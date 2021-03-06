require 'spec_helper'
require 'flapjack/gateways/jsonapi'

describe 'Flapjack::Gateways::JSONAPI::Methods::Blackholes', :sinatra => true, :logger => true, :pact_fixture => true do

  include_context "jsonapi"

  let(:blackhole)    { double(Flapjack::Data::Blackhole, :id => blackhole_data[:id]) }
  let(:blackhole_2)  { double(Flapjack::Data::Blackhole, :id => blackhole_2_data[:id]) }

  let(:contact) { double(Flapjack::Data::Contact, :id => contact_data[:id]) }

  let(:medium)  { double(Flapjack::Data::Medium, :id => email_data[:id]) }

  it "creates a blackhole" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    empty_ids = double('empty_ids')
    expect(empty_ids).to receive(:ids).and_return([])
    expect(Flapjack::Data::Blackhole).to receive(:intersect).
      with(:id => [blackhole_data[:id]]).and_return(empty_ids)

    expect(blackhole).to receive(:invalid?).and_return(false)
    expect(blackhole).to receive(:save!).and_return(true)
    expect(Flapjack::Data::Blackhole).to receive(:new).with(blackhole_data).
      and_return(blackhole)

    expect(blackhole).to receive(:as_json).with(:only => an_instance_of(Array)).
      and_return(blackhole_data.reject {|k,v| :id.eql?(k)})

    req_data  = blackhole_json(blackhole_data)
    resp_data = req_data.merge(:relationships => blackhole_rel(blackhole_data))

    post "/blackholes", Flapjack.dump_json(:data => req_data), jsonapi_env
    expect(last_response.status).to eq(201)
    expect(last_response.body).to be_json_eql(Flapjack.dump_json(:data =>
      resp_data))
  end

  it "does not create a blackhole if the data is improperly formatted" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    empty_ids = double('empty_ids')
    expect(empty_ids).to receive(:ids).and_return([])
    expect(Flapjack::Data::Blackhole).to receive(:intersect).
      with(:id => [blackhole_data[:id]]).and_return(empty_ids)

    errors = double('errors', :full_messages => ['err'])
    expect(blackhole).to receive(:errors).and_return(errors)

    expect(blackhole).to receive(:invalid?).and_return(true)
    expect(blackhole).not_to receive(:save!)
    expect(Flapjack::Data::Blackhole).to receive(:new).with(blackhole_data).
      and_return(blackhole)

    req_data  = blackhole_json(blackhole_data)

    post "/blackholes", Flapjack.dump_json(:data => req_data), jsonapi_env
    expect(last_response.status).to eq(403)
  end

  it "gets all blackholes" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    meta = {
      :pagination => {
        :page        => 1,
        :per_page    => 20,
        :total_pages => 1,
        :total_count => 1
      }
    }

    links = {
      :self  => 'http://example.org/blackholes',
      :first => 'http://example.org/blackholes?page=1',
      :last  => 'http://example.org/blackholes?page=1'
    }

    page = double('page')
    expect(page).to receive(:empty?).and_return(false)
    expect(page).to receive(:ids).and_return([blackhole.id])
    expect(page).to receive(:collect) {|&arg| [arg.call(blackhole)] }
    sorted = double('sorted')
    expect(sorted).to receive(:page).with(1, :per_page => 20).
      and_return(page)
    expect(sorted).to receive(:count).and_return(1)
    expect(Flapjack::Data::Blackhole).to receive(:sort).
      with(:id).and_return(sorted)

    expect(blackhole).to receive(:as_json).with(:only => an_instance_of(Array)).
      and_return(blackhole_data.reject {|k,v| :id.eql?(k)})

    resp_data = [blackhole_json(blackhole_data).merge(:relationships => blackhole_rel(blackhole_data))]

    get '/blackholes'
    expect(last_response).to be_ok
    expect(last_response.body).to be_json_eql(Flapjack.dump_json(:data => resp_data,
      :links => links, :meta => meta))
  end

  it "gets a single blackhole" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    expect(Flapjack::Data::Blackhole).to receive(:intersect).
      with(:id => blackhole.id).and_return([blackhole])

    expect(blackhole).to receive(:as_json).with(:only => an_instance_of(Array)).
      and_return(blackhole_data.reject {|k,v| :id.eql?(k)})

    resp_data = blackhole_json(blackhole_data).merge(:relationships => blackhole_rel(blackhole_data))

    get "/blackholes/#{blackhole.id}"
    expect(last_response).to be_ok
    expect(last_response.body).to be_json_eql(Flapjack.dump_json(:data =>
      resp_data, :links => {:self  => "http://example.org/blackholes/#{blackhole.id}"}))
  end

  it "does not get a blackhole that does not exist" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    no_blackholes = double('no_blackholes')
    expect(no_blackholes).to receive(:empty?).and_return(true)

    expect(Flapjack::Data::Blackhole).to receive(:intersect).
      with(:id => blackhole.id).and_return(no_blackholes)

    get "/blackholes/#{blackhole.id}"
    expect(last_response).to be_not_found
  end

  it "retrieves a blackhole and its linked contact record" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    blackholes = double('blackholes')
    expect(blackholes).to receive(:empty?).and_return(false)
    expect(blackholes).to receive(:collect) {|&arg| [arg.call(blackhole)] }
    expect(blackholes).to receive(:associated_ids_for).with(:contact).
      and_return(blackhole.id => contact.id)
    expect(Flapjack::Data::Blackhole).to receive(:intersect).
      with(:id => blackhole.id).and_return(blackholes)

    contacts = double('contacts')
    expect(contacts).to receive(:collect) {|&arg| [arg.call(contact)] }
    expect(Flapjack::Data::Contact).to receive(:intersect).
      with(:id => [contact.id]).and_return(contacts)

    expect(contact).to receive(:as_json).with(:only => an_instance_of(Array)).
      and_return(contact_data.reject {|k,v| :id.eql?(k)})

    expect(blackhole).to receive(:as_json).with(:only => an_instance_of(Array)).
      and_return(blackhole_data.reject {|k,v| :id.eql?(k)})

    get "/blackholes/#{blackhole.id}?include=contact"
    expect(last_response).to be_ok

    resp_data = blackhole_json(blackhole_data).merge(:relationships => blackhole_rel(blackhole_data))
    resp_data[:relationships][:contact][:data] = {:type => 'contact', :id => contact.id}

    resp_included = [contact_json(contact_data).merge(:relationships => contact_rel(contact_data))]

    expect(last_response.body).to be_json_eql(Flapjack.dump_json(
      :data => resp_data,
      :included => resp_included,
      :links => {:self  => "http://example.org/blackholes/#{blackhole.id}?include=contact"}))
  end

  it "retrieves a blackhole, its contact, and all of its contact's media records" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    blackholes = double('blackholes')
    expect(blackholes).to receive(:empty?).and_return(false)
    expect(blackholes).to receive(:collect) {|&arg| [arg.call(blackhole)] }
    expect(blackholes).to receive(:associated_ids_for).with(:contact).
      and_return(blackhole.id => contact.id)
    expect(Flapjack::Data::Blackhole).to receive(:intersect).
      with(:id => blackhole.id).and_return(blackholes)

    contacts = double('contacts')
    expect(contacts).to receive(:collect) {|&arg| [arg.call(contact)] }
    expect(contacts).to receive(:associated_ids_for).with(:media).
      and_return({contact.id => [medium.id]})
    expect(Flapjack::Data::Contact).to receive(:intersect).
      with(:id => [contact_data[:id]]).and_return(contacts)

    media = double('media')
    expect(media).to receive(:collect) {|&arg| [arg.call(medium)] }
    expect(Flapjack::Data::Medium).to receive(:intersect).
      with(:id => [medium.id]).and_return(media)

    expect(medium).to receive(:as_json).with(:only => an_instance_of(Array)).
      and_return(email_data.reject {|k,v| :id.eql?(k)})

    expect(contact).to receive(:as_json).with(:only => an_instance_of(Array)).
      and_return(contact_data.reject {|k,v| :id.eql?(k)})

    expect(blackhole).to receive(:as_json).with(:only => an_instance_of(Array)).
      and_return(blackhole_data.reject {|k,v| :id.eql?(k)})

    get "/blackholes/#{blackhole.id}?include=contact.media"
    expect(last_response).to be_ok

    resp_data = blackhole_json(blackhole_data).merge(:relationships => blackhole_rel(blackhole_data))
    resp_data[:relationships][:contact][:data] = {:type => 'contact', :id => contact.id}

    resp_incl_contact = contact_json(contact_data).merge(:relationships => contact_rel(contact_data))
    resp_incl_contact[:relationships][:media][:data] = [{:type => 'medium', :id => medium.id}]

    resp_included = [
      resp_incl_contact,
      medium_json(email_data).merge(:relationships => medium_rel(email_data))
    ]

    expect(last_response.body).to be_json_eql(Flapjack.dump_json(
      :data => resp_data,
      :included => resp_included,
      :links => {:self  => "http://example.org/blackholes/#{blackhole.id}?include=contact.media"}
    ))
  end

  it "deletes a blackhole" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    expect(blackhole).to receive(:destroy)
    expect(Flapjack::Data::Blackhole).to receive(:find_by_id!).
      with(blackhole.id).and_return(blackhole)

    delete "/blackholes/#{blackhole.id}"
    expect(last_response.status).to eq(204)
  end

  it "deletes multiple blackholes" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    blackholes = double('blackholes')
    expect(blackholes).to receive(:count).and_return(2)
    expect(blackholes).to receive(:destroy_all)
    expect(Flapjack::Data::Blackhole).to receive(:intersect).
      with(:id => [blackhole.id, blackhole_2.id]).and_return(blackholes)

    delete "/blackholes",
      Flapjack.dump_json(:data => [
        {:id => blackhole.id, :type => 'blackhole'},
        {:id => blackhole_2.id, :type => 'blackhole'}
      ]),
      jsonapi_bulk_env
    expect(last_response.status).to eq(204)
  end

  it "does not delete a blackhole that does not exist" do
    expect(Flapjack::Data::Blackhole).to receive(:lock).
      with(Flapjack::Data::Contact,
           Flapjack::Data::Medium,
           Flapjack::Data::Tag).
      and_yield

    expect(Flapjack::Data::Blackhole).to receive(:find_by_id!).
      with(blackhole.id).and_raise(Zermelo::Records::Errors::RecordNotFound.new(Flapjack::Data::Blackhole, blackhole.id))

    delete "/blackholes/#{blackhole.id}"
    expect(last_response).to be_not_found
  end

end
