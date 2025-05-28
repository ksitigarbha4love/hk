require 'yaml'
require 'uri' # For URI.join

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

    # Loads a single template file.
    # Returns a data structure representing the parsed template, or nil on failure.
    # Internal puts are commented out as errors will be collected by load_from_path.
    def load(template_path)
      unless File.exist?(template_path)
        # puts @pastel.red("TemplateEngine Error: File not found - #{template_path}") 
        return nil # Error handled by caller like load_from_path
      end
      ext = File.extname(template_path).downcase
      
      case ext
      when '.yml', '.yaml'
        begin
          yaml_data = YAML.safe_load_file(template_path, permitted_classes: [Symbol], aliases: true) 
        rescue Psych::Exception => e
          # puts @pastel.red("TemplateEngine Error: Failed to parse YAML file #{template_path} - #{e.message}")
          return nil 
        end

        unless yaml_data.is_a?(Hash) && yaml_data['info'].is_a?(Hash) && yaml_data['requests'].is_a?(Array)
          # puts @pastel.red("TemplateEngine Error: Invalid YAML structure in #{template_path}. Missing 'info' or 'requests'.")
          return nil
        end
        
        template_id = yaml_data['id'] || File.basename(template_path, ".*")
        
        info = yaml_data['info']
        unless info['name'] && info['severity']
            # puts @pastel.red("TemplateEngine Error: Missing 'name' or 'severity' in 'info' block for template ID '#{template_id}'.")
            return nil
        end
        { type: :yaml, path: template_path, id: template_id, data: yaml_data }
      when '.rb'
        template_id = File.basename(template_path, ".*")
        begin
          # HK::TemplateRegistry.clear! # Potentially dangerous here if loading multiple .rb files from a dir
          Kernel.load template_path 
        rescue Exception => e 
          # puts @pastel.red("TemplateEngine Error: Failed to load Ruby template file #{template_path} - #{e.class.name}: #{e.message}")
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
        # puts @pastel.yellow("TemplateEngine Warning: Unknown template type for extension '#{ext}' - #{template_path}")
        nil
      end
    end
    
    # Loads templates from a given file path or a directory.
    # Returns a hash like { loaded_templates: [], errors: [] }
    def load_from_path(path_or_directory)
      loaded_templates = []
      errors = []

      unless File.exist?(path_or_directory)
        errors << "Path does not exist: #{path_or_directory}"
        # puts @pastel.red("TemplateEngine Error: Path does not exist - #{path_or_directory}") # Verbose logging
        return { loaded_templates: loaded_templates, errors: errors }
      end

      if File.file?(path_or_directory)
        # puts @pastel.dim("  TemplateEngine: Loading single template file: #{path_or_directory}")
        template_definition = load(path_or_directory) 
        if template_definition
          loaded_templates << template_definition
        else
          errors << "Failed to load or parse template file: #{path_or_directory}"
        end
      elsif File.directory?(path_or_directory)
        # puts @pastel.dim("  TemplateEngine: Loading templates from directory: #{path_or_directory}")
        Dir.new(path_or_directory).children.each do |entry| # Using Dir.new().children as specified in prompt
            file_path = File.join(path_or_directory, entry)
            next unless File.file?(file_path) 

            ext = File.extname(file_path).downcase
            if ['.yml', '.yaml', '.rb'].include?(ext)
              # puts @pastel.dim("    Found template candidate: #{file_path}")
              template_definition = load(file_path)
              if template_definition
                loaded_templates << template_definition
              else
                # load method itself might print specific errors, or we can add generic one.
                errors << "Failed to load or parse template file: #{file_path}"
              end
            end
        end
        # This warning about no supported files might be too noisy if a directory legitimately has other files.
        # The prompt includes a check here:
        # if loaded_templates.empty? && Dir.glob(File.join(path_or_directory, "*.{yml,yaml,rb}")).none?
        #      puts @pastel.yellow("TemplateEngine Warning: No supported template files (.yml, .yaml, .rb) found in directory: #{path_or_directory}")
        # end
        # I will add this check to the errors array if it's relevant
        if loaded_templates.empty? && errors.empty? && Dir.glob(File.join(path_or_directory, "*.{yml,yaml,rb}")).none?
          errors << "No supported template files (.yml, .yaml, .rb) found in directory: #{path_or_directory}"
        end
      else
        errors << "Path is not a file or directory: #{path_or_directory}"
        # puts @pastel.red("TemplateEngine Error: Path is not a file or directory - #{path_or_directory}")
      end
      
      { loaded_templates: loaded_templates, errors: errors }
    end

    def execute(parsed_template, target_url)
      unless parsed_template && target_url
        # puts @pastel.red("TemplateEngine Error: Invalid arguments for execute.")
        return { success: false, findings: [], errors: ["Invalid arguments"] }
      end

      case parsed_template[:type]
      when :yaml
        execute_yaml_template(parsed_template, target_url)
      when :ruby
        execute_ruby_template(parsed_template, target_url)
      else
        # puts @pastel.red("TemplateEngine Error: Cannot execute unknown template type.")
        { success: false, findings: [], errors: ["Unknown template type for execution"] }
      end
    end

    def run(template_path, target_url)
      # This method is for running a single template file.
      # For running multiple templates from a directory, the caller should use
      # load_from_path and then iterate through the loaded_templates to execute them.
      parsed_template = load(template_path) 
      if parsed_template
        execute(parsed_template, target_url)
      else
        { success: false, findings: [], errors: ["Failed to load template: #{template_path}"] }
      end
    end

    private

    def execute_yaml_template(parsed_template, target_url)
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

    def execute_ruby_template(parsed_template, target_url)
      definition = parsed_template[:definition]
      execute_block = definition.execute_block
      
      unless execute_block.is_a?(Proc)
        return { success: false, findings: [], errors: ["Execute block not defined or not a Proc for Ruby template: #{definition.id}"] }
      end

      @web_client ||= HK::Web::Client.new 
      http_client_wrapper = HK::Http::ClientWrapper.new(@web_client, target_url)
      
      findings = []
      errors = []
      success = false

      begin
        result = execute_block.call(target_url, http_client_wrapper, definition.info_attrs)
        if result.is_a?(Hash)
          findings.concat(Array(result[:findings])) if result[:findings]
          errors.concat(Array(result[:errors])) if result[:errors]
        end
        success = true 
      rescue StandardError => e
        errors << "Exception during Ruby template '#{definition.id}' execution: #{e.class.name} - #{e.message}\n#{e.backtrace.join("\n  ")}"
        success = false
      end
      { success: success, findings: findings, errors: errors }
    end
  end
end
