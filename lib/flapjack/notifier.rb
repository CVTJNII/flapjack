#!/usr/bin/env ruby

require 'active_support/time'

require 'flapjack/exceptions'
require 'flapjack/redis_proxy'
require 'flapjack/record_queue'
require 'flapjack/utility'

require 'flapjack/data/alert'
require 'flapjack/data/check'
require 'flapjack/data/contact'
require 'flapjack/data/event'
require 'flapjack/data/notification'

module Flapjack

  class Notifier

    include Flapjack::Utility

    def initialize(opts = {})
      @lock = opts[:lock]
      @config = opts[:config] || {}

      @queue = Flapjack::RecordQueue.new(@config['queue'] || 'notifications',
                 Flapjack::Data::Notification)

      queue_configs = @config.find_all {|k, v| k =~ /_queue$/ }
      @queues = Hash[queue_configs.map {|k, v|
        [k[/^(.*)_queue$/, 1], Flapjack::RecordQueue.new(v, Flapjack::Data::Alert)]
      }]

      raise "No queues for media transports" if @queues.empty?

      tz_string = @config['default_contact_timezone'] || ENV['TZ'] || 'UTC'
      tz = ActiveSupport::TimeZone[tz_string.untaint]
      if tz.nil?
        raise "Invalid timezone string specified in default_contact_timezone or TZ (#{tz_string})"
      end
      @default_contact_timezone = tz
    end

    def start
      begin
        Zermelo.redis = Flapjack.redis

        loop do
          @lock.synchronize do
            @queue.foreach {|notif| process_notification(notif) }
          end

          @queue.wait
        end
      ensure
        Flapjack.redis.quit
      end
    end

    def stop_type
      :exception
    end

  private

    # takes an event for which messages should be generated, works out the type of
    # notification, updates the notification history in redis, generates the
    # notifications
    def process_notification(notification)
      Flapjack.logger.debug { "Processing notification: #{notification.inspect}" }

      check       = notification.check
      check_name  = check.name

      # TODO check whether time should come from something stored in the notification
      alerts = alerts_for(notification, check,
        :transports => @queues.keys, :time => Time.now)

      if alerts.nil? || alerts.empty?
        Flapjack.logger.info { "No alerts" }
      else
        Flapjack.logger.info { "Alerts: #{alerts.size}" }

        alerts.each do |alert|
          medium = alert.medium

          Flapjack.logger.info {
            "#{check_name} | #{medium.contact.id} | " \
            "#{medium.transport} | #{medium.address}\n" \
            "Enqueueing #{medium.transport} alert for " \
            "#{check_name} to #{medium.address} " \
            " rollup: #{alert.rollup || '-'}"
          }

          @queues[medium.transport].push(alert)
        end
      end

      notification.destroy
    end

    def alerts_for(notification, check, opts = {})
      time       = opts[:time]
      transports = opts[:transports]

      Flapjack::Data::Medium.lock(Flapjack::Data::Check,
                                  Flapjack::Data::ScheduledMaintenance,
                                  Flapjack::Data::UnscheduledMaintenance,
                                  Flapjack::Data::Rule,
                                  Flapjack::Data::Alert,
                                  Flapjack::Data::Blackhole,
                                  Flapjack::Data::Route,
                                  Flapjack::Data::Notification,
                                  Flapjack::Data::Contact,
                                  Flapjack::Data::State) do

        notification_state = notification.state

        this_notification_ok = 'acknowledgement'.eql?(notification_state.action) ||
          Flapjack::Data::Condition.healthy?(notification_state.condition)

        # checks in sched/unsched maint will not be notified -- time should be taken
        # from the processor's created notification, maint period check done there only
        this_notification_failure = !Flapjack::Data::Condition.healthy?(notification.severity)
        is_a_test            = 'test_notifications'.eql?(notification_state.action)

        alert_routes = nil

        if is_a_test
          alert_routes = check.routes.intersect(:conditions_list => [nil, /(?:^|,)critical(?:,|$)/])
        elsif !this_notification_ok
          alert_routes = check.routes.intersect(:conditions_list => [nil, /(?:^|,)#{notification.severity}(?:,|$)/])
          alert_routes.each do |route|
            route.alertable = this_notification_failure
            route.save! # no-op if the value didn't change
          end
        end

        media = check.alerting_media(:time => time, :routes => alert_routes).all

        Flapjack.logger.debug {
          "Alerting media for check #{check.name}:\n" +
            media.collect {|m| "#{m.transport} #{m.address}"}.join("\n")
        }

        # clear routes if OK, to get accurate rollup counts
        if !is_a_test && this_notification_ok
          check.routes.each do |route|
            route.alertable = false
            route.save! # no-op if the value didn't change
          end
        end

        media.inject([]) do |memo, alerting_medium|
          alert_rollup = nil
          alerting_check_ids = []

          unless is_a_test
            rollup_count_needed = !(alerting_medium.rollup_threshold.nil? ||
              (alerting_medium.rollup_threshold <= 0))

            if rollup_count_needed
              alerting_check_ids = alerting_medium.alerting_checks(:time => time).ids
            end

            alert_rollup = if rollup_count_needed &&
              (alerting_check_ids.size >= alerting_medium.rollup_threshold)

              'problem'
            else
              'problem'.eql?(alerting_medium.last_rollup_type) ? 'recovery' : nil
            end

            last_state = alerting_medium.last_state

            Flapjack.logger.debug "last_state #{last_state.inspect}"

            last_state_ok = last_state.nil? ? nil :
              (Flapjack::Data::Condition.healthy?(last_state.condition) ||
               'acknowledgement'.eql?(last_state.action))

            interval_allows = last_state.nil? ||
              ((!last_state_ok && this_notification_failure) &&
               ((last_state.created_at + (alerting_medium.interval || 0)) < notification_state.created_at))

            Flapjack.logger.debug "  last_state_ok = #{last_state_ok}\n" \
              "  interval_allows  = #{interval_allows}\n" \
              "  alert_rollup , last_rollup_type = #{alert_rollup} , #{alerting_medium.last_rollup_type}\n" \
              "  condition , last_notification_condition  = #{notification_state.condition} , #{last_state.nil? ? '-' : last_state.condition}\n" \
              "  no_previous_notification  = #{last_state.nil?}\n"

            next memo unless last_state.nil? ||
              (!last_state_ok && this_notification_ok) ||
              (alert_rollup != alerting_medium.last_rollup_type) ||
              ('acknowledgement'.eql?(last_state.action) && this_notification_failure) ||
              (notification_state.condition != last_state.condition) ||
              interval_allows
          end

          alert = Flapjack::Data::Alert.new(:condition => notification_state.condition,
            :action => notification_state.action,
            :last_condition => (last_state.nil? ? nil : last_state.condition),
            :last_action => (last_state.nil? ? nil : last_state.action),
            :condition_duration => notification.condition_duration,
            :acknowledgement_duration => notification.duration,
            :rollup => alert_rollup)

          unless alert_rollup.nil? || alerting_check_ids.empty?
            alert.rollup_states = Flapjack::Data::Check.intersect(:id => alerting_check_ids).all.each_with_object({}) do |check, m|
              cond = check.condition
              m[cond] ||= []
              m[cond] << check.name
            end
          end

          unless alert.save
            raise "Couldn't save alert: #{alert.errors.full_messages.inspect}"
          end

          alerting_medium.alerts << alert
          check.alerts  << alert

          Flapjack.logger.info "alerting for #{alerting_medium.transport}, #{alerting_medium.address}"

          unless is_a_test
            notification_state.latest_media << alerting_medium
            alerting_medium.last_rollup_type = alert.rollup
            alerting_medium.save
          end

          memo << alert
          memo
        end
      end
    end

  end
end
