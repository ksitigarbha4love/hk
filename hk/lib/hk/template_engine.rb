require 'yaml'
require 'uri' # For URI.join
# require 'hk/http/client_wrapper' # Should be loaded by hk.rb
# require 'hk/core_dsl' # Should be loaded by hk.rb

module HK
  class TemplateEngine
    attr_reader :options 

    def initialize(options = {})
      @options = options
      if defined?(TTY::Color)
        @pastel = TTY::Color
      else
        @pastel = Object.new
        def @pastel.method_missing(*args, &block); args.first; end
        def @pastel.respond_to_missing?(method_name, include_private = false); true; end
      end
      @web_client ||= HK::Web::Client.new 
      @loaded_templates = {} 
    end

    def load(template_path)
      unless File.exist?(template_path)
        return nil 
      end
      ext = File.extname(template_path).downcase
      
      case ext
      when '.yml', '.yaml'
        begin
          yaml_data = YAML.safe_load_file(template_path, permitted_classes: [Symbol], aliases: true) 
        rescue Psych::Exception => e
          return nil 
        end

        unless yaml_data.is_a?(Hash) && yaml_data['info'].is_a?(Hash) && yaml_data['requests'].is_a?(Array)
          return nil
        end
        
        template_id = yaml_data['id'] || File.basename(template_path, ".*")
        
        info = yaml_data['info']
        unless info['name'] && info['severity']
            return nil
        end
        { type: :yaml, path: template_path, id: template_id, data: yaml_data }
      when '.rb'
        template_id = File.basename(template_path, ".*")
        begin
          # Clear previous definition for this ID before loading, to allow hot-reloading/changes.
          # This makes sense if TemplateRegistry is a global cache across multiple loads in one engine instance.
          HK::TemplateRegistry.instance_variable_get(:@templates).delete(template_id)
          Kernel.load template_path 
        rescue Exception => e 
          # puts @pastel.red("TemplateEngine Error: Failed to load Ruby template file #{template_path} - #{e.class.name}: #{e.message}") # Keep error logging if desired
          return nil
        end
        
        definition = HK::TemplateRegistry.find(template_id)
        if definition
          { type: :ruby, path: template_path, id: template_id, definition: definition }
        else
          # puts @pastel.red("TemplateEngine Error: Ruby file #{template_path} loaded, but no template with ID '#{template_id}' was registered.")
          nil
        end
      else
        nil
      end
    end
    
    def load_from_path(path_or_directory)
      loaded_templates = []
      errors = []

      unless File.exist?(path_or_directory)
        errors << "Path does not exist: #{path_or_directory}"
        return { loaded_templates: loaded_templates, errors: errors }
      end

      if File.file?(path_or_directory)
        template_definition = load(path_or_directory) 
        if template_definition
          loaded_templates << template_definition
        else
          errors << "Failed to load or parse template file: #{path_or_directory}"
        end
      elsif File.directory?(path_or_directory)
        Dir.new(path_or_directory).children.each do |entry| 
            file_path = File.join(path_or_directory, entry)
            next unless File.file?(file_path) 

            ext = File.extname(file_path).downcase
            if ['.yml', '.yaml', '.rb'].include?(ext)
              template_definition = load(file_path)
              if template_definition
                loaded_templates << template_definition
              else
                errors << "Failed to load or parse template file: #{file_path}"
              end
            end
        end
        if loaded_templates.empty? && errors.empty? && Dir.glob(File.join(path_or_directory, "*.{yml,yaml,rb}")).none?
          errors << "No supported template files (.yml, .yaml, .rb) found in directory: #{path_or_directory}"
        end
      else
        errors << "Path is not a file or directory: #{path_or_directory}"
      end
      
      { loaded_templates: loaded_templates, errors: errors }
    end

    def execute(parsed_template, target_url)
      unless parsed_template && target_url
        return { success: false, findings: [], errors: ["Invalid arguments"] }
      end

      case parsed_template[:type]
      when :yaml
        execute_yaml_template(parsed_template, target_url)
      when :ruby
        execute_ruby_template(parsed_template, target_url) # Updated call
      else
        { success: false, findings: [], errors: ["Unknown template type for execution"] }
      end
    end

    def run(template_path, target_url)
      parsed_template = load(template_path) 
      if parsed_template
        execute(parsed_template, target_url)
      else
        { success: false, findings: [], errors: ["Failed to load template: #{template_path}"] }
      end
    end

    private

    def execute_yaml_template(parsed_template, target_url)
      # ... (implementation from turn 157, remains unchanged)
      template_data = parsed_template[:data]
      template_info = template_data['info']
      findings = []
      errors = []
      
      template_data['requests'].each_with_index do |req_def, index|
        method = req_def.fetch('method', 'GET').upcase
        path = req_def['path']
        
        unless path
          errors << { request_index: index, error: "Request definition missing 'path'." }
          next
        end

        base_uri_for_join = target_url
        base_uri_for_join += '/' if !target_url.end_with?('/') && !path.start_with?('/') && path != ""
        full_url = URI.join(base_uri_for_join, path.gsub('{{BaseURL}}', target_url)).to_s
            
        client_options = { timeout: @options.fetch(:timeout, 5) }
        client_options[:headers] = @options[:headers] if @options[:headers] 
        
        probe_result = @web_client.probe(full_url, client_options)

        if probe_result[:error]
          errors << { request_index: index, url: full_url, error: "Probe failed: #{probe_result[:error]}" }
          next
        end
        unless probe_result[:body] 
          errors << { request_index: index, url: full_url, error: "Response body is empty or missing."}
          next
        end

        matchers = req_def.fetch('matchers', [])
        matchers_condition_is_and = req_def.fetch('matchers-condition', 'and').downcase == 'and'
        current_request_match_results = []

        matchers.each do |matcher_def|
          matcher_type = matcher_def.fetch('type', '').downcase
          matcher_part = matcher_def.fetch('part', 'body').downcase
          content_to_check = ""
          if matcher_part == 'body'
            content_to_check = probe_result[:body] || ""
          elsif matcher_part == 'header'
            content_to_check = probe_result[:raw_headers]&.map{|k,v| "#{k}: #{v}"}&.join("\n") || ""
          else 
            content_to_check = probe_result[:body] || "" 
          end

          if matcher_type == 'word'
            words_to_match = Array(matcher_def['words'])
            all_words_found_for_this_matcher = words_to_match.all? { |word| content_to_check.include?(word) }
            current_request_match_results << all_words_found_for_this_matcher
          end
        end
        
        final_match_for_request = false
        if matchers.empty? 
            final_match_for_request = true 
        elsif matchers_condition_is_and 
          final_match_for_request = current_request_match_results.all? { |r| r == true }
        else 
          final_match_for_request = current_request_match_results.any? { |r| r == true }
        end

        if final_match_for_request
          findings << {
            template_id: parsed_template[:id],
            template_name: template_info['name'],
            severity: template_info['severity'],
            target_url: target_url, 
            matched_at_url: full_url, 
            description: "Matched based on template criteria." 
          }
        end
      end
      { success: true, findings: findings, errors: errors }
    end

    # Updated execute_ruby_template method
    def execute_ruby_template(parsed_template, target_url)
      definition = parsed_template[:definition]
      execute_block = definition.execute_block
      
      unless execute_block.is_a?(Proc)
        return { success: false, findings: [], errors: ["Execute block not defined or not a Proc for Ruby template: #{definition.id}"] }
      end

      # Conceptually check target conditions before execution
      # if definition.target_condition_block && ! _check_target_conditions(target_url, definition.target_condition_block)
      #   return { success: true, findings: [], errors: ["Target does not meet conditions for template #{definition.id}"] }
      # end

      @web_client ||= HK::Web::Client.new 
      # Pass the base target_url to the wrapper. The wrapper's get/post methods will join paths.
      http_client_wrapper = HK::Http::ClientWrapper.new(@web_client, target_url) 
      
      # Create a reporter instance, passing the template's own info attributes
      # and the main target_url for this execution run.
      # The RubyTemplateDefinition#info_attrs now includes :id.
      reporter = HK::RubyTemplateDefinition::FindingReporter.new(definition.info_attrs, target_url)
      
      errors = []
      success = false

      begin
        # The execute block now receives the reporter instance.
        # It no longer directly receives template_info; it's part of the reporter.
        # The block is responsible for calling reporter.report(details)
        # The block can also return a hash with :errors or :findings, but using reporter is preferred.
        # The prompt implies the block itself might not return anything, relying on reporter.
        # For now, we'll capture what it *does* return and also what reporter collects.
        
        # Make payload sets available to the execute_block if needed.
        # This could be done by passing them, or by making them accessible via the `http_client_wrapper` or `reporter`,
        # or by instance_exec'ing the block on an object that has access to them.
        # For now, the block doesn't explicitly receive payload_sets.
        # It would access them via `definition.payload_sets` if it had `definition` or if instance_eval'd.
        # The current call signature is: call(target_url, http_client_wrapper, reporter)

        block_result = execute_block.call(target_url, http_client_wrapper, reporter)
        
        # Collect findings from the reporter
        findings = reporter.findings # Use the reader for findings from reporter

        # Handle errors returned by the block itself, if any (optional pattern)
        if block_result.is_a?(Hash) && block_result[:errors]
          errors.concat(Array(block_result[:errors]))
        end
        # If block_result also has :findings, they are ignored in favor of reporter.findings for consistency.

        success = true 
      rescue StandardError => e
        errors << "Exception during Ruby template '#{definition.id}' execution: #{e.class.name} - #{e.message}\n#{e.backtrace.first(3).join("\n  ")}"
        success = false
        findings = reporter.findings # Still collect any findings reported before the exception
      end
      { success: success, findings: findings, errors: errors }
    end

    # Placeholder for target condition checking (not fully implemented in this step)
    # def _check_target_conditions(target_url, condition_block)
    #   # This would parse target_url into components (scheme, host, port, path, query)
    #   # and pass them to the condition_block.
    #   # For now, assume it passes.
    #   # url_components = { host: URI.parse(target_url).host, ... }
    #   # return condition_block.call(url_components)
    #   true 
    # end
  end
end
