require 'thor'
require 'tty-color'
require 'tty-progressbar' 
require 'fileutils'      
require 'json' 
require_relative '../hk' 

module HK
  # --- Templates Subcommand CLI (from turn 156) ---
  class TemplatesCLI < Thor
    def self.exit_on_failure?
      true
    end

    no_commands do
      def pastel
        @pastel ||= TTY::Color
      end
    end

    desc "create NAME", "Creates a new template file with basic boilerplate."
    option :type, type: :string, default: "yaml", enum: %w[yaml ruby], desc: "Type of template to create (yaml or ruby)"
    option :dir, type: :string, default: "templates/custom", desc: "Directory to create the template in"
    def create(name)
      template_type = options[:type].downcase
      base_dir = options[:dir]
      filename = case template_type
                 when "yaml" then "#{name}.yml"
                 when "ruby" then "#{name}.rb"
                 else
                   puts pastel.red("Error: Invalid template type '#{template_type}'. Supported types: yaml, ruby.")
                   return
                 end
      full_path = File.join(base_dir, filename)
      if File.exist?(full_path)
        puts pastel.yellow("Warning: Template file already exists at #{full_path}. Not overwriting.")
        return
      end
      begin
        FileUtils.mkdir_p(base_dir)
      rescue SystemCallError => e
        puts pastel.red("Error: Could not create directory #{base_dir}: #{e.message}")
        return
      end
      boilerplate_content = ""
      if template_type == "yaml"
        boilerplate_content = <<~YAML
          id: #{name.gsub(/[^a-zA-Z0-9_-]+/, '-').downcase}
          info:
            name: "#{name.split(/[-_]/).map(&:capitalize).join(' ')} Check"
            author: "Your Name"
            severity: medium 
            description: "A brief description of what this template checks for."
          requests:
            - method: GET
              path: "/" 
              matchers:
                - type: word 
                  part: body 
                  words:
                    - "Some keyword indicating vulnerability"
        YAML
      elsif template_type == "ruby"
        boilerplate_content = <<~RUBY
          HK.template "#{name.gsub(/[^a-zA-Z0-9_-]+/, '-').downcase}" do
            info(
              name: "#{name.split(/[-_]/).map(&:capitalize).join(' ')} Check",
              author: "Your Name",
              severity: :medium,
              description: "A brief description of what this template checks for via Ruby DSL."
            )
            execute do |target_url, http, reporter|
              # response = http.get("/some_path") 
              # if response && response[:body]&.include?("vulnerable_pattern")
              #   reporter.report(description: "Found 'vulnerable_pattern'", matched_at_url: target_url + "/some_path")
              # end
              { findings: reporter.findings } 
            end
          end
        RUBY
      end
      begin
        File.write(full_path, boilerplate_content)
        puts pastel.green("Successfully created template: #{full_path}")
      rescue SystemCallError => e
        puts pastel.red("Error: Could not write template file to #{full_path}: #{e.message}")
      end
    end

    desc "validate PATH_OR_DIR", "Validates one or more template files."
    long_desc <<-LONGDESC
      Validates the syntax and basic structure of Hēikè template files.
      Can target a single template file or a directory of templates.
    LONGDESC
    def validate(path_or_dir)
      puts pastel.cyan("CLI:") + " Validating templates at path: " + pastel.yellow(path_or_dir)
      puts "--------------------------------------------------"
      template_engine = HK::TemplateEngine.new 
      HK::TemplateRegistry.clear! 
      results = template_engine.load_from_path(path_or_dir)
      if results[:errors].any?
        puts pastel.red.bold("Validation Failed. Errors found:")
        results[:errors].each_with_index do |error_msg, idx|
          puts pastel.red("  Error ##{idx + 1}: #{error_msg}")
        end
      else
        puts pastel.yellow("No critical loading errors found.") 
      end
      if results[:loaded_templates].any?
        puts pastel.green.bold("
Successfully loaded and validated #{results[:loaded_templates].size} template(s):")
        results[:loaded_templates].each do |template_def|
          puts pastel.green("  - ID: #{template_def[:id]}, Type: #{template_def[:type]}, Path: #{template_def[:path]}")
        end
      elsif results[:errors].empty? 
        puts pastel.yellow("No template files found to validate at the specified path.")
      end
      puts "--------------------------------------------------"
      puts pastel.cyan("Validation process finished.")
      exit 1 if results[:errors].any?
    end
  end

  # Main CLI class
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    no_commands do
      def pastel
        @pastel ||= TTY::Color
      end

      def sev_sort_order(severity_string)
          %w[critical high medium low info unknown].index(severity_string&.downcase) || 99
      end

      def severity_color(severity_string)
          case severity_string&.downcase
          when 'critical' then pastel.bright_red.bold(severity_string)
          when 'high'     then pastel.red(severity_string)
          when 'medium'   then pastel.yellow(severity_string)
          when 'low'      then pastel.blue(severity_string)
          when 'info'     then pastel.cyan(severity_string)
          else pastel.white(severity_string || 'unknown')
          end
      end
    end

    desc "version", "Prints the HK version"
    def version
      hk_version_colored = pastel.bold(pastel.blue(HK::VERSION))
      puts "Hēi Kè (HK) Security Framework version #{hk_version_colored}"
    end

    desc "scan TARGET", "Scans a target using specified templates."
    option :templates, aliases: "-t", type: :string, required: true, banner: "PATH", desc: "Path to a template file or a directory of templates"
    option :timeout, type: :numeric, desc: "Global timeout for HTTP requests within templates (seconds)"
    option :json, type: :string, banner: "FILEPATH", desc: "Save scan results to a JSON file"
    def scan(target)
      unless options[:templates] 
        puts pastel.red("Error: Missing required option --templates / -t")
        invoke :help, ['scan'] 
        return
      end
      target_url = HK::Web::Crawler.normalize_url(target) 
      unless target_url
          puts pastel.red("Error: Invalid target URL provided: #{target}")
          return
      end
      puts pastel.cyan("CLI:") + " Scan command for target: " + pastel.yellow.bold(target_url); puts pastel.dim("  Templates path: #{options[:templates]}"); puts pastel.dim("  Global timeout option: #{options[:timeout] || 'default (engine uses 5s in Web::Client)'}"); puts "--------------------------------------------------" unless options[:json]
      engine_options = { timeout: options[:timeout] }.compact 
      template_engine = HK::TemplateEngine.new(engine_options)
      puts pastel.magenta("Loading templates...") unless options[:json]; HK::TemplateRegistry.clear! 
      load_results = template_engine.load_from_path(options[:templates])
      if load_results[:errors].any?; error_output_stream = options[:json] ? $stderr : $stdout; error_output_stream.puts pastel.yellow("Encountered errors during template loading:"); load_results[:errors].each { |err| error_output_stream.puts pastel.yellow("  - #{err}") }; end
      loaded_templates = load_results[:loaded_templates]
      if loaded_templates.empty?; message = "No templates were successfully loaded. Aborting scan."; options[:json] ? $stderr.puts(pastel.red(message)) : puts(pastel.red(message)); return; end
      puts pastel.green("Successfully loaded #{loaded_templates.size} template(s).") unless options[:json]; puts "--------------------------------------------------" unless options[:json]
      puts pastel.magenta("Executing templates against #{target_url}...") unless options[:json]
      bar_total = loaded_templates.size; bar = options[:json] ? nil : TTY::ProgressBar.new("Executing templates [:bar] :current/:total :percent :etas", total: bar_total, clear: true); all_findings = []; all_execution_errors = []
      loaded_templates.each do |template_def| exec_result = template_engine.execute(template_def, target_url); all_findings.concat(exec_result[:findings]) if exec_result[:findings]&.any?; all_execution_errors.concat(exec_result[:errors]) if exec_result[:errors]&.any?; bar&.advance; end
      puts "--------------------------------------------------" unless options[:json]
      if options[:json]; json_output_path = options[:json]; output_data = { target_info: { original_target: target, normalized_target_url: target_url, templates_path: options[:templates] }, summary: { templates_loaded: loaded_templates.size, findings_count: all_findings.size, execution_errors_count: all_execution_errors.size }, findings: all_findings.sort_by { |f| sev_sort_order(f[:severity]) }, errors: all_execution_errors }; begin; File.write(json_output_path, JSON.pretty_generate(output_data)); puts pastel.green("Scan results saved to JSON: #{json_output_path}"); rescue SystemCallError, IOError => e; puts pastel.red("Error: Could not write JSON output to #{json_output_path}: #{e.message}"); end
      else 
        if all_findings.any?; puts pastel.bright_green.bold("Vulnerability Findings (#{all_findings.size}):"); all_findings.group_by { |f| f[:severity] }.sort_by { |sev, _| sev_sort_order(sev) }.each do |severity, findings_by_severity| puts pastel.underline("
  Severity: #{severity_color(severity&.to_s || 'unknown')}"); findings_by_severity.each_with_index do |finding, idx| puts "    Finding ##{idx + 1}:"; puts "      Template Name: #{finding[:template_name]} (#{finding[:template_id]})"; puts "      Target:        #{finding[:target_url]}"; puts "      Matched At:    #{finding[:matched_at_url]}"; puts "      Description:   #{finding[:description]}"; end; end
        else; puts pastel.green("No vulnerabilities found for the executed templates."); end
        if all_execution_errors.any?; puts pastel.red("
Errors during template execution (#{all_execution_errors.size}):"); all_execution_errors.each_with_index do |err_info, idx| if err_info.is_a?(Hash) && err_info[:error]; error_message = "Error ##{idx + 1}: "; error_message += "Request Index: #{err_info[:request_index]} - " if err_info[:request_index]; error_message += "#{err_info[:error]}"; error_message += " (URL: #{err_info[:url]})" if err_info[:url]; puts "    #{error_message}"; else; puts "    Error ##{idx + 1}: #{err_info}"; end; end; end
        puts "--------------------------------------------------"; puts pastel.cyan("Scan finished.")
      end
    end

    desc "ports TARGET", "Scans ports on a target using TCP Connect scan."
    option :ports, type: :string, aliases: "-p"; option :top_ports, type: :numeric; option :timeout, type: :numeric
    def ports(target) # Condensed for brevity
      puts pastel.cyan("CLI:") + " Received ports command for target: " + pastel.yellow.bold(target); cli_options = options.dup; parsed_ports = []; if cli_options[:top_ports]; top_n_list = [80, 443, 22, 21, 25, 53, 3306, 3389, 8080, 8443, 110, 143, 5432, 5900, 6379, 9200, 9300, 27017]; count = cli_options[:top_ports].to_i; parsed_ports = top_n_list.take(count > 0 ? count : 10); puts pastel.dim("  (Using top #{parsed_ports.size} ports based on --top-ports #{cli_options[:top_ports]})"); elsif cli_options[:ports]; ports_string = cli_options[:ports]; ports_string.split(',').each do |part| part.strip!; if part.include?('-'); start_port, end_port = part.split('-').map(&:to_i); if start_port && end_port && start_port > 0 && end_port >= start_port && end_port <= 65535 && start_port <=65535; parsed_ports.concat((start_port..end_port).to_a); else; puts pastel.yellow("Warning: Invalid port range '#{part}'. Skipping."); end; else; port = part.to_i; if port > 0 && port <= 65535; parsed_ports << port; else; puts pastel.yellow("Warning: Invalid port number '#{part}'. Skipping."); end; end; end; parsed_ports.uniq!.sort!; puts pastel.dim("  (Using ports from -p option: #{ports_string})"); else; parsed_ports = [21, 22, 25, 53, 80, 110, 143, 443, 445, 3306, 3389, 5432, 5900, 6379, 8000, 8080, 8443, 9200, 9300, 27017]; puts pastel.dim("  (No ports specified, using default list: #{parsed_ports.size} ports)"); end; if parsed_ports.empty?; puts pastel.red("Error: No valid ports specified or derived. Use -p or --top-ports."); return; end; scan_options = { timeout: options[:timeout] || 1.0 }; scan_options[:rate] = options[:rate] if options[:rate]; net_scanner = HK::Net::Scanner.new; bar_format = "Scanning #{target} [:bar] :current/:total (:percent) :etas"; bar = TTY::ProgressBar.new(bar_format, total: parsed_ports.size, clear: true); scan_results = net_scanner.tcp_scan(target, parsed_ports, scan_options, bar); puts pastel.cyan("CLI: Scan Results for ") + pastel.yellow.bold(target); if scan_results[:error]; puts pastel.red("  Error: #{scan_results[:error]}"); return; end; if scan_results[:open_ports].any?; puts pastel.green("  Open Ports:"); scan_results[:open_ports].each do |pi| details = "    Port #{pi[:port]}"; details += " - Service: #{pastel.bright_blue(pi[:service])}" if pi[:service] && pi[:service] != "unknown"; details += " (Version: #{pastel.blue(pi[:version])})" if pi[:version]; puts pastel.green(details); end; else; puts pastel.yellow("  No open ports found from the scanned list."); end; if scan_results[:filtered_ports].any? ; puts pastel.yellow("  Filtered/Timed Out Ports: ") + scan_results[:filtered_ports].join(', '); end
    end

    desc "http URL", "Performs HTTP probing on a URL, supporting different methods, data, and headers."
    option :method, type: :string, aliases: "-X", default: "GET"; option :data, type: :string, aliases: "-d"; option :status_code, type: :boolean, aliases: "-sc"; option :title, type: :boolean; option :final_url, type: :boolean, aliases: "-fu"; option :cookies, type: :boolean; option :timeout, type: :numeric; option :headers, type: :string
    def http(url) # Condensed for brevity
      puts pastel.cyan("CLI:") + " Received http command for URL: " + pastel.yellow.bold(url); cli_options = options.dup; puts pastel.dim("CLI options: #{cli_options.inspect}"); web_client_options = { method: cli_options[:method].upcase, timeout: cli_options[:timeout], body_data: cli_options[:data]}; if cli_options[:headers]; begin; custom_headers = Hash[cli_options[:headers].split(';').map do |h| parts = h.split(':', 2); [parts[0].strip, parts[1] ? parts[1].strip : ""] end]; web_client_options[:headers] = custom_headers; rescue => e; puts pastel.red("Error parsing headers: #{e.message}. Ignoring custom headers."); end; end; web_client = HK::Web::Client.new; results = web_client.probe(url, web_client_options); puts pastel.cyan("CLI: HTTP Probe Results for ") + pastel.yellow.bold(results[:url]); if results[:error]; puts pastel.red("  Error: #{results[:error]}"); else; any_specific_output_flag_set = cli_options[:status_code] || cli_options[:title] || cli_options[:final_url] || cli_options[:cookies]; show_status = cli_options[:status_code] || !any_specific_output_flag_set; show_final_url = cli_options[:final_url] || !any_specific_output_flag_set; if show_status; puts "  Status Code: " + (results[:status_code] ? pastel.green(results[:status_code].to_s) : pastel.yellow("N/A")); end; if show_final_url && results[:final_url] != results[:url] ; puts "  Final URL:   " + pastel.dim(results[:final_url]); end; if cli_options[:title]; title_str = results[:title].nil? || results[:title].empty? ? "N/A or not found" : results[:title]; puts "  Title:       " + (results[:title] ? pastel.italic(title_str) : pastel.yellow(title_str)); end; if cli_options[:cookies] && results[:cookies]&.any?; puts "  Cookies Set: "; results[:cookies].each { |k,v| puts "    #{pastel.dim(k)}: #{pastel.dim(v)}" }; elsif cli_options[:cookies]; puts "  Cookies Set: " + pastel.dim("(none)"); end; end
    end

    desc "crawl URL", "Crawls a web target using HK::Web::Crawler, respecting scope and concurrency."
    option :depth, type: :numeric, aliases: "-d"; option :threads, type: :numeric, aliases: "-t", default: 5; option :timeout, type: :numeric; option :headers, type: :string; option :scope, type: :string, default: 'host'; option :max_pages, type: :numeric
    def crawl(url) # Condensed for brevity
      puts pastel.cyan("CLI:") + " Received crawl command for URL: " + pastel.yellow.bold(url); crawler_options = { depth: options[:depth] || 2, scope: (options[:scope]&.to_sym if HK::Web::Crawler::VALID_SCOPES.include?(options[:scope]&.to_sym)) || :host, threads: options[:threads] || 5 }; crawler_options[:timeout] = options[:timeout] if options[:timeout]; crawler_options[:max_pages] = options[:max_pages] if options[:max_pages] ; if options[:headers]; begin; custom_headers = Hash[options[:headers].split(';').map { |h| h.split(':', 2).map(&:strip) }]; crawler_options[:headers] = custom_headers; puts pastel.dim("  Using custom headers for crawler requests: #{custom_headers.inspect}"); rescue => e; puts pastel.red("Error parsing headers for crawler: #{e.message}. Ignoring custom headers."); end; end; puts pastel.dim("Crawler options: #{crawler_options.inspect}"); begin; crawler = HK::Web::Crawler.new(url, crawler_options); rescue ArgumentError => e; puts pastel.red("Error initializing crawler: #{e.message}"); return; end; puts pastel.magenta("Starting crawl, this might take a while..."); bar_total = options[:max_pages] || nil ; bar_format = "Crawling #{url} [:bar] :current#{bar_total ? '/'+bar_total.to_s : ''} pages :rate/s :etas"; bar = TTY::ProgressBar.new(bar_format, total: bar_total, clear: true); results = crawler.crawl(bar); puts pastel.cyan("CLI: Crawl Results for ") + pastel.yellow.bold(results[:initial_url]); puts "--------------------------------------------------"; puts "  Crawled Pages Count: #{results[:crawled_count]}"; puts "  Found Unique Links : #{results[:found_links_count]}"; if results[:found_links].any?; puts pastel.green("
  Found Links (#{results[:found_links].size}):"); results[:found_links].each_with_index do |link, index| puts "    #{index + 1}. #{link}"; end; else; puts pastel.yellow("
  No new links found within the scope and depth."); end; if results[:errors].any?; puts pastel.red("
  Errors during crawl (#{results[:errors].size}):"); results[:errors].each_with_index do |err_info, idx| if err_info.is_a?(Hash) && err_info[:error]; error_message = "Error ##{idx + 1}: "; error_message += "Request Index: #{err_info[:request_index]} - " if err_info[:request_index]; error_message += "#{err_info[:error]}"; error_message += " (URL: #{err_info[:url]})" if err_info[:url]; puts "    #{error_message}"; else; puts "    Error ##{idx + 1}: #{err_info}"; end; end; end; puts "--------------------------------------------------"; puts pastel.cyan("Scan finished.")
    end
    
    # New 'subdomains' command from current task
    desc "subdomains TARGET", "Discovers subdomains for a given target domain/URL."
    long_desc <<-LONGDESC
      Uses various sources (currently crt.sh) to find subdomains for the specified TARGET.
      The TARGET can be a domain name (e.g., example.com) or a full URL.

      Example:
        hk subdomains example.com
        hk subdomains https://www.example.com/path -o subdomains.txt
    LONGDESC
    option :output, aliases: "-o", type: :string, banner: "FILEPATH", desc: "Save the list of subdomains to a file (one per line)."
    option :timeout, type: :numeric, desc: "Network timeout in seconds for sources like crt.sh (default: 15)"
    def subdomains(target_domain_or_url)
      # puts pastel.cyan("CLI:") + " Received subdomains command for target: " + pastel.yellow.bold(target_domain_or_url)
      
      finder_options = { timeout: options[:timeout] }.compact 

      begin
        finder = HK::SubdomainFinder.new(target_domain_or_url, finder_options)
      rescue ArgumentError => e
        puts pastel.red("Error: #{e.message}")
        return 1 
      end

      # puts pastel.magenta("Discovering subdomains for #{finder.domain}...")
      # Could add a spinner here as it's a single network call.
      # TTY::Spinner.new("[:spinner] Discovering subdomains...").run do |spinner| ... end
      
      discovered_subdomains = finder.discover

      if discovered_subdomains.empty?
        puts pastel.yellow("No subdomains found for #{finder.domain}.")
      else
        puts pastel.green("Found #{discovered_subdomains.size} unique subdomain(s) for #{finder.domain}:")
        
        if options[:output]
          begin
            # Ensure directory exists for output file if it's nested
            output_dir = File.dirname(options[:output])
            FileUtils.mkdir_p(output_dir) unless File.directory?(output_dir)
            
            File.open(options[:output], 'w') do |file|
              discovered_subdomains.each { |sd| file.puts sd }
            end
            puts pastel.green("Subdomain list saved to: #{options[:output]}")
          rescue SystemCallError => e 
            puts pastel.red("Error saving subdomains to file #{options[:output]}: #{e.message}")
            # Fallback to console if file write failed
            puts pastel.yellow("Printing to console instead:")
            discovered_subdomains.each { |sd| puts "  #{pastel.bright_blue(sd)}" }
          end
        else 
          discovered_subdomains.each { |sd| puts "  #{pastel.bright_blue(sd)}" }
        end
      end
      return 0 
    end

    desc "templates SUBCOMMAND ...ARGS", "Manage Hēikè templates"
    subcommand "templates", TemplatesCLI
  end
end
