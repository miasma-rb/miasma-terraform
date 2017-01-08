require 'miasma'
require 'miasma-terraform'

module Miasma
  module Contrib

    # Terraform API core helper
    class TerraformApiCore

      # Common API methods
      module ApiCommon

        # Set attributes into model
        #
        # @param klass [Class]
        def self.included(klass)
          klass.class_eval do
            attribute :terraform_driver, String, :required => true,
                      :allowed_values => ['atlas', 'boule', 'local'], :default => 'local',
                      :coerce => lambda{|v| v.to_s }
            # Attributes required for Atlas driver
            attribute :terraform_atlas_endpoint, String
            attribute :terraform_atlas_token, String
            # Attributes required for Boule driver
            attribute :terraform_boule_endpoint, String
            # Attributes required for local driver
            attribute :terraform_local_directory, String
            attribute :terraform_local_scrub_destroyed, [TrueClass, FalseClass], :default => false
          end
        end

        def custom_setup(creds)
          begin
            driver_module = Miasma::Models::Orchestration::Terraform.const_get(
              Bogo::Utility.camel(creds[:terraform_driver].to_s)
            )
            extend driver_module
          rescue NameError
            raise NotImplementedError.new "Requested driver not implemented `#{creds[:terraform_driver]}`"
          end
        end

        def endpoint
          terraform_boule_endpoint
        end
      end

    end
  end

  Models::Orchestration.autoload :Terraform, 'miasma/contrib/terraform/orchestration'
end
