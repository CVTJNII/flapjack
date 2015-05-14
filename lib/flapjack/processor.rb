#!/usr/bin/env ruby

require 'chronic_duration'

require 'flapjack/redis_proxy'

require 'flapjack/filters/acknowledgement'
require 'flapjack/filters/ok'
require 'flapjack/filters/scheduled_maintenance'
require 'flapjack/filters/unscheduled_maintenance'
require 'flapjack/filters/delays'

require 'flapjack/data/check'
require 'flapjack/data/event'
require 'flapjack/data/notification'
require 'flapjack/data/statistic'

require 'flapjack/exceptions'
require 'flapjack/utility'

module Flapjack

  class Processor

    include Flapjack::Utility

    def initialize(opts = {})
      @lock = opts[:lock]

      @config = opts[:config]

      @boot_time = opts[:boot_time]

      @queue = @config['queue'] || 'events'

      @initial_failure_delay = @config['initial_failure_delay']
      if !@initial_failure_delay.is_a?(Integer) || (@initial_failure_delay < 0)
        @initial_failure_delay = nil
      end

      @repeat_failure_delay = @config['repeat_failure_delay']
      if !@repeat_failure_delay.is_a?(Integer) || (@repeat_failure_delay < 0)
        @repeat_failure_delay = nil
      end

      @notifier_queue = Flapjack::RecordQueue.new(@config['notifier_queue'] || 'notifications',
                 Flapjack::Data::Notification)

      @archive_events        = @config['archive_events'] || false
      @events_archive_maxage = @config['events_archive_maxage']

      ncsm_duration_conf = @config['new_check_scheduled_maintenance_duration'] || '100 years'
      @ncsm_duration = ChronicDuration.parse(ncsm_duration_conf, :keep_zero => true)

      @ncsm_ignore_tags = @config['new_check_scheduled_maintenance_ignore_tags'] || []

      @exit_on_queue_empty = !!@config['exit_on_queue_empty']

      @filters = [Flapjack::Filters::Ok.new,
                  Flapjack::Filters::ScheduledMaintenance.new,
                  Flapjack::Filters::UnscheduledMaintenance.new,
                  Flapjack::Filters::Delays.new,
                  Flapjack::Filters::Acknowledgement.new]

      fqdn          = `/bin/hostname -f`.chomp
      pid           = Process.pid
      @instance_id  = "#{fqdn}:#{pid}"

      @entry_range = Zermelo::Filters::IndexRange.new(1, nil)
    end

    def start_stats
      empty_stats = {:created_at => @boot_time, :all_events => 0,
        :ok_events => 0, :failure_events => 0, :action_events => 0,
        :invalid_events => 0}

      @global_stats = Flapjack::Data::Statistic.
        intersect(:instance_name => 'global').all.first

      if @global_stats.nil?
        @global_stats = Flapjack::Data::Statistic.new(empty_stats.merge(
          :instance_name => 'global'))
        @global_stats.save!
      end

      @instance_stats = Flapjack::Data::Statistic.new(empty_stats.merge(
        :instance_name => @instance_id))
      @instance_stats.save!
    end

    def start
      Flapjack.logger.info("Booting main loop.")

      begin
        Zermelo.redis = Flapjack.redis

        start_stats

        queue = (@config['queue'] || 'events')

        loop do
          @lock.synchronize do
            foreach_on_queue(queue) {|event| process_event(event)}
          end

          raise Flapjack::GlobalStop if @exit_on_queue_empty

          wait_for_queue(queue)
        end

      ensure
        @instance_stats.destroy unless @instance_stats.nil? || !@instance_stats.persisted?
        Flapjack.redis.quit
      end
    end

    def stop_type
      :exception
    end

  private

    def foreach_on_queue(queue, opts = {})
      base_time_str = Time.now.utc.strftime "%Y%m%d%H"
      rejects = "events_rejected:#{base_time_str}"
      archive = @archive_events ? "events_archive:#{base_time_str}" : nil
      max_age = archive ? @events_archive_maxage : nil

      while event_json = (archive ? Flapjack.redis.rpoplpush(queue, archive) :
                                    Flapjack.redis.rpop(queue))
        parsed, errors = Flapjack::Data::Event.parse_and_validate(event_json)
        if !errors.nil? && !errors.empty?
          Flapjack.redis.multi do |multi|
            if archive
              multi.lrem(archive, 1, event_json)
            end
            multi.lpush(rejects, event_json)
            @global_stats.all_events       += 1
            @global_stats.invalid_events   += 1
            @instance_stats.all_events     += 1
            @instance_stats.invalid_events += 1
            if archive
              multi.expire(archive, max_age)
            end
          end
          Flapjack::Data::Statistic.lock do
            @global_stats.save!
            @instance_stats.save!
          end
          Flapjack.logger.error {
            error_str = errors.nil? ? '' : errors.join(', ')
            "Invalid event data received, #{error_str} #{parsed.inspect}"
          }
        else
          Flapjack.redis.expire(archive, max_age) if archive
          yield Flapjack::Data::Event.new(parsed) if block_given?
        end
      end
    end

    def wait_for_queue(queue)
      Flapjack.redis.brpop("#{queue}_actions")
    end

    def process_event(event)
      Flapjack.logger.debug {
        pending = Flapjack::Data::Event.pending_count(@queue)
        "#{pending} events waiting on the queue"
      }
      Flapjack.logger.debug { "Event received: #{event.inspect}" }
      Flapjack.logger.debug { "Processing Event: #{event.dump}" }

      timestamp = Time.now

      event_condition = case event.state
      when 'acknowledgement', 'test_notifications'
        nil
      else
        cond = Flapjack::Data::Condition.for_name(event.state)
        if cond.nil?
          Flapjack.logger.error { "Invalid event received: #{event.inspect}" }
          Flapjack::Data::Statistic.lock do
            @global_stats.all_events       += 1
            @global_stats.invalid_events   += 1
            @instance_stats.all_events     += 1
            @instance_stats.invalid_events += 1
            @global_stats.save!
            @instance_stats.save!
          end
          return
        end
        cond
      end

      Flapjack::Data::Check.lock(Flapjack::Data::State, Flapjack::Data::Entry,
        Flapjack::Data::ScheduledMaintenance, Flapjack::Data::UnscheduledMaintenance,
        Flapjack::Data::Tag, Flapjack::Data::Route, Flapjack::Data::Medium,
        Flapjack::Data::Notification, Flapjack::Data::Statistic) do

        check = Flapjack::Data::Check.intersect(:name => event.id).all.first ||
          Flapjack::Data::Check.new(:name => event.id)

        # result will be nil if check has been created via API but has no events
        old_state = check.id.nil? ? nil : check.states.last
        new_state, new_entry = update_check(check, old_state, event,
                                            event_condition, timestamp)

        check.enabled = true unless event_condition.nil?
        check.save! # no-op if not new and not changed

        @global_stats.save!
        @instance_stats.save!

        if old_state.nil? && !event_condition.nil? &&
          Flapjack::Data::Condition.healthy?(event_condition.name)

          new_entry.save!
          new_state.save!
          new_state.entries << new_entry
          check.states << new_state

          # If the service event's state is ok and there was no previous state, don't alert.
          # This stops new checks from alerting as "recovery" after they have been added.
          Flapjack.logger.debug {
            "Not generating notification for event #{event.id} because " \
            "filtering was skipped"
          }

        else
          filter_opts = {
            :initial_failure_delay => @initial_failure_delay,
            :repeat_failure_delay => @repeat_failure_delay,
            :old_state => old_state, :new_entry => new_entry,
            :timestamp => timestamp, :duration => event.duration
          }

          blocker = @filters.find {|f| f.block?(check, filter_opts) }

          if blocker.nil?
            Flapjack.logger.info { "Generating notification for event #{event.dump}" }
            generate_notification(check, old_state, new_state, new_entry,
                                  event, event_condition)
          else
            new_entry.save!

            if new_state.nil?
              entries = old_state.entries

              if entries.count > 1
                entries.intersect(:timestamp => @entry_range).each do |e|
                  entries.delete(e)
                  Flapjack::Data::Entry.delete_if_unlinked(e)
                end
              end
              entries << new_entry
            else
              new_state.save!
              new_state.entries << new_entry
              check.states << new_state
            end

            Flapjack.logger.debug { "Not generating notification for event #{event.id} " \
                            "because this filter blocked: #{blocker.name}" }
          end
        end
      end
    end

    def update_check(check, old_state, event, event_condition, timestamp)
      @global_stats.all_events   += 1
      @instance_stats.all_events += 1

      event.counter = @global_stats.all_events

      new_state         = nil
      new_entry         = Flapjack::Data::Entry.new(:timestamp => timestamp)

      ncsm_sched_maint  = nil

      if event_condition.nil?
        # Action events represent human or automated interaction with Flapjack
        new_entry.action = event.state

        unless 'test_notifications'.eql?(new_entry.action)
          @global_stats.action_events   += 1
          @instance_stats.action_events += 1

          if old_state.nil?
            # Flapjack.logger.info { "No previous state for event #{event.id}" }
            new_state = Flapjack::Data::State.new(:timestamp => timestamp,
              :condition => nil, :action => event.state)
          else
            new_entry.condition = old_state.condition
          end
        end
      else
        # Service events represent current state of checks on monitored systems

        check.failing = !Flapjack::Data::Condition.healthy?(event_condition.name)
        check.condition = event_condition.name

        if check.failing
          @global_stats.failure_events   += 1
          @instance_stats.failure_events += 1
        else
          @global_stats.ok_events   += 1
          @instance_stats.ok_events += 1
        end

        check.failing = !Flapjack::Data::Condition.healthy?(event_condition.name)

        # only change notification delays on service (non-action) events;
        # resets a check's delays to the default values if the event data doesn't
        # reinforce the change
        check.initial_failure_delay = event.initial_failure_delay ||
                                      Flapjack::DEFAULT_INITIAL_FAILURE_DELAY
        check.repeat_failure_delay  = event.repeat_failure_delay  ||
                                      Flapjack::DEFAULT_REPEAT_FAILURE_DELAY

        new_entry.condition = event_condition.name

        if old_state.nil?
          Flapjack.logger.info { "No previous state for event #{event.id}" }

          new_state = Flapjack::Data::State.new(:timestamp => timestamp,
            :condition => event_condition.name)

          if (@ncsm_duration > 0) && !check.id.nil? &&
            (check.tags.all.map(&:name) & @ncsm_ignore_tags).empty?

            Flapjack.logger.info { "Setting scheduled maintenance for #{time_period_in_words(@ncsm_duration)}" }

            ncsm_sched_maint = Flapjack::Data::ScheduledMaintenance.new(:start_time => timestamp,
              :end_time => timestamp + @ncsm_duration,
              :summary => 'Automatically created for new check')
            ncsm_sched_maint.save!

            check.scheduled_maintenances << ncsm_sched_maint
          end

        elsif event_condition.name != old_state.condition
          new_state = Flapjack::Data::State.new(:timestamp => timestamp,
            :condition => event_condition.name)
        end

        new_entry.perfdata = event.perfdata
      end

      new_entry.summary   = event.summary
      new_entry.details   = event.details

      [new_state, new_entry]
    end

    def generate_notification(check, old_state, new_state, new_entry, event, event_condition)
      severity = nil

      new_entry.save!

      if new_state.nil?
        entries = old_state.entries
        if entries.count > 1
          entries.intersect(:timestamp => @entry_range).each {|e| entries.delete(e); Flapjack::Data::Entry.delete_if_unlinked(e) }
        end
        entries << new_entry
      else
        new_state.save!
        new_state.entries << new_entry
        check.states << new_state
      end

      if 'test_notifications'.eql?(new_entry.action)
        # the entry won't be preserved for any time after the notification is
        # sent via association to a state or check
        severity = Flapjack::Data::Condition.most_unhealthy
      else

        # lat_notif = check.latest_notifications
        # lat_notif.intersect(:condition => new_entry.condition).each do |e|
        #   lat_notif.delete(e)
        # end
        # lat_notif << new_entry

        most_severe = check.most_severe
        most_severe_cond = most_severe.nil? ? nil :
          Flapjack::Data::Condition.for_name(most_severe.condition)

        # Flapjack.logger.debug { "old most severe #{most_severe_cond.nil? ? 'ok' : most_severe_cond.name}"}

        if !event_condition.nil? &&
          Flapjack::Data::Condition.unhealthy.has_key?(event_condition.name) &&
          (most_severe_cond.nil? || (event_condition < most_severe_cond))

          check.most_severe = (new_state || old_state)
          most_severe_cond = event_condition
        end

        # Flapjack.logger.debug { "new most severe #{most_severe_cond.nil? ? 'ok' : most_severe_cond.name}"}

        severity = most_severe_cond.nil? ? 'ok' : most_severe_cond.name
      end

      Flapjack.logger.info { "severity #{severity}"}

      Flapjack.logger.debug("Notification is being generated for #{event.id}: " + event.inspect)

      event_hash = (event_condition.nil? || Flapjack::Data::Condition.healthy?(event_condition.name)) ?
        nil : check.ack_hash

      condition_duration = old_state.nil? ? nil :
                             (new_entry.timestamp - old_state.timestamp)

      notification = Flapjack::Data::Notification.new(:duration => event.duration,
        :severity => severity, :condition_duration => condition_duration,
        :event_hash => event_hash)

      notification.save!
      notification.entry = new_entry

      @notifier_queue.push(notification)

      return if 'test_notifications'.eql?(new_entry.action)

      Flapjack.logger.info "notification count: #{check.notification_count}"

      if check.notification_count.nil?
        check.notification_count = 1
      else
        check.notification_count += 1
      end
      check.save!

      Flapjack.logger.info "#{check.name} #{check.errors.full_messages} notification count: #{check.notification_count}"

    end
  end
end
