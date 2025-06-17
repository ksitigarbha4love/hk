require 'yaml'
require 'uri'

module HK
  class TemplateEngine
    attr_reader :options

    def initialize(options = {})
      @options = options
      # @pastel is not used here anymore, HK.logger handles formatting/coloring.
      @web_client ||= HK::Web::Client.new
      @loaded_templates = {}
      HK.logger.debug "HK::TemplateEngine initialized with options: #{options}"
    end

    def load(template_path)
      unless File.exist?(template_path)
        # HK.logger.error "TemplateEngine Error: File not found - #{template_path}" # Logged by load_from_path
        return nil
      end
      ext = File.extname(template_path).downcase
      HK.logger.debug "TemplateEngine: Attempting to load template: #{template_path}, type: #{ext}"

      case ext
      when '.yml', '.yaml'
        begin
          yaml_data = YAML.safe_load_file(template_path, permitted_classes: [Symbol], aliases: true)
        rescue Psych::Exception => e
          # HK.logger.error "TemplateEngine Error: Failed to parse YAML file #{template_path} - #{e.message}"
          return nil
        end

        unless yaml_data.is_a?(Hash) && yaml_data['info'].is_a?(Hash) && yaml_data['requests'].is_a?(Array)
          # HK.logger.error "TemplateEngine Error: Invalid YAML structure in #{template_path}. Missing 'info' or 'requests'."
          return nil
        end

        template_id = yaml_data['id'] || File.basename(template_path, ".*")

        info = yaml_data['info']
        unless info['name'] && info['severity']
            # HK.logger.error "TemplateEngine Error: Missing 'name' or 'severity' in 'info' block for template ID '#{template_id}'."
            return nil
        end
        HK.logger.debug "YAML template '#{template_id}' loaded and parsed successfully from #{template_path}"
        { type: :yaml, path: template_path, id: template_id, data: yaml_data }
      when '.rb'
        template_id = File.basename(template_path, ".*")
        begin
          HK::TemplateRegistry.instance_variable_get(:@templates).delete(template_id)
          Kernel.load template_path
        rescue Exception => e
          # HK.logger.error "TemplateEngine Error: Failed to load Ruby template file #{template_path} - #{e.class.name}: #{e.message}"
          return nil
        end

        definition = HK::TemplateRegistry.find(template_id)
        if definition
          HK.logger.debug "Ruby template '#{template_id}' loaded and definition found from #{template_path}"
          { type: :ruby, path: template_path, id: template_id, definition: definition }
        else
          # HK.logger.error "TemplateEngine Error: Ruby file #{template_path} loaded, but no template with ID '#{template_id}' was registered."
          nil
        end
      else
        # HK.logger.warn "TemplateEngine Warning: Unknown template type for extension '#{ext}' - #{template_path}"
        nil
      end
    end

    def load_from_path(path_or_directory)
      loaded_templates = []; errors = []
      unless File.exist?(path_or_directory); errors << "Path does not exist: #{path_or_directory}"; HK.logger.error "TemplateEngine: Path does not exist - #{path_or_directory}"; return { loaded_templates: loaded_templates, errors: errors }; end
      if File.file?(path_or_directory)
        HK.logger.debug "TemplateEngine: Loading single template file: #{path_or_directory}"
        template_definition = load(path_or_directory)
        if template_definition; loaded_templates << template_definition; else; error_msg = "Failed to load or parse template file: #{path_or_directory}"; errors << error_msg; HK.logger.warn error_msg; end
      elsif File.directory?(path_or_directory)
        HK.logger.debug "TemplateEngine: Loading templates from directory: #{path_or_directory}"
        Dir.new(path_or_directory).children.each do |entry|
            file_path = File.join(path_or_directory, entry); next unless File.file?(file_path)
            ext = File.extname(file_path).downcase
            if ['.yml', '.yaml', '.rb'].include?(ext)
              HK.logger.debug "Found template candidate: #{file_path}"
              template_definition = load(file_path)
              if template_definition; loaded_templates << template_definition; else; error_msg = "Failed to load or parse template file: #{file_path}"; errors << error_msg; HK.logger.warn error_msg; end
            end
        end
        if loaded_templates.empty? && errors.empty? && Dir.glob(File.join(path_or_directory, "*.{yml,yaml,rb}")).none?
          # errors << "No supported template files (.yml, .yaml, .rb) found in directory: #{path_or_directory}" # Retained my logic for error reporting
          # HK.logger.warn "TemplateEngine: No supported template files found in directory: #{path_or_directory}"
        end
      else; error_msg = "Path is not a file or directory: #{path_or_directory}"; errors << error_msg; HK.logger.error "TemplateEngine: #{error_msg}"; end
      { loaded_templates: loaded_templates, errors: errors }
    end

    def execute(parsed_template, target_url)
      unless parsed_template && target_url; HK.logger.error "TemplateEngine Error: Invalid arguments for execute."; return { success: false, findings: [], errors: ["Invalid arguments"] }; end
      HK.logger.debug "TemplateEngine: Executing template '#{parsed_template[:id]}' (#{parsed_template[:type]}) against target: #{target_url}"

      case parsed_template[:type]
      when :yaml; execute_yaml_template(parsed_template, target_url)
      when :ruby; execute_ruby_template(parsed_template, target_url)
      else; HK.logger.error "TemplateEngine Error: Cannot execute unknown template type."; { success: false, findings: [], errors: ["Unknown template type for execution"] }; end
    end

    def run(template_path, target_url)
      HK.logger.info "TemplateEngine: Running template '#{template_path}' against '#{target_url}'"
      parsed_template = load(template_path);
      if parsed_template; execute(parsed_template, target_url); else; error_msg = "Failed to load template: #{template_path}"; HK.logger.error error_msg; { success: false, findings: [], errors: [error_msg] }; end
    end

    private

    def execute_yaml_template(parsed_template, target_url)
      template_data = parsed_template[:data]; template_info = template_data['info']; findings = []; errors = []
      HK.logger.debug "Executing YAML template: #{template_info['name']} (ID: #{parsed_template[:id]})"
      template_data['requests'].each_with_index do |req_def, index|
        # ... (existing logic from turn 157, adding logging within) ...
        method = req_def.fetch('method', 'GET').upcase; path = req_def['path']
        unless path; errors << { request_index: index, error: "Request definition missing 'path'." }; HK.logger.warn "YAML Req ##{index} for #{parsed_template[:id]}: Missing path."; next; end

        base_uri_for_join = target_url; base_uri_for_join += '/' if !target_url.end_with?('/') && !path.start_with?('/') && path != ""; full_url = URI.join(base_uri_for_join, path.gsub('{{BaseURL}}', target_url)).to_s
        HK.logger.debug "  Requesting: #{method} #{full_url}"
        client_options = { timeout: @options.fetch(:timeout, 5) }; client_options[:headers] = @options[:headers] if @options[:headers]
        probe_result = @web_client.probe(full_url, client_options)

        if probe_result[:error]; errors << { request_index: index, url: full_url, error: "Probe failed: #{probe_result[:error]}" }; HK.logger.warn "  Probe failed for #{full_url}: #{probe_result[:error]}"; next; end
        unless probe_result[:body]; errors << { request_index: index, url: full_url, error: "Response body is empty or missing."}; HK.logger.warn "  Response body empty for #{full_url}."; next; end

        # ... (matcher logic) ...
        matchers = req_def.fetch('matchers', []); matchers_condition_is_and = req_def.fetch('matchers-condition', 'and').downcase == 'and'; current_request_match_results = []
        matchers.each do |matcher_def| # ... (matcher logic as before) ...
          matcher_type = matcher_def.fetch('type', '').downcase; matcher_part = matcher_def.fetch('part', 'body').downcase
          content_to_check = ""; if matcher_part == 'body'; content_to_check = probe_result[:body] || ""; elsif matcher_part == 'header'; content_to_check = probe_result[:raw_headers]&.map{|k,v| "#{k}: #{v}"}&.join("\n") || ""; else; content_to_check = probe_result[:body] || ""; end
          if matcher_type == 'word'; words_to_match = Array(matcher_def['words']); all_words_found_for_this_matcher = words_to_match.all? { |word| content_to_check.include?(word) }; current_request_match_results << all_words_found_for_this_matcher; HK.logger.debug "    Matcher 'word' on '#{matcher_part}' for words '#{words_to_match.join(',')}': #{all_words_found_for_this_matcher}"; end
        end
        final_match_for_request = false; if matchers.empty?; final_match_for_request = true; elsif matchers_condition_is_and; final_match_for_request = current_request_match_results.all? { |r| r == true }; else; final_match_for_request = current_request_match_results.any? { |r| r == true }; end

        if final_match_for_request
          finding_detail = { template_id: parsed_template[:id], template_name: template_info['name'], severity: template_info['severity'], target_url: target_url, matched_at_url: full_url, description: "Matched based on template criteria." }
          findings << finding_detail
          HK.logger.info "Finding reported by YAML template '#{parsed_template[:id]}': #{finding_detail[:description]} at #{full_url}"
        end
      end
      { success: true, findings: findings, errors: errors }
    end

    def execute_ruby_template(parsed_template, target_url) # Logic from turn 158
      definition = parsed_template[:definition]; execute_block = definition.execute_block
      unless execute_block.is_a?(Proc); return { success: false, findings: [], errors: ["Execute block not defined or not a Proc for Ruby template: #{definition.id}"] }; end
      unless _check_target_conditions(target_url, definition); return { success: true, findings: [], errors: ["Target does not meet conditions for template #{definition.id} (Skipped)"] }; end
      @web_client ||= HK::Web::Client.new; http_client_wrapper = HK::Http::ClientWrapper.new(@web_client, target_url); reporter = HK::RubyTemplateDefinition::FindingReporter.new(definition.info_attrs, target_url)
      accumulated_errors = []; overall_success = false; findings = []
      payload_set_proc = definition.payload_sets&.values&.first; payloads_to_iterate = nil
      if payload_set_proc.is_a?(Proc); begin; payloads_to_iterate = payload_set_proc.call; rescue StandardError => e; accumulated_errors << "Error generating payloads for template '#{definition.id}': #{e.class.name} - #{e.message}"; payloads_to_iterate = nil; end; end
      payloads_to_iterate = Array(payloads_to_iterate)
      HK.logger.debug "Executing Ruby template: #{definition.info_attrs[:name]} (ID: #{definition.id}) with #{payloads_to_iterate.empty? ? 'no payloads (single run)' : "#{payloads_to_iterate.size} payload(s)"}"
      if !payloads_to_iterate.empty?
        payloads_to_iterate.each_with_index do |current_payload, idx|
          begin; HK.logger.debug "  Payload ##{idx}: #{current_payload.inspect}"; block_result = execute_block.call(target_url, http_client_wrapper, reporter, current_payload); if block_result.is_a?(Hash) && block_result[:errors]; accumulated_errors.concat(Array(block_result[:errors])); end; overall_success = true;
          rescue StandardError => e; error_message = "Exception during Ruby template '#{definition.id}' (payload: #{current_payload.inspect}): #{e.class.name} - #{e.message}"; accumulated_errors << error_message; HK.logger.error error_message; end
        end
      else
        begin; block_result = execute_block.call(target_url, http_client_wrapper, reporter, nil); if block_result.is_a?(Hash) && block_result[:errors]; accumulated_errors.concat(Array(block_result[:errors])); end; overall_success = true;
        rescue StandardError => e; error_message = "Exception during Ruby template '#{definition.id}' (default run): #{e.class.name} - #{e.message}"; accumulated_errors << error_message; HK.logger.error error_message; end
      end
      findings.concat(reporter.findings); findings.uniq!
      findings.each { |f| HK.logger.info "Finding reported by Ruby template '#{definition.id}': #{f[:description]} at #{f[:matched_at_url]}" }
      { success: overall_success, findings: findings, errors: accumulated_errors }
    end

    def _check_target_conditions(target_url, definition) # Logic from turn 158
      return true unless definition.target_condition_block.is_a?(Proc)
      begin
        uri = URI.parse(target_url); url_components = { scheme: uri.scheme, host: uri.host, port: uri.port, path: uri.path || "/", query: uri.query, fragment: uri.fragment, userinfo: uri.userinfo, user: uri.user, password: uri.password, registry: uri.registry, opaque: uri.opaque }; return false if url_components[:host].nil?
        match = definition.target_condition_block.call(url_components)
        HK.logger.debug "Target condition for template '#{definition.id}' on URL '#{target_url}': #{match ? 'met' : 'not met'}"
        match
      rescue URI::InvalidURIError, StandardError => e
        HK.logger.warn "Warning: Error checking target condition for template '#{definition.id}' on URL '#{target_url}': #{e.message}"
        false
      end
    end
  end
end
