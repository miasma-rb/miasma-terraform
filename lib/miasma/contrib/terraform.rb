require 'miasma'

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
            # attribute
          end
        end
      end

    end
  end

  Models::Orchestration.autoload :Terraform, 'miasma/contrib/terraform/orchestration'
end
