require 'thor'
require 'tty-color'
require 'tty-progressbar'
require 'fileutils'
require 'json'
require_relative '../hk'

module HK
  # --- Templates Subcommand CLI ---
  class TemplatesCLI < Thor
    HOME_TEMPLATES_DIR = File.expand_path("~/.hk/templates"); PROJECT_TEMPLATES_DIR = File.expand_path("./templates")
    def self.exit_on_failure?; true; end
    no_commands do; def pastel; @pastel ||= TTY::Color; end
      def collect_templates_from_paths(paths_to_scan); template_engine = HK::TemplateEngine.new; all_loaded_templates = {}; all_load_errors = []; HK::TemplateRegistry.clear!; paths_to_scan.each do |path_str| expanded_path = File.expand_path(path_str); unless Dir.exist?(expanded_path); next; end; results = template_engine.load_from_path(expanded_path); results[:loaded_templates].each do |t_def| all_loaded_templates[t_def[:id]] ||= t_def; end; all_load_errors.concat(results[:errors].map { |e| "Path '#{expanded_path}': #{e}" }); end; { loaded_templates: all_loaded_templates.values, errors: all_load_errors }; end
      def display_templates(templates, verbose_output); if templates.empty?; HK.logger.warn(pastel.yellow("No matching templates found.")); return; end; HK.logger.info(pastel.bright_green.bold("Found #{templates.size} template(s):")); headers = ["ID", "Type", "Name", "Severity", "Path"]; format_string = "%-25s %-6s %-30s %-10s %-s"; if verbose_output; headers.insert(3, "Author"); headers.insert(5, "Description"); format_string = "%-25s %-6s %-30s %-20s %-10s %-40s %-s"; end; puts pastel.underline(format_string % headers); templates.sort_by { |t| t[:id] }.each do |template| info = template[:data]&.[]('info') || template[:definition]&.info_attrs || {}; row_data = [template[:id], template[:type].to_s, info[:name] || "N/A", info[:severity]&.to_s || "N/A", template[:path]]; if verbose_output; row_data.insert(3, info[:author] || "N/A"); row_data.insert(5, info[:description] || "N/A"); end; puts format_string % row_data; end; puts "--------------------------------------------------"; end
    end
    desc "create NAME", "Creates a new template file."; option :type, default: "yaml"; option :dir, default: "templates/custom"; def create(name); template_type = options[:type].downcase; base_dir = options[:dir]; filename = case template_type; when "yaml" then "#{name}.yml"; when "ruby" then "#{name}.rb"; else HK.logger.error(pastel.red("Error: Invalid template type '#{template_type}'.")); return; end; full_path = File.join(base_dir, filename); if File.exist?(full_path); HK.logger.warn(pastel.yellow("Warning: Template file already exists at #{full_path}.")); return; end; begin; FileUtils.mkdir_p(base_dir); rescue SystemCallError => e; HK.logger.error(pastel.red("Error: Could not create directory #{base_dir}: #{e.message}")); return; end; boilerplate_content = ""; if template_type == "yaml"; boilerplate_content = <<~YAML
        id: #{name.gsub(/[^a-zA-Z0-9_-]+/, '-').downcase}
        info:
          name: "#{name.split(/[-_]/).map(&:capitalize).join(' ')} Check"; author: "Your Name"; severity: medium
          description: "A brief description of what this template checks for."
        requests:
          - method: GET; path: "/"; matchers: [ { type: word, part: body, words: ["Some keyword"] } ]
      YAML
    elsif template_type == "ruby"; boilerplate_content = <<~RUBY
        HK.template "#{name.gsub(/[^a-zA-Z0-9_-]+/, '-').downcase}" do
          info(name: "#{name.split(/[-_]/).map(&:capitalize).join(' ')} Check", author: "Your Name", severity: :medium, description: "A brief desc.")
          execute { |target_url, http, reporter| { findings: reporter.findings } }
        end
      RUBY
    end; begin; File.write(full_path, boilerplate_content); HK.logger.info(pastel.green("Successfully created template: #{full_path}")); rescue SystemCallError => e; HK.logger.error(pastel.red("Error: Could not write template file to #{full_path}: #{e.message}")); end; end
    desc "validate PATH_OR_DIR", "Validates one or more template files."; def validate(path_or_dir); HK.logger.info(pastel.cyan("CLI:") + " Validating templates at path: " + pastel.yellow(path_or_dir)); HK.logger.info("--------------------------------------------------"); template_engine = HK::TemplateEngine.new; HK::TemplateRegistry.clear!; results = template_engine.load_from_path(path_or_dir); if results[:errors].any?; HK.logger.error(pastel.red.bold("Validation Failed. Errors found:")); results[:errors].each_with_index { |e, i| HK.logger.error(pastel.red("  Error ##{i + 1}: #{e}")) }; else; HK.logger.warn(pastel.yellow("No critical loading errors found.")); end; if results[:loaded_templates].any?; HK.logger.info(pastel.green.bold("
Successfully loaded and validated #{results[:loaded_templates].size} template(s):")); results[:loaded_templates].each { |t| HK.logger.info(pastel.green("  - ID: #{t[:id]}, Type: #{t[:type]}, Path: #{t[:path]}")) }; elsif results[:errors].empty?; HK.logger.warn(pastel.yellow("No template files found to validate at the specified path.")); end; HK.logger.info("--------------------------------------------------"); HK.logger.info(pastel.cyan("Validation process finished.")); exit 1 if results[:errors].any?; end
    desc "list", "Lists available Hēikè templates."; option :paths, aliases:"-P",type: :array; option :verbose, aliases:"-v",type: :boolean,default: false; def list; default_paths = [HOME_TEMPLATES_DIR, PROJECT_TEMPLATES_DIR].select { |p| Dir.exist?(p) }; user_paths = options[:paths] || []; search_paths = (default_paths + user_paths).uniq.map { |p| File.expand_path(p) }; if search_paths.empty?; HK.logger.warn(pastel.yellow("No template paths configured or specified.")); return; end; HK.logger.info(pastel.cyan("Listing templates from paths:")); search_paths.each { |p| HK.logger.debug(pastel.dim("  - #{p}")) }; HK.logger.info("--------------------------------------------------"); collection_results = collect_templates_from_paths(search_paths); if collection_results[:errors].any?; HK.logger.warn(pastel.yellow.bold("Encountered errors during template loading:")); collection_results[:errors].each { |err| HK.logger.warn(pastel.yellow("  - #{err}")) }; HK.logger.info("--------------------------------------------------"); end; display_templates(collection_results[:loaded_templates], options[:verbose]); end

    # Updated 'search' command for field-specific searching
    desc "search [KEYWORD]", "Searches templates by keyword or specific metadata fields."
    long_desc <<-LONGDESC
      Searches available templates based on a general KEYWORD or specific metadata fields.
      If KEYWORD is provided, it searches across ID, name, author, description, and tags.
      Field-specific options (-n, -a, -s, --tags) allow for more targeted searches.
      Multiple field-specific options are combined with AND logic.
      If KEYWORD and field-specific options are both given, KEYWORD search is performed first,
      and then field-specific filters are applied to those results.

      Examples:
        hk templates search sql
        hk templates search -n "SQL Injection" -s high --tags web,sqli
        hk templates search --author "Ethical Hacker" -i
    LONGDESC
    option :paths, aliases: "-P", type: :array, banner: "PATH1 PATH2...", desc: "Additional template directories or files to search."
    option :name, aliases: "-n", type: :string, desc: "Search by template name."
    option :author, aliases: "-a", type: :string, desc: "Search by template author."
    option :severity, aliases: "-s", type: :string, desc: "Search by template severity (critical, high, medium, low, info)."
    option :tags, type: :string, desc: "Search by comma-separated tags (matches if any tag is present)."
    option :case_insensitive, aliases: "-i", type: :boolean, default: false, desc: "Perform case-insensitive search for keyword and string fields."
    option :verbose, aliases: "-v", type: :boolean, default: false, desc: "Display verbose output for matched templates."

    def search(keyword = nil) # KEYWORD is now optional
      if keyword.nil? && options.slice(:name, :author, :severity, :tags).empty?
        HK.logger.error pastel.red("Search requires a keyword or at least one field-specific option (-n, -a, -s, --tags).")
        invoke :help, ['search']
        return
      end

      default_paths = [HOME_TEMPLATES_DIR, PROJECT_TEMPLATES_DIR].select { |p| Dir.exist?(p) }
      user_paths = options[:paths] || []
      search_paths = (default_paths + user_paths).uniq.map { |p| File.expand_path(p) }

      if search_paths.empty? && user_paths.empty?
        HK.logger.warn pastel.yellow("No template paths configured or specified.")
        return
      end

      # HK.logger.info pastel.cyan("Searching templates...") # General message, details below
      # search_paths.each { |p| HK.logger.debug(pastel.dim("  In path: #{p}")) }
      # HK.logger.info "--------------------------------------------------"


      collection_results = collect_templates_from_paths(search_paths)
      if collection_results[:errors].any?
        HK.logger.warn pastel.yellow.bold("Note: Some errors occurred during template loading:")
        collection_results[:errors].each { |err| HK.logger.warn(pastel.yellow("  - #{err}")) }
        # HK.logger.info "--------------------------------------------------" # No need for extra separator here
      end

      templates_to_filter = collection_results[:loaded_templates]

      # Apply general keyword search first if KEYWORD is provided
      if keyword
        search_term = options[:case_insensitive] ? keyword.downcase : keyword
        HK.logger.info "Filtering by general keyword: '#{search_term}'#{options[:case_insensitive] ? ' (case-insensitive)' : ''}"
        templates_to_filter = templates_to_filter.select do |template|
          info = template[:data]&.[]('info') || template[:definition]&.info_attrs || {}
          tags_str = (info[:tags].is_a?(Array) ? info[:tags].join(' ') : info[:tags].to_s)

          searchable_content = [
            template[:id], info[:name], info[:author], info[:description], tags_str
          ].compact.join(' ')

          options[:case_insensitive] ? searchable_content.downcase.include?(search_term) : searchable_content.include?(search_term)
        end
      end

      # Apply field-specific filters
      field_options = options.slice(:name, :author, :severity, :tags)
      unless field_options.empty?
        HK.logger.info "Applying field-specific filters: #{field_options.map{|k,v| "#{k}='#{v}'"}.join(', ')}#{options[:case_insensitive] && field_options.slice(:name, :author, :tags).any? ? ' (some case-insensitive)' : ''}"
      end

      matched_templates = templates_to_filter.select do |template|
        info = template[:data]&.[]('info') || template[:definition]&.info_attrs || {}

        matches_name = true
        if options[:name]
          name_search = options[:case_insensitive] ? options[:name].downcase : options[:name]
          template_name = options[:case_insensitive] ? (info[:name]&.downcase || "") : (info[:name] || "")
          matches_name = template_name.include?(name_search)
        end

        matches_author = true
        if options[:author]
          author_search = options[:case_insensitive] ? options[:author].downcase : options[:author]
          template_author = options[:case_insensitive] ? (info[:author]&.downcase || "") : (info[:author] || "")
          matches_author = template_author.include?(author_search)
        end

        matches_severity = true
        if options[:severity]
          # Severity matching should be exact for the given level, or allow partial if desired (e.g. "h" for high)
          # Current CLI output for severity uses downcase.
          # For robustness, match against downcased severity.
          severity_search = options[:severity].downcase
          template_severity = info[:severity]&.to_s&.downcase || ""
          matches_severity = template_severity.include?(severity_search) # Partial match (e.g. "hi" matches "high")
        end

        matches_tags = true
        if options[:tags]
          search_tags = options[:tags].split(',').map(&:strip).reject(&:empty?)
          template_tags_str = (info[:tags].is_a?(Array) ? info[:tags].join(' ') : info[:tags].to_s)
          template_tags_str = options[:case_insensitive] ? template_tags_str.downcase : template_tags_str

          matches_tags = search_tags.all? do |search_tag| # Changed from .any? to .all? for AND logic on tags
            tag_to_find = options[:case_insensitive] ? search_tag.downcase : search_tag
            template_tags_str.include?(tag_to_find)
          end
        end

        matches_name && matches_author && matches_severity && matches_tags
      end

      display_templates(matched_templates, options[:verbose])
    end
  end

  # Main CLI class
  class CLI < Thor # Preserving other commands from turn 163
    no_commands do; def pastel; @pastel ||= TTY::Color; end; def sev_sort_order(s); %w[critical high medium low info unknown].index(s&.downcase) || 99; end; def severity_color(s); case s&.downcase; when 'critical' then pastel.bright_red.bold(s); when 'high' then pastel.red(s); when 'medium' then pastel.yellow(s); when 'low' then pastel.blue(s); when 'info' then pastel.cyan(s); else pastel.white(s || 'unknown'); end; end; def prepare_logger; HK.configure_logger(level: options[:log_level], output: options[:log_output]); end; def _print_body(body_string, content_type_header, cli_opts); return if body_string.nil? || body_string.empty?; if cli_opts[:pretty]; content_type = content_type_header&.downcase || ""; lexer_name = nil; formatted_body = body_string; if content_type.include?("application/json") || content_type.include?("javascript"); begin; parsed_json = JSON.parse(body_string); formatted_body = JSON.pretty_generate(parsed_json); lexer_name = "JSON"; rescue JSON::ParserError; lexer_name = "text"; end; elsif content_type.include?("text/html"); lexer_name = "HTML"; elsif content_type.include?("application/xml") || content_type.include?("text/xml"); lexer_name = "XML"; elsif content_type.start_with?("text/"); lexer_name = "text"; end; if lexer_name; begin; lexer = Rouge::Lexer.find_fancy(lexer_name, formatted_body) || Rouge::Lexers::PlainText.new; formatter = Rouge::Formatters::Terminal256.new(theme: cli_opts.fetch(:theme, 'thankful_eyes')); puts formatter.format(lexer.lex(formatted_body)); rescue => e; puts formatted_body; end; else; puts body_string; end; else; puts body_string; end; end; end
    class_option :log_level, type: :string; class_option :log_output, type: :string; def initialize(*a); super; prepare_logger; end
    desc "version", "Prints the HK version"; def version; HK.logger.info("Hēi Kè (HK) Security Framework version #{pastel.bold(pastel.blue(HK::VERSION))}"); end
    desc "scan TARGET", "Scans a target using specified templates."; option :templates, aliases: "-t", r: true; option :timeout, type: :numeric; option :json, type: :string; def scan(target); unless options[:templates]; HK.logger.error(pastel.red("Error: Missing required option --templates / -t")); invoke :help, ['scan']; return; end; target_url = HK::Web::Crawler.normalize_url(target); unless target_url; HK.logger.error(pastel.red("Error: Invalid target URL provided: #{target}")); return; end; HK.logger.info(pastel.cyan("CLI:") + " Scan command for target: " + pastel.yellow.bold(target_url)); HK.logger.debug(pastel.dim("  Templates path: #{options[:templates]}")); HK.logger.debug(pastel.dim("  Global timeout option: #{options[:timeout] || 'default (engine uses 5s in Web::Client)'}")); HK.logger.info("--------------------------------------------------") unless options[:json]; engine_options = { timeout: options[:timeout] }.compact; template_engine = HK::TemplateEngine.new(engine_options); HK.logger.info(pastel.magenta("Loading templates...")) unless options[:json]; HK::TemplateRegistry.clear!; load_results = template_engine.load_from_path(options[:templates]); if load_results[:errors].any?; error_output_stream = options[:json] ? $stderr : HK.logger.method(:warn); error_output_stream.call(pastel.yellow("Encountered errors during template loading:")); load_results[:errors].each { |err| error_output_stream.call(pastel.yellow("  - #{err}")) }; end; loaded_templates = load_results[:loaded_templates]; if loaded_templates.empty?; message = "No templates were successfully loaded. Aborting scan."; options[:json] ? $stderr.puts(pastel.red(message)) : HK.logger.error(pastel.red(message)); return; end; HK.logger.info(pastel.green("Successfully loaded #{loaded_templates.size} template(s).")) unless options[:json]; HK.logger.info("--------------------------------------------------") unless options[:json]; HK.logger.info(pastel.magenta("Executing templates against #{target_url}...")) unless options[:json]; bar_total = loaded_templates.size; bar = options[:json] ? nil : TTY::ProgressBar.new("Executing templates [:bar] :current/:total :percent :etas", total: bar_total, clear: true, output: $stderr); all_findings = []; all_execution_errors = []; loaded_templates.each do |template_def| exec_result = template_engine.execute(template_def, target_url); all_findings.concat(exec_result[:findings]) if exec_result[:findings]&.any?; all_execution_errors.concat(exec_result[:errors]) if exec_result[:errors]&.any?; bar&.advance; end; bar&.finish; HK.logger.info("--------------------------------------------------") unless options[:json]; if options[:json]; json_output_path = options[:json]; output_data = { target_info: { original_target: target, normalized_target_url: target_url, templates_path: options[:templates] }, summary: { templates_loaded: loaded_templates.size, findings_count: all_findings.size, execution_errors_count: all_execution_errors.size }, findings: all_findings.sort_by { |f| sev_sort_order(f[:severity]) }, errors: all_execution_errors }; begin; File.write(json_output_path, JSON.pretty_generate(output_data)); HK.logger.info(pastel.green("Scan results saved to JSON: #{json_output_path}")); rescue SystemCallError, IOError => e; HK.logger.error(pastel.red("Error: Could not write JSON output to #{json_output_path}: #{e.message}")); end; else; if all_findings.any?; HK.logger.info(pastel.bright_green.bold("Vulnerability Findings (#{all_findings.size}):")); all_findings.group_by { |f| f[:severity] }.sort_by { |sev, _| sev_sort_order(sev) }.each do |severity, findings_by_severity| HK.logger.info(pastel.underline("
  Severity: #{severity_color(severity&.to_s || 'unknown')}")); findings_by_severity.each_with_index do |finding, idx| HK.logger.info("    Finding ##{idx + 1}:"); HK.logger.info("      Template Name: #{finding[:template_name]} (#{finding[:template_id]})"); HK.logger.info("      Target:        #{finding[:target_url]}"); HK.logger.info("      Matched At:    #{finding[:matched_at_url]}"); HK.logger.info("      Description:   #{finding[:description]}"); end; end; else; HK.logger.info(pastel.green("No vulnerabilities found for the executed templates.")); end; if all_execution_errors.any?; HK.logger.error(pastel.red("
Errors during template execution (#{all_execution_errors.size}):")); all_execution_errors.each_with_index do |err_info, idx| if err_info.is_a?(Hash) && err_info[:error]; error_message = "Error ##{idx + 1}: "; error_message += "Request Index: #{err_info[:request_index]} - " if err_info[:request_index]; error_message += "#{err_info[:error]}"; error_message += " (URL: #{err_info[:url]})" if err_info[:url]; HK.logger.error("    #{error_message}"); else; HK.logger.error("    Error ##{idx + 1}: #{err_info}"); end; end; end; HK.logger.info("--------------------------------------------------"); HK.logger.info(pastel.cyan("Scan finished.")); end; end
    desc "ports TARGET", "Scans TCP or UDP ports on a target."; option :ports; option :top_ports; option :timeout; option :threads, aliases:"-T"; option :udp, type: :boolean, default: false; def ports(target); protocol = options[:udp] ? "UDP" : "TCP"; HK.logger.info(pastel.cyan("CLI:") + " Received #{protocol} ports command for target: " + pastel.yellow.bold(target)); cli_options = options.dup; parsed_ports = []; if cli_options[:top_ports]; top_n_list = options[:udp] ? HK::Net::Scanner::DEFAULT_UDP_PORTS : [80,443,22,21,25,53,3306,3389,8080,8443,110,143,5432,5900,6379,9200,9300,27017]; count = cli_options[:top_ports].to_i; parsed_ports = top_n_list.take(count > 0 ? count : (options[:udp] ? 5 : 10)); HK.logger.debug(pastel.dim("  (Using top #{parsed_ports.size} #{protocol} ports based on --top-ports #{cli_options[:top_ports]})")); elsif cli_options[:ports]; ports_string = cli_options[:ports]; ports_string.split(',').each do |part| part.strip!; if part.include?('-'); start_port, end_port = part.split('-').map(&:to_i); if start_port && end_port && start_port > 0 && end_port >= start_port && end_port <= 65535 && start_port <=65535; parsed_ports.concat((start_port..end_port).to_a); else; HK.logger.warn(pastel.yellow("Warning: Invalid port range '#{part}'. Skipping.")); end; else; port = part.to_i; if port > 0 && port <= 65535; parsed_ports << port; else; HK.logger.warn(pastel.yellow("Warning: Invalid port number '#{part}'. Skipping.")); end; end; end; parsed_ports.uniq!.sort!; HK.logger.debug(pastel.dim("  (Using #{protocol} ports from -p option: #{ports_string})")); else; parsed_ports = options[:udp] ? HK::Net::Scanner::DEFAULT_UDP_PORTS : [21,22,25,53,80,110,143,443,445,3306,3389,5432,5900,6379,8000,8080,8443,9200,9300,27017]; HK.logger.debug(pastel.dim("  (No ports specified, using default #{protocol} list: #{parsed_ports.size} ports)")); end; if parsed_ports.empty?; HK.logger.error(pastel.red("Error: No valid ports specified or derived.")); return; end; default_timeout = options[:udp] ? HK::Net::Scanner::UDP_RESPONSE_TIMEOUT : 1.0; default_threads = options[:udp] ? 5 : 10; scan_options = { timeout: options[:timeout] || default_timeout, threads: options[:threads] || default_threads }.compact; net_scanner = HK::Net::Scanner.new; bar_total = parsed_ports.empty? ? 0 : parsed_ports.size; progress_bar = bar_total > 0 ? TTY::ProgressBar.new("Scanning #{target} (#{protocol}) [:bar] :current/:total (:percent) :etas", total: bar_total, clear: true, output: $stderr) : nil; scan_options[:progress_bar] = progress_bar; scan_results = options[:udp] ? net_scanner.udp_scan(target, parsed_ports, scan_options) : net_scanner.tcp_scan(target, parsed_ports, scan_options); progress_bar&.finish; HK.logger.info(pastel.cyan("CLI: #{protocol} Scan Results for ") + pastel.yellow.bold(target)); if scan_results[:error]; HK.logger.error(pastel.red("  Error: #{scan_results[:error]}")); return; end; if scan_results[:open_ports].any?; HK.logger.info(pastel.green("  Open/Responsive #{protocol} Ports:")); scan_results[:open_ports].each do |pi| details = "    Port #{pi[:port]}"; details += " - Service: #{pastel.bright_blue(pi[:service])}" if pi[:service] && pi[:service] != "unknown"; details += " (Version: #{pastel.blue(pi[:version])})" if pi[:version]; details += " (Banner: #{pastel.dim(pi[:banner])})" if pi[:banner] && options[:udp]; HK.logger.info(pastel.green(details)); end; else; HK.logger.warn(pastel.yellow("  No open or responsive #{protocol} ports found from the scanned list.")); end; if scan_results[:filtered_ports].any? ; HK.logger.warn(pastel.yellow("  Filtered/Timed Out #{protocol} Ports: ") + scan_results[:filtered_ports].join(', ')); end; if !options[:udp] && scan_results[:closed_ports]&.any? ; HK.logger.info(pastel.red("  Closed #{protocol} Ports: ") + scan_results[:closed_ports].join(', ')); end; end
    desc "http URL", "Performs HTTP probing on a URL."; option :method; option :data; option :status_code; option :title; option :final_url; option :cookies; option :timeout; option :headers; option :pretty,type: :boolean, default: true; option :format, default:"terminal256"; option :theme, default:"thankful_eyes"; option :body_only, aliases:"-B",type: :boolean,default:false; def http(url); HK.logger.info(pastel.cyan("CLI:") + " Received http command for URL: " + pastel.yellow.bold(url)); cli_options = options.dup; HK.logger.debug(pastel.dim("CLI options (raw): #{cli_options.inspect}")); actual_body_data = cli_options[:data]; if actual_body_data&.start_with?('@'); filepath = actual_body_data[1..-1]; if File.exist?(filepath); begin; actual_body_data = File.read(filepath); HK.logger.debug(pastel.dim("  Loaded body data from file: #{filepath}")); rescue SystemCallError, IOError => e; HK.logger.error(pastel.red("Error reading body file #{filepath}: #{e.message}")); actual_body_data=nil; end; else; HK.logger.error(pastel.red("Error: Body file not found: #{filepath}")); actual_body_data=nil; end; end; web_client_options = { method: cli_options.fetch(:method,"GET").upcase, timeout: cli_options[:timeout], body_data: actual_body_data}; custom_headers = {}; if cli_options[:headers]; begin; custom_headers = Hash[cli_options[:headers].split(';').map do |h| parts = h.split(':', 2); [parts[0].strip, parts[1] ? parts[1].strip : ""] end]; rescue => e; HK.logger.error(pastel.red("Error parsing custom headers: #{e.message}")); custom_headers={}; end; end; if actual_body_data && !actual_body_data.empty? && !custom_headers.keys.any? { |k| k.downcase == 'content-type' }; begin; parsed_json = JSON.parse(actual_body_data); if parsed_json.is_a?(Hash) || parsed_json.is_a?(Array); custom_headers['Content-Type'] = 'application/json'; HK.logger.debug(pastel.dim("  Auto-detected and set Content-Type to application/json")); end; rescue JSON::ParserError; end; end; web_client_options[:headers] = custom_headers unless custom_headers.empty?; HK.logger.debug(pastel.dim("Final web_client_options: #{web_client_options.reject{ |k,v| k==:body_data && v && v.length > 100}}")); web_client = HK::Web::Client.new; results = web_client.probe(url, web_client_options); unless options[:body_only]; HK.logger.info(pastel.cyan("CLI: HTTP Probe Results for ") + pastel.yellow.bold(results[:url])); if results[:error]; HK.logger.error(pastel.red("  Error: #{results[:error]}")); return; end; any_specific_output_flag_set = cli_options[:status_code] || cli_options[:title] || cli_options[:final_url] || cli_options[:cookies]; show_status = cli_options[:status_code] || !any_specific_output_flag_set; show_final_url = cli_options[:final_url] || !any_specific_output_flag_set; if show_status; HK.logger.info("  Status Code: " + (results[:status_code] ? pastel.green(results[:status_code].to_s) : pastel.yellow("N/A"))); end; if show_final_url && results[:final_url] != results[:url] ; HK.logger.info("  Final URL:   " + pastel.dim(results[:final_url])); end; if cli_options[:title]; title_str = results[:title].nil? || results[:title].empty? ? "N/A or not found" : results[:title]; HK.logger.info("  Title:       " + (results[:title] ? pastel.italic(title_str) : pastel.yellow(title_str))); end; if cli_options[:cookies] && results[:cookies]&.any?; HK.logger.info("  Cookies Set: "); results[:cookies].each { |k,v| HK.logger.info("    #{pastel.dim(k)}: #{pastel.dim(v)}") }; elsif cli_options[:cookies]; HK.logger.info("  Cookies Set: " + pastel.dim("(none)")); end; if results[:raw_headers]&.any? && !options[:body_only] ; HK.logger.info(pastel.cyan("  Raw Headers:")); results[:raw_headers].each { |k, v| HK.logger.info("    #{pastel.dim(k)}: #{pastel.dim(v)}") }; end; HK.logger.info "--- Body ---" unless results[:body].nil? || results[:body].empty? || options[:body_only]; end; if results[:body]; content_type_header = results[:raw_headers]&.find(->{["content-type","text/plain"]}){|k,_| k.downcase == 'content-type'}&.last || "text/plain"; _print_body(results[:body], content_type_header, cli_options); elsif !results[:error] && options[:body_only]; HK.logger.info(pastel.dim("(Response body is empty)")); end; end
    desc "crawl URL", "Crawls a web target."; option :depth; option :threads, default:5; option :timeout; option :headers; option :scope, default:'host'; option :max_pages; option :respect_robots_txt, type: :boolean, default: true; def crawl(url); HK.logger.info(pastel.cyan("CLI:") + " Received crawl command for URL: " + pastel.yellow.bold(url)); crawler_options = { depth: options[:depth] || 2, scope: (options[:scope]&.to_sym if HK::Web::Crawler::VALID_SCOPES.include?(options[:scope]&.to_sym)) || :host, threads: options[:threads] || 5, respect_robots_txt: options[:respect_robots_txt] }; crawler_options[:timeout] = options[:timeout] if options[:timeout]; crawler_options[:max_pages] = options[:max_pages] if options[:max_pages] ; if options[:headers]; begin; custom_headers = Hash[options[:headers].split(';').map { |h| h.split(':', 2).map(&:strip) }]; crawler_options[:headers] = custom_headers; HK.logger.debug(pastel.dim("  Using custom headers for crawler requests: #{custom_headers.inspect}")); rescue => e; HK.logger.error(pastel.red("Error parsing headers for crawler: #{e.message}. Ignoring custom headers.")); end; end; HK.logger.debug(pastel.dim("Crawler options: #{crawler_options.inspect}")); begin; crawler = HK::Web::Crawler.new(url, crawler_options); rescue ArgumentError => e; HK.logger.error(pastel.red("Error initializing crawler: #{e.message}")); return; end; HK.logger.info(pastel.magenta("Starting crawl, this might take a while...")); bar_total = crawler_options[:max_pages] || nil ; bar_format = "Crawling #{url} [:bar] :current#{bar_total ? '/'+bar_total.to_s : ''} pages :rate/s :etas"; bar = TTY::ProgressBar.new(bar_format, total: bar_total, clear: true, output: $stderr); crawler_options_for_internal_use = crawler_options.merge(progress_bar: bar); results = crawler.crawl(bar) ; bar.finish if bar_total && !bar.complete?; HK.logger.info(pastel.cyan("CLI: Crawl Results for ") + pastel.yellow.bold(results[:initial_url])); HK.logger.info("--------------------------------------------------"); HK.logger.info("  Crawled Pages Count: #{results[:crawled_count]}"); HK.logger.info("  Found Unique Links : #{results[:found_links_count]}"); if results[:found_links].any?; HK.logger.info(pastel.green("
  Found Links (#{results[:found_links].size}):")); results[:found_links].each_with_index do |link, index| HK.logger.info("    #{index + 1}. #{link}"); end; else; HK.logger.warn(pastel.yellow("
  No new links found within the scope and depth.")); end; if results[:errors].any?; HK.logger.error(pastel.red("
  Errors during crawl (#{results[:errors].size}):")); results[:errors].each_with_index do |err_info, idx| if err_info.is_a?(Hash) && err_info[:error]; error_message = "Error ##{idx + 1}: "; error_message += "Request Index: #{err_info[:request_index]} - " if err_info[:request_index]; error_message += "#{err_info[:error]}"; error_message += " (URL: #{err_info[:url]})" if err_info[:url]; HK.logger.error("    #{error_message}"); else; HK.logger.error("    Error ##{idx + 1}: #{err_info}"); end; end; end; HK.logger.info("--------------------------------------------------"); HK.logger.info(pastel.cyan("Scan finished.")); end
    desc "subdomains TARGET", "Discovers subdomains for a given target domain/URL."; option :output, aliases:"-o"; option :timeout; def subdomains(target_domain_or_url); finder_options = { timeout: options[:timeout] }.compact; begin; finder = HK::SubdomainFinder.new(target_domain_or_url, finder_options); rescue ArgumentError => e; HK.logger.error(pastel.red("Error: #{e.message}")); return 1; end; discovered_subdomains = finder.discover; if discovered_subdomains.empty?; HK.logger.warn(pastel.yellow("No subdomains found for #{finder.domain}.")); else; HK.logger.info(pastel.green("Found #{discovered_subdomains.size} unique subdomain(s) for #{finder.domain}:")); if options[:output]; begin; output_dir = File.dirname(options[:output]); FileUtils.mkdir_p(output_dir) unless File.directory?(output_dir); File.open(options[:output], 'w') do |file| discovered_subdomains.each { |sd| file.puts sd } end; HK.logger.info(pastel.green("Subdomain list saved to: #{options[:output]}")); rescue SystemCallError => e ; HK.logger.error(pastel.red("Error saving subdomains to file #{options[:output]}: #{e.message}")); HK.logger.warn(pastel.yellow("Printing to console instead:")); discovered_subdomains.each { |sd| HK.logger.info("  #{pastel.bright_blue(sd)}") }; end; else; discovered_subdomains.each { |sd| HK.logger.info("  #{pastel.bright_blue(sd)}") }; end; end; return 0; end

    desc "templates SUBCOMMAND ...ARGS", "Manage Hēikè templates"
    subcommand "templates", TemplatesCLI
  end
end
