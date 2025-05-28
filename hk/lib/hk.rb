module HK
  VERSION = "0.1.0" # Keep in sync with gemspec
  class Error < StandardError; end

  class Scanner
    attr_reader :target

    def initialize(target)
      @target = target
      puts "HK::Scanner initialized for target: #{target}"
    end

    def filter_open_ports
      puts "Scanner: Filtering open ports for #{@target}"
      self # Return self for chaining
    end

    def identify_services
      puts "Scanner: Identifying services for #{@target}"
      self
    end

    def check_vulnerabilities
      puts "Scanner: Checking vulnerabilities for #{@target}"
      self
    end

    def generate_report
      puts "Scanner: Generating report for #{@target}"
      self
    end
  end

  # HK::Net::Scanner is now in its own file
  require_relative 'hk/net/scanner'
  # HK::Web::Client for HTTP operations
  require_relative 'hk/web/client'
  # HK::Web::Crawler for crawling websites
  require_relative 'hk/web/crawler'
  # HK::TemplateEngine for loading and running templates
  require_relative 'hk/template_engine'
  # HK::CoreDSL for Ruby native templates (HK.template method)
  require_relative 'hk/core_dsl'
  # HK::Http::ClientWrapper for use in Ruby DSL templates
  require_relative 'hk/http/client_wrapper'
  # HK::SubdomainFinder for discovering subdomains
  require_relative 'hk/subdomain_finder'

  def self.scan(target)
    scanner = HK::Scanner.new(target) # Explicitly HK::Scanner to avoid ambiguity
    if block_given?
      yield scanner
    end
    scanner # Always return the scanner instance
  end

  def self.crawl(target)
    puts "HK.crawl called with target: #{target}"
  end

  def self.security_scan(&block)
    puts "HK.security_scan called."
    if block_given?
      # In a real DSL, we would instance_eval or yield an object
      # that has methods like target, port_scan, etc.
      # For now, just call the block.
      yield
      puts "HK.security_scan block executed."
    else
      puts "HK.security_scan called without a block."
    end
  end

  def self.interactive(&block)
    puts "HK.interactive mode initiated."
    if block_given?
      # In a real interactive mode, this block might represent
      # a pre-configured set of commands, or we'd start a REPL.
      # For now, just call the block.
      yield
      puts "HK.interactive block (pre-commands) executed."
    else
      puts "HK.interactive mode started. (No pre-commands given)"
      # Later, this is where a REPL would start (e.g., using IRB.start or similar)
    end
  end
end
