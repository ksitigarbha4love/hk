require 'thor'
require 'tty-color'
require_relative '../hk' # To access HK::VERSION and other core functionalities

module HK
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    no_commands do
      def pastel
        @pastel ||= TTY::Color
      end

      # Helper methods for scan command output (from current task)
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

    # scan command as per current task description
    desc "scan TARGET", "Scans a target using specified templates."
    long_desc <<-LONGDESC
      Performs a template-based scan against the specified TARGET.
      You must provide a path to a template file or a directory containing templates
      using the -t/--templates option.

      YAML templates define requests and matchers.
      Ruby DSL templates allow for more complex scripted logic.

      Example:
        hk scan example.com -t templates/my_sqli_check.yml
        hk scan example.com -t templates/web_vulns/
        hk scan example.com -t templates/complex_attack.rb --timeout 15
    LONGDESC
    option :templates, aliases: "-t", type: :string, required: true, banner: "PATH", desc: "Path to a template file or a directory of templates"
    option :timeout, type: :numeric, desc: "Global timeout for HTTP requests within templates (seconds)"
    # Future options: --severity, --output, etc.

    def scan(target)
      # Thor handles 'required: true' for options, so this check is usually not needed.
      # However, keeping it for explicit error message if Thor's behavior changes or for clarity.
      unless options[:templates] 
        puts pastel.red("Error: Missing required option --templates / -t")
        invoke :help, ['scan'] 
        return
      end

      target_url = HK::Web::Crawler.normalize_url(target) # Use the same normalizer
      unless target_url
          puts pastel.red("Error: Invalid target URL provided: #{target}")
          return
      end
      
      puts pastel.cyan("CLI:") + " Scan command for target: " + pastel.yellow.bold(target_url)
      puts pastel.dim("  Templates path: #{options[:templates]}")
      puts pastel.dim("  Global timeout option: #{options[:timeout] || 'default (engine uses 5s in Web::Client)'}") 
      puts "--------------------------------------------------"

      engine_options = { timeout: options[:timeout] }.compact # Pass only non-nil options
      template_engine = HK::TemplateEngine.new(engine_options)

      # 1. Load Templates
      puts pastel.magenta("Loading templates...")
      # Clear Ruby DSL registry before loading to avoid stale data from previous runs in same process
      # This is important if HK::TemplateRegistry is a global store and CLI is run multiple times
      # in a persistent environment (like IRB or a test suite without proper cleanup).
      # For a single CLI invocation, it's less critical but good practice.
      HK::TemplateRegistry.clear! 
      load_results = template_engine.load_from_path(options[:templates])

      if load_results[:errors].any?
        puts pastel.yellow("Encountered errors during template loading:")
        load_results[:errors].each { |err| puts pastel.yellow("  - #{err}") }
      end

      loaded_templates = load_results[:loaded_templates]
      if loaded_templates.empty?
        puts pastel.red("No templates were successfully loaded. Aborting scan.")
        return
      end
      puts pastel.green("Successfully loaded #{loaded_templates.size} template(s).")
      puts "--------------------------------------------------"

      # 2. Execute Templates
      puts pastel.magenta("Executing templates against #{target_url}...")
      all_findings = []
      all_execution_errors = []

      loaded_templates.each do |template_def|
        # puts pastel.dim("  Executing template: #{template_def[:id]} (#{template_def[:type]})")
        exec_result = template_engine.execute(template_def, target_url)
        
        all_findings.concat(exec_result[:findings]) if exec_result[:findings]&.any?
        all_execution_errors.concat(exec_result[:errors]) if exec_result[:errors]&.any?
      end
      puts "--------------------------------------------------"

      # 3. Display Results
      if all_findings.any?
        puts pastel.bright_green.bold("Vulnerability Findings (#{all_findings.size}):")
        # Group by severity then sort by predefined order
        all_findings.group_by { |f| f[:severity] }.sort_by { |sev, _| sev_sort_order(sev) }.each do |severity, findings_by_severity|
            puts pastel.underline("
  Severity: #{severity_color(severity&.to_s || 'unknown')}")
            findings_by_severity.each_with_index do |finding, idx|
                puts "    Finding ##{idx + 1}:"
                puts "      Template Name: #{finding[:template_name]} (#{finding[:template_id]})"
                puts "      Target:        #{finding[:target_url]}" 
                puts "      Matched At:    #{finding[:matched_at_url]}" 
                puts "      Description:   #{finding[:description]}"
            end
        end
      else
        puts pastel.green("No vulnerabilities found for the executed templates.")
      end

      if all_execution_errors.any?
        puts pastel.red("
Errors during template execution (#{all_execution_errors.size}):")
        all_execution_errors.each_with_index do |err_info, idx| # Renamed err to err_info
          # Check if err_info is a hash with expected keys, otherwise treat as string
          if err_info.is_a?(Hash) && err_info[:error]
            error_message = "Error ##{idx + 1}: "
            # Include request_index and url if present (typically for YAML template errors)
            error_message += "Request Index: #{err_info[:request_index]} - " if err_info[:request_index]
            error_message += "#{err_info[:error]}"
            error_message += " (URL: #{err_info[:url]})" if err_info[:url]
            puts "    #{error_message}"
          else # For simple string errors or other exception messages from Ruby DSL
            puts "    Error ##{idx + 1}: #{err_info}"
          end
        end
      end
      puts "--------------------------------------------------"
      puts pastel.cyan("Scan finished.")
    end

    # --- Other commands like ports, http, crawl from previous subtasks ---
    desc "ports TARGET", "Scans ports on a target. Supports comma-separated ports and ranges (e.g., 80,443-445,8080)."
    option :ports, type: :string, aliases: "-p", banner: "PORTS", desc: "Comma-separated list of ports and ranges (e.g., 80,443-445,1000-1024)"
    option :top_ports, type: :numeric, banner: "N", desc: "Scan the top N most common ports (overrides -p if both given)"
    option :rate, type: :numeric, desc: "Scan rate in packets per second (simulation)"
    option :timeout, type: :numeric, desc: "Per-port timeout in seconds (simulation)"
    def ports(target)
      puts pastel.cyan("CLI:") + " Received ports command for target: " + pastel.yellow.bold(target)
      cli_options = options.dup 

      parsed_ports = []
      if cli_options[:top_ports]
        top_n_list = [80, 443, 22, 21, 25, 53, 3306, 3389, 8080, 8443, 110, 143, 5432, 5900, 6379, 9200, 9300, 27017]
        count = cli_options[:top_ports].to_i
        parsed_ports = top_n_list.take(count > 0 ? count : 10)
        puts pastel.dim("  (Using top #{parsed_ports.size} ports based on --top-ports #{cli_options[:top_ports]})")
      elsif cli_options[:ports]
        ports_string = cli_options[:ports]
        ports_string.split(',').each do |part|
          part.strip!
          if part.include?('-')
            start_port, end_port = part.split('-').map(&:to_i)
            if start_port && end_port && start_port > 0 && end_port >= start_port && end_port <= 65535 && start_port <=65535
              parsed_ports.concat((start_port..end_port).to_a)
            else
              puts pastel.yellow("Warning: Invalid port range '#{part}'. Skipping.")
            end
          else
            port = part.to_i
            if port > 0 && port <= 65535
              parsed_ports << port
            else
              puts pastel.yellow("Warning: Invalid port number '#{part}'. Skipping.")
            end
          end
        end
        parsed_ports.uniq!.sort!
        puts pastel.dim("  (Using ports from -p option: #{ports_string})")
      else
        parsed_ports = [21, 22, 25, 53, 80, 110, 143, 443, 445, 3306, 3389, 5432, 5900, 6379, 8000, 8080, 8443, 9200, 9300, 27017]
        puts pastel.dim("  (No ports specified, using default list: #{parsed_ports.size} ports)")
      end

      if parsed_ports.empty?
         puts pastel.red("Error: No valid ports specified or derived. Use -p or --top-ports.")
         return
      end
      
      scan_execution_options = cli_options.reject { |k,_| [:ports, :top_ports].include?(k) }
      puts pastel.dim("CLI options for scan: #{scan_execution_options.inspect}")
      puts pastel.dim("Effective ports to be scanned (#{parsed_ports.size}): #{parsed_ports.inspect}")

      net_scanner = HK::Net::Scanner.new
      scan_results = net_scanner.tcp_scan(target, parsed_ports, scan_execution_options)

      puts pastel.cyan("CLI: Scan Results for ") + pastel.yellow.bold(target)
      if scan_results[:open_ports].any?
        puts pastel.green("  Open Ports: ") + scan_results[:open_ports].join(', ')
      else
        puts pastel.yellow("  No open ports found from the scanned list.")
      end
    end

    desc "http URL", "Performs HTTP probing on a URL, fetching status code and title."
    long_desc <<-LONGDESC
      Sends HTTP requests to the specified URL(s) using HK::Web::Client.
      Fetches and displays the HTTP status code and page title.

      Example:
        hk http https://example.com -sc -title -timeout 10
        hk http https://example.com --headers "User-Agent:HKTool/0.1"
    LONGDESC
    option :status_code, type: :boolean, aliases: "-sc", desc: "Display status code (default: true if no other display options)"
    option :title, type: :boolean, desc: "Extract and display page title"
    option :tech_detect, type: :boolean, aliases: "-td", desc: "Perform technology detection (placeholder)"
    option :timeout, type: :numeric, desc: "Request timeout in seconds (default: 5)"
    option :headers, type: :string, banner: "HEADER_STRING", desc: "Custom headers (e.g., "Name1:Value1;Name2:Value2")"
    def http(url)
      puts pastel.cyan("CLI:") + " Received http command for URL: " + pastel.yellow.bold(url)
      cli_options = options.dup 
      puts pastel.dim("CLI options: #{cli_options.inspect}")

      web_client_options = { timeout: cli_options[:timeout] } 
      if cli_options[:headers]
        begin
          custom_headers = Hash[cli_options[:headers].split(';').map do |h|
            parts = h.split(':', 2)
            [parts[0].strip, parts[1] ? parts[1].strip : ""] 
          end]
          web_client_options[:headers] = custom_headers
          puts pastel.dim("  Using custom headers: #{custom_headers.inspect}")
        rescue => e
          puts pastel.red("Error parsing headers: #{e.message}. Ignoring custom headers.")
        end
      end
      
      web_client = HK::Web::Client.new
      results = web_client.probe(url, web_client_options)

      puts pastel.cyan("CLI: HTTP Probe Results for ") + pastel.yellow.bold(url)
      if results[:error]
        puts pastel.red("  Error: #{results[:error]}")
      else
        any_specific_display = cli_options[:status_code] || cli_options[:title] || cli_options[:tech_detect]
        if cli_options[:status_code] || !any_specific_display
          puts "  Status Code: " + (results[:status_code] ? pastel.green(results[:status_code].to_s) : pastel.yellow("N/A"))
        end
        if cli_options[:title]
          title_str = results[:title].nil? || results[:title].empty? ? "N/A or not found" : results[:title]
          puts "  Title: " + (results[:title] ? pastel.italic(title_str) : pastel.yellow(title_str))
        end
        if cli_options[:tech_detect]
          puts pastel.magenta("  Tech Detection:") + " (Placeholder - would show detected technologies)"
        end
        if !any_specific_display && !cli_options[:status_code] && results[:status_code]
             puts pastel.dim("  (Status code #{results[:status_code]} was found but not requested for display.)")
        elsif !any_specific_display && !results[:status_code] 
            puts pastel.yellow("  No specific information requested to display, and no primary info (like status code) available.")
        end
      end
    end

    desc "crawl URL", "Crawls a web target using HK::Web::Crawler."
    long_desc <<-LONGDESC
      Crawls the specified URL to discover links and content by leveraging HK::Web::Crawler.
      
      The crawler will respect the specified depth and attempt to stay on the same host
      as the initial URL. It uses HK::Web::Client for fetching pages.

      Example:
        hk crawl https://example.com --depth 2 --timeout 10
        hk crawl http://testsite.com -d 1 --headers "X-Custom:MyValue"
    LONGDESC
    option :depth, type: :numeric, aliases: "-d", desc: "Crawl depth limit (default: 2)"
    option :threads, type: :numeric, aliases: "-t", desc: "Number of concurrent threads (placeholder, not yet implemented)"
    option :timeout, type: :numeric, desc: "HTTP request timeout in seconds for each page fetch (default: 5)"
    option :headers, type: :string, banner: "HEADER_STRING", desc: "Custom headers for HTTP requests (e.g., "Name1:Value1")"

    def crawl(url)
      puts pastel.cyan("CLI:") + " Received crawl command for URL: " + pastel.yellow.bold(url)
      
      crawler_options = {
        depth: options[:depth] || 2 
      }
      crawler_options[:timeout] = options[:timeout] if options[:timeout]
      if options[:headers]
        begin
          custom_headers = Hash[options[:headers].split(';').map { |h| h.split(':', 2).map(&:strip) }]
          crawler_options[:headers] = custom_headers
          puts pastel.dim("  Using custom headers for crawler requests: #{custom_headers.inspect}")
        rescue => e
          puts pastel.red("Error parsing headers for crawler: #{e.message}. Ignoring custom headers.")
        end
      end

      puts pastel.dim("Crawler options: #{crawler_options.inspect}")

      begin
        crawler = HK::Web::Crawler.new(url, crawler_options)
      rescue ArgumentError => e
        puts pastel.red("Error initializing crawler: #{e.message}")
        return
      end
      
      puts pastel.magenta("Starting crawl, this might take a while...")
      results = crawler.crawl

      puts pastel.cyan("CLI: Crawl Results for ") + pastel.yellow.bold(results[:initial_url])
      puts "--------------------------------------------------"
      puts "  Crawled Pages Count: #{results[:crawled_count]}"
      puts "  Found Unique Links : #{results[:found_links_count]}"
      
      if results[:found_links].any?
        puts pastel.green("
  Found Links (#{results[:found_links].size}):")
        results[:found_links].each_with_index do |link, index|
          puts "    #{index + 1}. #{link}"
        end
      else
        puts pastel.yellow("
  No new links found within the scope and depth.")
      end

      if results[:errors].any?
        puts pastel.red("
  Errors during crawl (#{results[:errors].size}):")
        all_execution_errors.each_with_index do |err_info, idx| # Corrected variable name from prompt
          if err_info.is_a?(Hash) && err_info[:error]
            error_message = "Error ##{idx + 1}: "
            error_message += "Request Index: #{err_info[:request_index]} - " if err_info[:request_index]
            error_message += "#{err_info[:error]}"
            error_message += " (URL: #{err_info[:url]})" if err_info[:url]
            puts "    #{error_message}"
          else
            puts "    Error ##{idx + 1}: #{err_info}"
          end
        end
      end
      puts "--------------------------------------------------"
      puts pastel.cyan("Scan finished.")
    end
  end
end
