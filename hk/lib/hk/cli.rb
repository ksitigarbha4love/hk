require 'thor'
require 'tty-color' # Add this
require_relative '../hk' # To access HK::VERSION

module HK
  class CLI < Thor
    # Default task if no command is given, or for `hk help`
    def self.exit_on_failure?
      true # Exit with a non-zero status on command failure
    end

    no_commands do # Methods defined here are not exposed as CLI commands
      def pastel
        @pastel ||= TTY::Color
      end
    end

    desc "version", "Prints the HK version"
    def version
      hk_version_colored = pastel.bold(pastel.blue(HK::VERSION)) # Corrected usage
      puts "Hēi Kè (HK) Security Framework version #{hk_version_colored}"
    end

    # Placeholder for the default action (e.g., if just 'hk' is typed)
    # Thor usually calls help if no command matches.
    # We can also define a default_task if needed later.
    # For now, relying on Thor's default help is fine.

    desc "scan TARGET", "Scans a target. Supports simple direct scan for now."
    long_desc <<-LONGDESC
      Performs a scan against the specified TARGET.
      This initial version calls the foundational HK.scan method.
      Later, this will be expanded with more options for port selection,
      template usage, etc.

      Example:
        hk scan example.com
    LONGDESC
    # option :ports, type: :array, aliases: "-p", desc: "Specific ports to scan"
    # option :template, type: :string, aliases: "-t", desc: "Path to a scan template"
    def scan(target)
      puts pastel.cyan("CLI:") + " Received scan command for target: " + pastel.bold(pastel.yellow(target)) # Corrected
      # Call the existing HK.scan method
      # HK.scan already prints "HK::Scanner initialized for target: <target>"
      scanner_instance = HK.scan(target) # HK.scan itself might also use colors later
      # For now, we don't do anything else with the scanner_instance here.
      # The original HK.scan method itself prints output.
      # We might want to make HK.scan return results that the CLI then formats.
    end

    desc "ports TARGET", "Scans ports on a target using simulated TCP scan." # Updated desc
    long_desc <<-LONGDESC
      Performs a port scan against the specified TARGET.
      This command uses a simulated TCP scan to identify open ports.
      You can specify ports with -p, or use --top-ports.

      Example:
        hk ports example.com -p 80,443,8080
        hk ports example.com --top-ports 10
    LONGDESC
    option :ports, type: :string, aliases: "-p", banner: "PORTS", desc: "Comma-separated list of ports (e.g., 80,443,8080). Ranges later."
    option :rate, type: :numeric, desc: "Scan rate (packets per second)" # Kept for future use
    option :top_ports, type: :numeric, banner: "N", desc: "Scan the top N most common ports"
    def ports(target)
      puts pastel.cyan("CLI:") + " Received ports command for target: " + pastel.bold(pastel.yellow(target))
      cli_options = options.dup # Thor options object is frozen

      # Parse ports string into an array of integers
      ports_to_scan_input = cli_options[:ports]
      parsed_ports = []
      if ports_to_scan_input
        parsed_ports = ports_to_scan_input.split(',').map(&:strip).map(&:to_i).uniq.sort.select { |p| p > 0 && p <= 65535 }
      elsif cli_options[:top_ports]
        # Placeholder for top_ports logic
        top_n = cli_options[:top_ports] || 5
        # Simulate a list of common ports
        common_ports = [21, 22, 25, 53, 80, 110, 143, 443, 3306, 3389, 8080, 8443, 5900, 6379, 9200, 9300, 27017]
        parsed_ports = common_ports.sample(top_n).sort
        puts pastel.dim("  (Using top #{top_n} ports (simulated): #{parsed_ports.inspect})")
      else
        # Default list if no specific ports or top_ports are given
        parsed_ports = [21, 22, 25, 53, 80, 110, 143, 443, 445, 3306, 3389, 5432, 5900, 6379, 8000, 8080, 8443, 9200, 9300, 27017]
        puts pastel.dim("  (No ports specified, using default list: #{parsed_ports.size} ports)")
      end

      if parsed_ports.empty? && !cli_options[:top_ports] # if top_ports was specified but resolved to empty, that's fine
         puts pastel.red("Error: No valid ports specified or derived. Use -p or --top-ports.")
         return
      end
      
      puts pastel.dim("CLI options for scan: #{cli_options.inspect}")
      # Ensure parsed_ports is an array of integers before inspecting
      puts pastel.dim("Ports to be scanned: #{parsed_ports.map(&:to_s).inspect}")


      net_scanner = HK::Net::Scanner.new
      # Pass the parsed ports array and other relevant options to tcp_scan
      scan_results = net_scanner.tcp_scan(target, parsed_ports, cli_options)

      puts pastel.cyan("CLI: Scan Results for ") + pastel.yellow.bold(target)
      if scan_results[:open_ports].any?
        puts pastel.green("  Open Ports: ") + scan_results[:open_ports].join(', ')
      else
        puts pastel.yellow("  No open ports found from the scanned list.")
      end
      # Optionally display closed ports if verbose or a specific flag is set
      # puts "  Closed Ports: " + scan_results[:closed_ports].join(', ')
    end

    desc "http URL", "Performs HTTP probing on a URL."
    long_desc <<-LONGDESC
      Sends HTTP requests to the specified URL(s).
      This initial version is a placeholder and will be enhanced with actual HTTP client logic
      from HK::Web::Client, inspired by HTTPx.

      Example:
        hk http https://example.com -sc -title -timeout 5
    LONGDESC
    option :status_code, type: :boolean, aliases: "-sc", desc: "Display status code"
    option :title, type: :boolean, desc: "Extract and display page title"
    option :tech_detect, type: :boolean, aliases: "-td", desc: "Perform technology detection"
    option :timeout, type: :numeric, desc: "Request timeout in seconds"
    def http(url)
      puts pastel.cyan("CLI:") + " Received http command for URL: " + pastel.bold(pastel.yellow(url)) # Corrected
      puts pastel.dim("CLI options: #{options.inspect}") # Display Thor options

      # Instantiate Web::Client and call the placeholder
      web_client = HK::Web::Client.new
      results = web_client.probe(url, options) # Pass Thor options down
      puts pastel.cyan("CLI:") + " HK::Web::Client returned: " + pastel.dim(results.inspect)

      # Conditionally print info based on boolean flags
      if options[:status_code]
        puts "Status Code: " + pastel.green(results[:status_code].to_s)
      end
      if options[:title]
        # Ensure results[:title] is a string before applying .italic
        # pastel.italic only works on strings.
        title_str = results[:title].nil? ? "" : results[:title].to_s
        puts "Title: " + pastel.italic(title_str)
      end
      if options[:tech_detect]
        puts pastel.magenta("Tech Detection:") + " (Placeholder - would show detected technologies)"
      end
    end

    desc "crawl URL", "Crawls a web target."
    long_desc <<-LONGDESC
      Crawls the specified URL to discover links and content.
      This initial version calls the foundational HK.crawl method.
      Later, this will be expanded with more options for crawl depth,
      scope management, and integration with HK::Web::Crawler.

      Example:
        hk crawl https://example.com --depth 3 --threads 5
    LONGDESC
    option :depth, type: :numeric, aliases: "-d", desc: "Crawl depth limit"
    option :threads, type: :numeric, aliases: "-t", desc: "Number of concurrent threads"
    option :scope, type: :string, desc: "Define crawl scope (e.g., 'domain', 'subdomain', 'path')"
    def crawl(url)
      puts pastel.cyan("CLI:") + " Received crawl command for URL: " + pastel.bold(pastel.yellow(url)) # Corrected
      puts pastel.dim("CLI options: #{options.inspect}") # Display Thor options

      # Call the existing HK.crawl method
      # HK.crawl currently just prints "HK.crawl called with target: <url>"
      HK.crawl(url) # HK.crawl itself might also use colors later
      # We might want HK.crawl to return results or take options in the future.
      # For now, just passing the options to the CLI output is fine.
      if options[:depth]
        puts pastel.cyan("CLI:") + " Crawl depth specified: " + pastel.yellow(options[:depth].to_s)
      end
    end
  end
end
