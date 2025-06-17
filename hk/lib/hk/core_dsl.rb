# lib/hk/core_dsl.rb
module HK
  module TemplateRegistry
    @templates = {}

    def self.register(template_definition)
      unless template_definition.is_a?(RubyTemplateDefinition) && template_definition.id
        HK.logger.error "Error: Invalid template definition passed to registry." if HK.logger
        return
      end
      HK.logger.debug "Registering Ruby template: #{template_definition.id}" if HK.logger
      @templates[template_definition.id.to_s] = template_definition
    end

    def self.find(id)
      @templates[id.to_s]
    end

    def self.all_templates
        @templates
    end

    def self.clear!
        HK.logger.debug "Clearing TemplateRegistry." if HK.logger
        @templates = {}
    end
  end

  class RubyTemplateDefinition
    attr_reader :id, :info_attrs, :execute_block, :payload_sets, :target_condition_block, :payload_cache # Added payload_cache

    class FindingReporter # From turn 153
      attr_reader :base_template_info, :base_target_url, :findings

      def initialize(base_template_info, base_target_url)
        @base_template_info = base_template_info; @base_target_url = base_target_url; @findings = []
      end
      def report(details_hash = {})
        finding = { template_id: @base_template_info[:id], template_name: @base_template_info[:name], severity: @base_template_info[:severity], target_url: @base_target_url }.merge(details_hash)
        finding[:name] ||= @base_template_info[:name]; finding[:severity] ||= @base_template_info[:severity]; finding[:matched_at_url] ||= @base_target_url
        @findings << finding
      end
    end

    def initialize(id)
      @id = id.to_s
      @info_attrs = { name: "Unnamed Ruby Template", severity: "info", id: @id }
      @payload_sets = {}
      @target_condition_block = nil
      @payload_cache = {} # Initialize payload_cache

      @execute_block = proc { |target_url, client, reporter, payload| # Added payload argument
        default_id = @id
        reporter.report(description: "Warning: Execute block not defined for #{default_id}. Payload: #{payload.inspect}", severity: "debug")
      }
    end

    def info(details = {})
      @info_attrs.merge!(details)
    end

    def payloads(name, &block)
      @payload_sets[name.to_sym] = block if block_given?
    end

    def target(target_type = :url, &block)
      @target_condition_block = block if block_given?
    end

    def execute(&block)
      @execute_block = block if block_given?
    end

    # New get_payloads method as per current task description
    def get_payloads(name_param)
      name = name_param.to_sym
      return @payload_cache[name] if @payload_cache.key?(name)

      payload_proc = @payload_sets[name]
      if payload_proc.is_a?(Proc)
        begin
          payload_data = payload_proc.call
          @payload_cache[name] = Array(payload_data) # Ensure it's an array and cache
          return @payload_cache[name]
        rescue StandardError => e
          HK.logger.error "Error generating payloads for set ':#{name}' in template '#{@id}': #{e.class.name} - #{e.message}" if HK.logger
          @payload_cache[name] = [] # Cache empty array on error
          return @payload_cache[name]
        end
      else
        HK.logger.warn "Payload set ':#{name}' not found or not a Proc in template '#{@id}'." if HK.logger
        @payload_cache[name] = [] # Cache empty array if not found / not a Proc
        return @payload_cache[name]
      end
    end
  end

  def self.template(id, &block)
    definition = RubyTemplateDefinition.new(id)
    definition.instance_eval(&block) if block_given?
    TemplateRegistry.register(definition)
    definition
  end
end
