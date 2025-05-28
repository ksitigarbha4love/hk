# lib/hk/core_dsl.rb
module HK
  module TemplateRegistry
    @templates = {} 

    def self.register(template_definition)
      unless template_definition.is_a?(RubyTemplateDefinition) && template_definition.id
        puts "Error: Invalid template definition passed to registry."
        return
      end
      @templates[template_definition.id.to_s] = template_definition
    end

    def self.find(id)
      @templates[id.to_s]
    end

    def self.all_templates
        @templates
    end
    
    def self.clear! 
        @templates = {}
    end
  end

  class RubyTemplateDefinition
    attr_reader :id, :info_attrs, :execute_block, :payload_sets, :target_condition_block # Added

    # Inner class for reporting findings from within execute block
    class FindingReporter
      attr_reader :base_template_info, :base_target_url
      
      def initialize(base_template_info, base_target_url)
        @base_template_info = base_template_info
        @base_target_url = base_target_url
        @findings = [] # Accumulates findings reported by this instance
      end

      # details_hash can include: :matched_at_url, :description, :evidence, etc.
      # It can also override :severity or :name if needed for a specific finding.
      def report(details_hash = {})
        finding = {
          template_id: @base_template_info[:id], # id from RubyTemplateDefinition
          template_name: @base_template_info[:name],
          severity: @base_template_info[:severity],
          target_url: @base_target_url # The main target URL for this execution run
        }.merge(details_hash) # Merge specific details from the report call
        
        # Ensure required fields for a finding are present if overridden
        finding[:name] ||= @base_template_info[:name] 
        finding[:severity] ||= @base_template_info[:severity]
        finding[:matched_at_url] ||= @base_target_url # Default matched_at to base_target_url

        @findings << finding
        # Optionally, puts "Finding reported by #{base_template_info[:id]}: #{details_hash[:description]}"
      end
      
      # Allows the execute block to retrieve all findings it has reported
      def all_reported_findings
        @findings
      end
    end


    def initialize(id)
      @id = id.to_s
      @info_attrs = { name: "Unnamed Ruby Template", severity: "info", id: @id } # Added id to info_attrs
      @payload_sets = {} # Initialize
      @target_condition_block = nil # Initialize
      
      @execute_block = proc { |target_url, client, reporter| 
        default_id = @id 
        # Default execute block now uses the reporter
        reporter.report(description: "Warning: Execute block not defined for #{default_id}", severity: "debug")
      }
    end

    def info(details = {})
      @info_attrs.merge!(details)
    end

    # New DSL method for defining named payload sets
    def payloads(name, &block)
      # The block is expected to return an array or enumerable of payloads
      @payload_sets[name.to_sym] = block if block_given?
    end

    # New DSL method for defining target conditions
    # target_type is a placeholder for future use (e.g. :host, :ip_range)
    def target(target_type = :url, &block)
      @target_condition_block = block if block_given?
    end

    # Execute block now receives a FindingReporter instance
    def execute(&block)
      @execute_block = block if block_given?
    end
  end

  def self.template(id, &block)
    definition = RubyTemplateDefinition.new(id)
    definition.instance_eval(&block) if block_given? 
    TemplateRegistry.register(definition)
    definition 
  end
end
