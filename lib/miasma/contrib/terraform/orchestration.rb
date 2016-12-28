require 'miasma'

module Miasma
  module Models
    class Orchestration
      class Terraform < Orchestration

        include Miasma::Contrib::TerraformApiCore::ApiCommon

        module Local

          # Generate wrapper stack
          def terraform_stack(stack)
            if(terraform_local_directory.to_s.empty?)
              raise ArgumentError.new 'Attribute `terraform_local_directory` must be set for local mode usage'
            end
            memoize(stack.name, :direct) do
              MiasmaTerraform::Stack.new(
                :name => stack.name,
                :container => terraform_local_directory
              )
            end
          end

          # Save the stack
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [Models::Orchestration::Stack]
          def stack_save(stack)
            tf_stack = terraform_stack(stack)
            tf_stack.save(
              :template => stack.template,
              :parameters => stack.parameters || {}
            )
            stack.id = stack.name
            stack.valid_state
          end

          # Reload the stack data from the API
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [Models::Orchestration::Stack]
          def stack_reload(stack)
            if(stack.persisted?)
              begin
                s = terraform_stack(stack).info
                stack.load_data(
                  :id => s[:id],
                  :created => s[:creation_time].to_s.empty? ? nil : Time.at(s[:creation_time].to_i / 1000.0),
                  :description => s[:description],
                  :name => s[:name],
                  :state => s[:status].downcase.to_sym,
                  :status => s[:status],
                  :status_reason => s[:stack_status_reason],
                  :updated => s[:updated_time].to_s.empty? ? nil : Time.at(s[:updated_time].to_i / 1000.0),
                  :outputs => s[:outputs].map{|k,v| {:key => k, :value => v}}
                ).valid_state
              rescue MiasmaTerraform::Stack::Error::NotFound
                raise Miasma::Error::ApiError::RequestError.new(
                  "Failed to locate stack `#{stack.name}`",
                  :response => OpenStruct.new(:code => 404)
                )
              end
            end
            stack
          end

          # Delete the stack
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [TrueClass, FalseClass]
          def stack_destroy(stack)
            if(stack.persisted?)
              terraform_stack(stack).destroy!
              true
            else
              false
            end
          end

          # Fetch stack template
          #
          # @param stack [Stack]
          # @return [Smash] stack template
          def stack_template_load(stack)
            if(stack.persisted?)
              JSON.load(terraform_stack(stack).template).to_smash
            else
              Smash.new
            end
          end

          # Validate stack template
          #
          # @param stack [Stack]
          # @return [NilClass, String] nil if valid, string error message if invalid
          def stack_template_validate(stack)
            begin
              terraform_stack(stack).validate(stack.template)
              nil
            rescue MiasmaTerraform::Error::Validation => e
              MultiJson.load(e.response.body.to_s).to_smash.get(:error, :message)
            end
          end

          # Return all stacks
          #
          # @param options [Hash] filter
          # @return [Array<Models::Orchestration::Stack>]
          # @todo check if we need any mappings on state set
          def stack_all(options={})
            MiasmaTerraform::Stack.list(terraform_local_directory).map do |stack_name|
              s = terraform_stack(Stack.new(self, :name => stack_name)).info
              Stack.new(
                self,
                :id => s[:id],
                :created => s[:creation_time].to_s.empty? ? nil : Time.at(s[:creation_time].to_i / 1000.0),
                :description => s[:description],
                :name => s[:name],
                :state => s[:status].downcase.to_sym,
                :status => s[:status],
                :status_reason => s[:stack_status_reason],
                :updated => s[:updated_time].to_s.empty? ? nil : Time.at(s[:updated_time].to_i / 1000.0)
              ).valid_state
            end
          end

          # Return all resources for stack
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [Array<Models::Orchestration::Stack::Resource>]
          def resource_all(stack)
            terraform_stack(stack).resources.map do |resource|
              Stack::Resource.new(
                stack,
                :id => resource[:physical_id],
                :name => resource[:name],
                :type => resource[:type],
                :logical_id => resource[:name],
                :state => resource[:status].downcase.to_sym,
                :status => resource[:status],
                :status_reason => resource[:resource_status_reason],
                :updated => resource[:updated_time].to_s.empty? ? Time.now : Time.parse(resource[:updated_time])
              ).valid_state
            end
          end

          # Reload the stack resource data from the API
          #
          # @param resource [Models::Orchestration::Stack::Resource]
          # @return [Models::Orchestration::Resource]
          def resource_reload(resource)
            resource.stack.resources.reload
            resource.stack.resources.get(resource.id)
          end

          # Return all events for stack
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [Array<Models::Orchestration::Stack::Event>]
          def event_all(stack, marker = nil)
            params = marker ? {:marker => marker} : {}
            terraform_stack(stack).events.map do |event|
              Stack::Event.new(
                stack,
                :id => event[:id],
                :resource_id => event[:physical_resource_id],
                :resource_name => event[:resource_name],
                :resource_logical_id => event[:resource_name],
                :resource_state => event[:resource_status].downcase.to_sym,
                :resource_status => event[:resource_status],
                :resource_status_reason => event[:resource_status_reason],
                :time => Time.at(event[:timestamp] / 1000.0)
              ).valid_state
            end
          end

          # Return all new events for event collection
          #
          # @param events [Models::Orchestration::Stack::Events]
          # @return [Array<Models::Orchestration::Stack::Event>]
          def event_all_new(events)
            event_all(events.stack, events.all.first.id)
          end

          # Reload the stack event data from the API
          #
          # @param resource [Models::Orchestration::Stack::Event]
          # @return [Models::Orchestration::Event]
          def event_reload(event)
            event.stack.events.reload
            event.stack.events.get(event.id)
          end
        end

        module Boule
          # Save the stack
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [Models::Orchestration::Stack]
          def stack_save(stack)
            if(stack.persisted?)
              stack.load_data(stack.attributes)
              result = request(
                :method => :put,
                :path => "/terraform/stack/#{stack.name}",
                :json => {
                  :template => MultiJson.dump(stack.template),
                  :parameters => stack.parameters || {}
                }
              )
              stack.valid_state
            else
              stack.load_data(stack.attributes)
              result = request(
                :method => :post,
                :path => "/terraform/stack/#{stack.name}",
                :json => {
                  :template => MultiJson.dump(stack.template),
                  :parameters => stack.parameters || {}
                }
              )
              stack.id = result.get(:body, :stack, :id)
              stack.valid_state
            end
          end

          # Reload the stack data from the API
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [Models::Orchestration::Stack]
          def stack_reload(stack)
            if(stack.persisted?)
              result = request(
                :method => :get,
                :path => "/terraform/stack/#{stack.name}"
              )
              s = result.get(:body, :stack)
              stack.load_data(
                :id => s[:id],
                :created => s[:creation_time].to_s.empty? ? nil : Time.at(s[:creation_time].to_i / 1000.0),
                :description => s[:description],
                :name => s[:name],
                :state => s[:status].downcase.to_sym,
                :status => s[:status],
                :status_reason => s[:stack_status_reason],
                :updated => s[:updated_time].to_s.empty? ? nil : Time.at(s[:updated_time].to_i / 1000.0),
                :outputs => s[:outputs].map{|k,v| {:key => k, :value => v}}
              ).valid_state
            end
            stack
          end

          # Delete the stack
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [TrueClass, FalseClass]
          def stack_destroy(stack)
            if(stack.persisted?)
              request(
                :method => :delete,
                :path => "/terraform/stack/#{stack.name}"
              )
              true
            else
              false
            end
          end

          # Fetch stack template
          #
          # @param stack [Stack]
          # @return [Smash] stack template
          def stack_template_load(stack)
            if(stack.persisted?)
              result = request(
                :method => :get,
                :path => "/terraform/template/#{stack.name}"
              )
              result.fetch(:body, Smash.new)
            else
              Smash.new
            end
          end

          # Validate stack template
          #
          # @param stack [Stack]
          # @return [NilClass, String] nil if valid, string error message if invalid
          def stack_template_validate(stack)
            begin
              result = request(
                :method => :post,
                :path => '/terraform/validate',
                :json => Smash.new(
                  :template => stack.template
                )
              )
              nil
            rescue Error::ApiError::RequestError => e
              MultiJson.load(e.response.body.to_s).to_smash.get(:error, :message)
            end
          end

          # Return all stacks
          #
          # @param options [Hash] filter
          # @return [Array<Models::Orchestration::Stack>]
          # @todo check if we need any mappings on state set
          def stack_all(options={})
            result = request(
              :method => :get,
              :path => '/terraform/stacks'
            )
            result.fetch(:body, :stacks, []).map do |s|
              Stack.new(
                self,
                :id => s[:id],
                :created => s[:creation_time].to_s.empty? ? nil : Time.at(s[:creation_time].to_i / 1000.0),
                :description => s[:description],
                :name => s[:name],
                :state => s[:status].downcase.to_sym,
                :status => s[:status],
                :status_reason => s[:stack_status_reason],
                :updated => s[:updated_time].to_s.empty? ? nil : Time.at(s[:updated_time].to_i / 1000.0)
              ).valid_state
            end
          end

          # Return all resources for stack
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [Array<Models::Orchestration::Stack::Resource>]
          def resource_all(stack)
            result = request(
              :method => :get,
              :path => "/terraform/resources/#{stack.name}"
            )
            result.fetch(:body, :resources, []).map do |resource|
              Stack::Resource.new(
                stack,
                :id => resource[:physical_id],
                :name => resource[:name],
                :type => resource[:type],
                :logical_id => resource[:name],
                :state => resource[:status].downcase.to_sym,
                :status => resource[:status],
                :status_reason => resource[:resource_status_reason],
                :updated => resource[:updated_time].to_s.empty? ? Time.now : Time.parse(resource[:updated_time])
              ).valid_state
            end
          end

          # Reload the stack resource data from the API
          #
          # @param resource [Models::Orchestration::Stack::Resource]
          # @return [Models::Orchestration::Resource]
          def resource_reload(resource)
            resource.stack.resources.reload
            resource.stack.resources.get(resource.id)
          end

          # Return all events for stack
          #
          # @param stack [Models::Orchestration::Stack]
          # @return [Array<Models::Orchestration::Stack::Event>]
          def event_all(stack, marker = nil)
            params = marker ? {:marker => marker} : {}
            result = request(
              :path => "/terraform/events/#{stack.name}",
              :method => :get,
              :params => params
            )
            result.fetch(:body, :events, []).map do |event|
              Stack::Event.new(
                stack,
                :id => event[:id],
                :resource_id => event[:physical_resource_id],
                :resource_name => event[:resource_name],
                :resource_logical_id => event[:resource_name],
                :resource_state => event[:resource_status].downcase.to_sym,
                :resource_status => event[:resource_status],
                :resource_status_reason => event[:resource_status_reason],
                :time => Time.at(event[:timestamp] / 1000.0)
              ).valid_state
            end
          end

          # Return all new events for event collection
          #
          # @param events [Models::Orchestration::Stack::Events]
          # @return [Array<Models::Orchestration::Stack::Event>]
          def event_all_new(events)
            event_all(events.stack, events.all.first.id)
          end

          # Reload the stack event data from the API
          #
          # @param resource [Models::Orchestration::Stack::Event]
          # @return [Models::Orchestration::Event]
          def event_reload(event)
            event.stack.events.reload
            event.stack.events.get(event.id)
          end
        end

      end
    end
  end
end
