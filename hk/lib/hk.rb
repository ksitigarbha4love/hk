require 'logging' # For structured logging

module HK
  # --- Gem Version ---
  VERSION = "0.1.0"

  # --- Error Base Class ---
  class Error < StandardError; end

  # --- Logger Configuration ---
  # Allow other classes to access the logger via HK.logger
  class << self
    attr_accessor :logger
  end

  def self.configure_logger(level: nil, output: nil, force_default: false)
    # Determine log level: argument > ENV > default
    log_level_str = level&.to_s&.downcase || ENV['HK_LOG_LEVEL']&.downcase || 'info'

    # Determine log output: argument > ENV > default
    log_output_str = output&.to_s || ENV['HK_LOG_OUTPUT'] || 'stderr'

    # Get the root logger for 'HK'
    # If force_default or no logger yet, create and configure.
    # Otherwise, if already configured (e.g. by CLI), don't stomp on it unless forced.
    if force_default || @logger.nil? || @logger.name != 'HK'
        @logger = Logging.logger['HK'] # Using Logging.logger[self] might be HK::HK
                                     # Logging.logger['HK'] is cleaner for a specific root name.

        # Clear existing appenders and levels if reconfiguring with force_default
        if force_default
            @logger.clear_appenders
            # Logging gem might not have a simple way to reset level to undefined,
            # but setting it to the new one is fine.
        end

        # Only add appenders if none exist or if forced (to avoid duplicate appenders on re-configure)
        if @logger.appenders.empty? || force_default
            case log_output_str.downcase
            when 'stdout'
              appender = Logging.appenders.stdout
            when 'stderr'
              appender = Logging.appenders.stderr
            else # Assume it's a file path
              begin
                appender = Logging.appenders.file(log_output_str)
              rescue SystemCallError => e
                # Fallback to stderr if file path is invalid
                $stderr.puts "Warning: Could not open log file '#{log_output_str}': #{e.message}. Defaulting to STDERR."
                appender = Logging.appenders.stderr
              end
            end

            # Define a layout (pattern)
            # Example: [FATAL] 2023-10-27 10:00:00.123 HK : My log message
            layout_pattern = Logging.layouts.pattern(
              pattern: '[%5l] %d %c : %m\n', # level, date, logger name, message
              date_pattern: '%Y-%m-%d %H:%M:%S.%3N'
            )
            appender.layout = layout_pattern
            @logger.add_appenders(appender)
        end

        # Set level (this can be changed later by CLI options too)
        begin
          @logger.level = log_level_str.to_sym
        rescue ArgumentError # Invalid log level string
          @logger.level = :info # Default to info if invalid level given
          # $stderr.puts "Warning: Invalid log level '#{log_level_str}'. Defaulting to :info."
        end
    end
    @logger
  end

  # Initialize logger with default settings (can be overridden by ENV or later by CLI)
  # This ensures HK.logger is available as soon as hk.rb is required.
  configure_logger unless @logger # Configure only if not already set (e.g., by a test)


  # --- Existing class/module requires (ensure these are after logger setup if they use HK.logger at load time) ---
  require_relative 'hk/net/scanner'
  require_relative 'hk/web/client'
  require_relative 'hk/web/crawler'
  require_relative 'hk/template_engine'
  require_relative 'hk/core_dsl'
  require_relative 'hk/http/client_wrapper' # Added from subtask 28
  require_relative 'hk/subdomain_finder'   # Added from subtask 29

  # --- Existing HK module methods (scan, crawl, etc.) ---
  # These methods might be refactored later to use HK.logger

  class Scanner # Original HK::Scanner
    attr_reader :target
    def initialize(target)
      @target = target
      # HK.logger.info "HK::Scanner initialized for target: #{target}" # Example usage
      puts "HK::Scanner initialized for target: #{target}" # Original puts
    end
    def filter_open_ports; puts "Scanner: Filtering open ports for #{@target}"; self; end
    def identify_services; puts "Scanner: Identifying services for #{@target}"; self; end
    def check_vulnerabilities; puts "Scanner: Checking vulnerabilities for #{@target}"; self; end
    def generate_report; puts "Scanner: Generating report for #{@target}"; self; end
  end

  def self.scan(target)
    # HK.logger.debug "HK.scan called with target: #{target}"
    scanner = HK::Scanner.new(target)
    if block_given?
      yield scanner
    end
    scanner
  end

  def self.crawl(target)
    # HK.logger.debug "HK.crawl called with target: #{target}"
    # This is a placeholder; actual crawl is HK::Web::Crawler
    # For now, to avoid breaking CLI if `hk crawl` is called without HK::Web::Crawler integration yet:
    if defined?(HK::Web::Crawler)
        HK.logger.warn "Direct HK.crawl is deprecated. Use HK::Web::Crawler or CLI."
        # Placeholder for direct call if needed, or raise error.
        # For now, just log and use old puts.
        puts "HK.crawl called with target: #{target} (using old placeholder)"
    else
        puts "HK.crawl called with target: #{target}"
    end
  end

  def self.security_scan(&block)
    # HK.logger.info "HK.security_scan called."
    puts "HK.security_scan called." # Original puts
    if block_given?
      yield
      # HK.logger.debug "HK.security_scan block executed."
      puts "HK.security_scan block executed." # Original puts
    else
      # HK.logger.debug "HK.security_scan called without a block."
      puts "HK.security_scan called without a block." # Original puts
    end
  end

  def self.interactive(&block)
    # HK.logger.info "HK.interactive mode initiated."
    puts "HK.interactive mode initiated." # Original puts
    if block_given?
      yield
      # HK.logger.debug "HK.interactive block (pre-commands) executed."
      puts "HK.interactive block (pre-commands) executed." # Original puts
    else
      # HK.logger.debug "HK.interactive mode started. (No pre-commands given)"
      puts "HK.interactive mode started. (No pre-commands given)" # Original puts
    end
  end

end
