# lib/hk/core_dsl.rb
module HK
  # Simple registry for Ruby DSL templates
  module TemplateRegistry
    @templates = {} # Class instance variable to store templates

    def self.register(template_definition)
      unless template_definition.is_a?(RubyTemplateDefinition) && template_definition.id
        # Maybe raise an error or log a warning
        puts "Error: Invalid template definition passed to registry." # Consider using @pastel if available
        return
      end
      # puts "Registering Ruby template: #{template_definition.id}"
      @templates[template_definition.id.to_s] = template_definition
    end

    def self.find(id)
      @templates[id.to_s]
    end

    def self.all_templates
        @templates
    end
    
    def self.clear! # For testing
        @templates = {}
    end
  end

  class RubyTemplateDefinition
    attr_reader :id, :info_attrs, :execute_block

    def initialize(id)
      @id = id.to_s
      @info_attrs = { name: "Unnamed Ruby Template", severity: "info" } # Defaults
      # Default execute_block should ideally accept the arguments it's meant to
      @execute_block = proc { |target_url, client| 
        # Accessing @id directly here might be tricky if this proc is unbound later.
        # Better to pass id or use a method that has access to @id if needed for the warning.
        # For now, keeping it simple.
        default_id = @id # Capture @id in the proc's closure
        puts "Warning: Execute block not defined for #{default_id}" 
      }
    end

    # DSL method to set template metadata
    def info(details = {})
      @info_attrs.merge!(details)
    end

    # DSL method to define the execution logic
    # The block will receive target_url and an http_client instance
    def execute(&block)
      @execute_block = block if block_given?
    end
    
    # Potentially other DSL methods like target_conditions, payloads etc. can be added later
  end

  # Entry point for the Ruby Template DSL
  def self.template(id, &block)
    definition = RubyTemplateDefinition.new(id)
    # Execute the block in the context of the definition instance
    # Using instance_exec allows passing arguments to the block if needed,
    # but for this DSL style, instance_eval is more common.
    definition.instance_eval(&block) if block_given? 
    TemplateRegistry.register(definition)
    definition # Return the definition for potential chaining or inspection
  end
end
