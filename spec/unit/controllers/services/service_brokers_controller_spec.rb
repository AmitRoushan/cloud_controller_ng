require 'spec_helper'

module VCAP::CloudController
  describe ServiceBrokersController, :services do
    let(:headers) { json_headers(admin_headers) }

    let(:non_admin_headers) do
      user = VCAP::CloudController::User.make(admin: false)
      json_headers(headers_for(user))
    end

    describe 'Query Parameters' do
      it { expect(described_class).to be_queryable_by(:name) }
    end

    describe 'Attributes' do
      it do
        expect(described_class).to have_creatable_attributes({
          name: { type: 'string', required: true },
          broker_url: { type: 'string', required: true },
          auth_username: { type: 'string', required: true },
          auth_password: { type: 'string', required: true }
        })
      end

      it do
        expect(described_class).to have_updatable_attributes({
          name: { type: 'string' },
          broker_url: { type: 'string' },
          auth_username: { type: 'string' },
          auth_password: { type: 'string' }
        })
      end
    end

    describe 'POST /v2/service_brokers' do
      let(:name) { Sham.name }
      let(:broker_url) { 'http://cf-service-broker.example.com' }
      let(:auth_username) { 'me' }
      let(:auth_password) { 'abc123' }
      let(:catalog_json) do
        {
          'services' => [{
            'name' => 'fake-service',
            'id' => 'f479b64b-7c25-42e6-8d8f-e6d22c456c9b',
            'description' => 'fake service',
            'tags' => ['no-sql', 'relational'],
            'max_db_per_node' => 5,
            'bindable' => true,
            'metadata' => {
              'provider' => { 'name' => 'The name' },
              'listing' => {
                'imageUrl' => 'http://catgifpage.com/cat.gif',
                'blurb' => 'fake broker that is fake',
                'longDescription' => 'A long time ago, in a galaxy far far away...'
              },
              'displayName' => 'The Fake Broker'
            },
            'dashboard_client' => nil,
            'plan_updateable' => true,
            'plans' => [{
              'name' => 'fake-plan',
              'id' => 'f52eabf8-e38d-422f-8ef9-9dc83b75cc05',
              'description' => 'Shared fake Server, 5tb persistent disk, 40 max concurrent connections',
              'max_storage_tb' => 5,
              'metadata' => {
                'cost' => 0.0,
                'bullets' => [
                  { 'content' => 'Shared fake server' },
                  { 'content' => '5 TB storage' },
                  { 'content' => '40 concurrent connections' }
                ],
              },
            }],
          }],
        }
      end

      let(:body_hash) do
        {
          name: name,
          broker_url: broker_url,
          auth_username: auth_username,
          auth_password: auth_password,
        }
      end
      let(:catalog_status_code) { 200 }
      let(:catalog_url) { "http://#{auth_username}:#{auth_password}@cf-service-broker.example.com/v2/catalog" }

      let(:body) { body_hash.to_json }
      let(:errors) { instance_double(Sequel::Model::Errors, on: nil) }

      def stub_get_catalog_request(status_code, body)
        stub_request(:get, catalog_url).
          to_return(status: status_code, body: MultiJson.dump(body))
      end

      it 'creates a broker create event' do
        email = 'email@example.com'
        stub_get_catalog_request(catalog_status_code, catalog_json)
        post '/v2/service_brokers', body, headers_for(admin_user, email: email)
        broker = ServiceBroker.last

        event = Event.first(type: 'audit.service_broker.create')
        expect(event.actor_type).to eq('user')
        expect(event.timestamp).to be
        expect(event.actor).to eq(admin_user.guid)
        expect(event.actor_name).to eq(email)
        expect(event.actee).to eq(broker.guid)
        expect(event.actee_type).to eq('service_broker')
        expect(event.actee_name).to eq(body_hash[:name])
        expect(event.space_guid).to be_empty
        expect(event.organization_guid).to be_empty
        expect(event.metadata).to include({
          'request' => {
            'name' => body_hash[:name],
            'broker_url' => body_hash[:broker_url],
            'auth_username' => body_hash[:auth_username],
            'auth_password' => '[REDACTED]',
          }
        })
      end

      it 'creates a service broker registration' do
        stub_get_catalog_request(catalog_status_code, catalog_json)
        post '/v2/service_brokers', body, headers

        expect(last_response.status).to eq(201)
        expect(a_request(:get, catalog_url)).to have_been_made
      end

      it 'returns the serialized broker' do
        stub_get_catalog_request(catalog_status_code, catalog_json)
        post '/v2/service_brokers', body, headers

        service_broker = ServiceBroker.last
        expect(MultiJson.load(last_response.body)).to eq(
          'metadata' => {
            'guid' => service_broker.guid,
            'created_at' => service_broker.created_at.iso8601,
            'updated_at' => nil,
            'url' => "/v2/service_brokers/#{service_broker.guid}",
          },
          'entity' =>  {
              'name' => name,
              'broker_url' => broker_url,
              'auth_username' => auth_username,
          },
        )
      end

      it 'includes a location header for the resource' do
        stub_get_catalog_request(catalog_status_code, catalog_json)
        post '/v2/service_brokers', body, headers

        headers = last_response.original_headers
        broker = ServiceBroker.last
        expect(headers.fetch('Location')).to eq("/v2/service_brokers/#{broker.guid}")
      end

      context 'when the fields for creating the broker is invalid' do
        context 'when the broker url is taken' do
          before do
            ServiceBroker.make(broker_url: body_hash[:broker_url])
          end

          it 'returns an error' do
            stub_get_catalog_request(catalog_status_code, catalog_json)
            post '/v2/service_brokers', body, headers

            expect(last_response.status).to eq(400)
            expect(decoded_response.fetch('code')).to eq(270003)
          end
        end

        context 'when the broker name is taken' do
          before do
            ServiceBroker.make(name: body_hash[:name])
          end

          it 'returns an error' do
            stub_get_catalog_request(catalog_status_code, catalog_json)
            post '/v2/service_brokers', body, headers

            expect(last_response.status).to eq(400)
            expect(decoded_response.fetch('code')).to eq(270002)
          end
        end

        context 'when catalog response is invalid' do
          let(:catalog_json) do
            {}
          end

          it 'returns an error' do
            stub_get_catalog_request(200, catalog_json)
            post '/v2/service_brokers', body, headers

            expect(last_response).to have_status_code(502)
            expect(decoded_response.fetch('code')).to eq(270012)
            expect(decoded_response.fetch('description')).to include('Service broker catalog is invalid:')
            expect(decoded_response.fetch('description')).to include('Service broker must provide at least one service')
          end
        end
      end

      context 'when the CC is not configured to use the UAA correctly and the service broker requests dashboard access' do
        before do
          VCAP::CloudController::Config.config[:uaa_client_name] = nil
          VCAP::CloudController::Config.config[:uaa_client_secret] = nil

          catalog_json['services'][0]['dashboard_client'] = {
            id: 'p-mysql-client',
            secret: 'p-mysql-secret',
            redirect_uri: 'http://p-mysql.example.com',
          }
        end

        it 'emits warnings as headers to the CC client' do
          stub_get_catalog_request(catalog_status_code, catalog_json)
          post('/v2/service_brokers', body, headers)

          warnings = last_response.headers['X-Cf-Warnings'].split(',').map { |w| CGI.unescape(w) }
          expect(warnings.length).to eq(1)
          expect(warnings[0]).to eq(VCAP::Services::SSO::DashboardClientManager::REQUESTED_FEATURE_DISABLED_WARNING)
        end
      end
    end

    describe 'DELETE /v2/service_brokers/:guid' do
      let!(:broker) { ServiceBroker.make(name: 'FreeWidgets', broker_url: 'http://example.com/', auth_password: 'secret') }

      it 'deletes the service broker' do
        delete "/v2/service_brokers/#{broker.guid}", {}, headers

        expect(last_response.status).to eq(204)

        get '/v2/service_brokers', {}, headers
        expect(decoded_response).to include('total_results' => 0)
      end

      it 'creates a broker delete event' do
        email = 'some-email-address@example.com'
        delete "/v2/service_brokers/#{broker.guid}", {}, headers_for(admin_user, email: email)

        event = Event.first(type: 'audit.service_broker.delete')
        expect(event.actor_type).to eq('user')
        expect(event.timestamp).to be
        expect(event.actor).to eq(admin_user.guid)
        expect(event.actor_name).to eq(email)
        expect(event.actee).to eq(broker.guid)
        expect(event.actee_type).to eq('service_broker')
        expect(event.actee_name).to eq(broker.name)
        expect(event.space_guid).to be_empty
        expect(event.organization_guid).to be_empty
        expect(event.metadata).to have_key('request')
        expect(event.metadata['request']).to be_empty
      end

      it 'returns 404 when deleting a service broker that does not exist' do
        delete '/v2/service_brokers/1234', {}, headers
        expect(last_response.status).to eq(404)
      end

      context 'when a service instance exists', isolation: :truncation do
        it 'returns a 400 and an appropriate error message' do
          service = Service.make(service_broker: broker)
          service_plan = ServicePlan.make(service: service)
          ManagedServiceInstance.make(service_plan: service_plan)

          delete "/v2/service_brokers/#{broker.guid}", {}, headers

          expect(last_response.status).to eq(400)
          expect(decoded_response.fetch('code')).to eq(270010)
          expect(decoded_response.fetch('description')).to match(/Can not remove brokers that have associated service instances/)

          get '/v2/service_brokers', {}, headers
          expect(decoded_response).to include('total_results' => 1)
        end
      end

      describe 'authentication' do
        it 'returns a forbidden status for non-admin users' do
          delete "/v2/service_brokers/#{broker.guid}", {}, non_admin_headers
          expect(last_response).to be_forbidden

          # make sure it still exists
          get '/v2/service_brokers', {}, headers
          expect(decoded_response).to include('total_results' => 1)
        end
      end
    end

    describe 'PUT /v2/service_brokers/:guid' do
      let(:body_hash) do
        {
          name: 'My Updated Service',
          auth_username: 'new-username',
          auth_password: 'new-password',
        }
      end

      let(:body) { body_hash.to_json }
      let(:errors) { instance_double(Sequel::Model::Errors, on: nil) }
      let(:broker) do
        instance_double(ServiceBroker, {
          guid: '123',
          name: 'My Custom Service',
          broker_url: 'http://broker.example.com',
          auth_username: 'me',
          auth_password: 'abc123',
          set: nil
        })
      end

      let(:registration) do
        reg = instance_double(VCAP::Services::ServiceBrokers::ServiceBrokerRegistration, {
          broker: broker,
          errors: errors
        })
        allow(reg).to receive(:update).and_return(reg)
        allow(reg).to receive(:warnings).and_return([])
        reg
      end

      let(:presenter) { instance_double(ServiceBrokerPresenter, {
        to_json: "{\"metadata\":{\"guid\":\"#{broker.guid}\"}}"
      }) }

      before do
        allow(ServiceBroker).to receive(:find)
        allow(ServiceBroker).to receive(:find).with(guid: broker.guid).and_return(broker)
        allow(VCAP::Services::ServiceBrokers::ServiceBrokerRegistration).to receive(:new).and_return(registration)
        allow(ServiceBrokerPresenter).to receive(:new).with(broker).and_return(presenter)
      end

      context 'when changing credentials' do
        it 'creates a broker update event' do
          old_broker_name = broker.name
          body_hash.delete(:broker_url)
          email = 'email@example.com'

          put "/v2/service_brokers/#{broker.guid}", body, headers_for(admin_user, email: email)

          event = Event.first(type: 'audit.service_broker.update')
          expect(event.actor_type).to eq('user')
          expect(event.timestamp).to be
          expect(event.actor).to eq(admin_user.guid)
          expect(event.actor_name).to eq(email)
          expect(event.actee).to eq(broker.guid)
          expect(event.actee_type).to eq('service_broker')
          expect(event.actee_name).to eq(old_broker_name)
          expect(event.space_guid).to be_empty
          expect(event.organization_guid).to be_empty
          expect(event.metadata['request']['name']).to eq body_hash[:name]
          expect(event.metadata['request']['auth_username']).to eq body_hash[:auth_username]
          expect(event.metadata['request']['auth_password']).to eq '[REDACTED]'
          expect(event.metadata['request']).not_to have_key 'broker_url'
        end

        it 'updates the broker' do
          put "/v2/service_brokers/#{broker.guid}", body, headers

          expect(broker).to have_received(:set).with(body_hash)
          expect(registration).to have_received(:update)
        end

        it 'returns the serialized broker' do
          put "/v2/service_brokers/#{broker.guid}", body, headers

          expect(last_response.body).to eq(presenter.to_json)
        end

        context 'when specifying an unknown broker' do
          it 'returns 404' do
            put '/v2/service_brokers/nonexistent', body, headers

            expect(last_response.status).to eq(HTTP::NOT_FOUND)
          end
        end

        context 'when there is an error in Broker Registration' do
          before { allow(registration).to receive(:update).and_return(nil) }

          context 'when the broker url is not a valid http/https url' do
            before { allow(errors).to receive(:on).with(:broker_url).and_return([:url]) }

            it 'returns an error' do
              put "/v2/service_brokers/#{broker.guid}", body, headers

              expect(last_response.status).to eq(400)
              expect(decoded_response.fetch('code')).to eq(270011)
              expect(decoded_response.fetch('description')).to match(/is not a valid URL/)
            end
          end

          context 'when the broker url is taken' do
            before { allow(errors).to receive(:on).with(:broker_url).and_return([:unique]) }

            it 'returns an error' do
              put "/v2/service_brokers/#{broker.guid}", body, headers

              expect(last_response.status).to eq(400)
              expect(decoded_response.fetch('code')).to eq(270003)
              expect(decoded_response.fetch('description')).to match(/The service broker url is taken/)
            end
          end

          context 'when the broker name is taken' do
            before { allow(errors).to receive(:on).with(:name).and_return([:unique]) }

            it 'returns an error' do
              put "/v2/service_brokers/#{broker.guid}", body, headers

              expect(last_response.status).to eq(400)
              expect(decoded_response.fetch('code')).to eq(270002)
              expect(decoded_response.fetch('description')).to match(/The service broker name is taken/)
            end
          end

          context 'when there are other errors on the registration' do
            before { allow(errors).to receive(:full_messages).and_return('A bunch of stuff was wrong') }

            it 'returns an error' do
              put "/v2/service_brokers/#{broker.guid}", body, headers

              expect(last_response.status).to eq(400)
              expect(decoded_response.fetch('code')).to eq(270001)
              expect(decoded_response.fetch('description')).to eq('Service broker is invalid: A bunch of stuff was wrong')
            end
          end
        end

        context 'when the broker registration has warnings' do
          before do
            allow(registration).to receive(:warnings).and_return(['warning1', 'warning2'])
          end

          it 'adds the warnings' do
            put("/v2/service_brokers/#{broker.guid}", body, headers)
            warnings = last_response.headers['X-Cf-Warnings'].split(',').map { |w| CGI.unescape(w) }
            expect(warnings.length).to eq(2)
            expect(warnings[0]).to eq('warning1')
            expect(warnings[1]).to eq('warning2')
          end
        end

        describe 'authentication' do
          it 'returns a forbidden status for non-admin users' do
            put "/v2/service_brokers/#{broker.guid}", {}, non_admin_headers
            expect(last_response).to be_forbidden
          end
        end
      end
    end
  end
end
