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
    end

    desc "version", "Prints the HK version"
    def version
      hk_version_colored = pastel.bold(pastel.blue(HK::VERSION))
      puts "Hēi Kè (HK) Security Framework version #{hk_version_colored}"
    end

    desc "scan TARGET", "Scans a target. Supports simple direct scan for now."
    long_desc <<-LONGDESC
      Performs a scan against the specified TARGET.
      This initial version calls the foundational HK.scan method.
    LONGDESC
    def scan(target)
      puts pastel.cyan("CLI:") + " Received scan command for target: " + pastel.bold(pastel.yellow(target))
      HK.scan(target)
    end

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
            if start_port && end_port && start_port > 0 && end_port >= start_port && end_port <= 65535 && start_port <= 65535
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
    # option :scope, type: :string, desc: "Define crawl scope (placeholder, current default is same host)"
    option :timeout, type: :numeric, desc: "HTTP request timeout in seconds for each page fetch (default: 5)"
    option :headers, type: :string, banner: "HEADER_STRING", desc: "Custom headers for HTTP requests (e.g., "Name1:Value1")"

    def crawl(url)
      puts pastel.cyan("CLI:") + " Received crawl command for URL: " + pastel.yellow.bold(url)
      
      crawler_options = {
        depth: options[:depth] || 2 # Default depth if not provided by Thor's default
      }
      # Pass HTTP client related options if they are present
      crawler_options[:timeout] = options[:timeout] if options[:timeout]
      if options[:headers]
        begin
          # Basic header parsing: "Key1:Value1;Key2:Value2"
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
      
      # Potentially long-running operation, maybe add a spinner later
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
        results[:errors].each_with_index do |err_info, index|
          puts "    #{index + 1}. URL: #{err_info[:url]}"
          puts "       Error: #{err_info[:error]}"
        end
      end
      puts "--------------------------------------------------"
    end
  end
end
