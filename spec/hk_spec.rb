require 'spec_helper'
# hk.rb (which includes HK.configure_logger and HK.logger) is loaded by spec_helper
require 'stringio'   # For StringIO
require 'fileutils'  # For file operations in tests

RSpec.describe HK do
  let(:log_string_io) { StringIO.new }
  # Store original logger state to restore after tests in this file.
  # This is important if other spec files run after this and expect default logger.
  # However, manipulating class variables like this across tests can be tricky.
  # A cleaner way might be to ensure HK.configure_logger can fully reset.

  original_logger_level = nil
  original_logger_appenders = nil

  before(:all) do
    # Save the initial state of the logger once before any tests in this file run.
    # This assumes HK.logger is already initialized when spec_helper loads 'hk'.
    if HK.logger
      original_logger_level = HK.logger.level
      original_logger_appenders = HK.logger.appenders.dup
    end
    FileUtils.mkdir_p("tmp") # Ensure tmp directory exists for log file tests
  end

  after(:all) do
    # Restore the initial logger state after all tests in this file.
    if HK.logger && original_logger_level && original_logger_appenders
      HK.logger.level = original_logger_level
      HK.logger.clear_appenders
      original_logger_appenders.each { |appender| HK.logger.add_appenders(appender) }
    end
    FileUtils.rm_rf("tmp/env_test.log")
    FileUtils.rm_rf("tmp/param_test.log")
    # No need to rm_rf("tmp") itself unless it was created solely for this.
  end

  # Helper to temporarily change ENV variables
  def with_env(vars)
    original_env = {}
    vars.each do |key, value|
      original_env[key] = ENV[key]
      ENV[key] = value
    end
    yield
  ensure
    vars.each_key { |key| ENV[key] = original_env[key] }
  end

  # Configure a temporary string appender for testing log output
  # This helper will reconfigure the HK.logger directly.
  def setup_string_logger_for_hk(level_symbol = :info)
    # Use HK.configure_logger to set the output to our StringIO object
    # This requires HK.configure_logger to correctly handle an IO object as output.
    # The current HK.configure_logger expects 'stdout', 'stderr', or a filepath string.
    # So, this helper needs to adapt or HK.configure_logger needs enhancement.
    # For now, let's assume we can temporarily swap appenders on the existing logger.

    # Clear existing appenders from the global HK logger for this test
    HK.logger.clear_appenders

    # Create a new string appender
    string_io_appender = Logging.appenders.string_io('test_string_io_appender', string_io: log_string_io)
    string_io_appender.layout = Logging.layouts.pattern(
        pattern: '[%5l] %d %c : %m\n', # Match the default pattern in SUT
        date_pattern: '%Y-%m-%d %H:%M:%S.%3N'
    )
    HK.logger.add_appenders(string_io_appender)
    HK.logger.level = level_symbol
    log_string_io.string = "" # Clear buffer before test
  end

  before(:each) do
    # Reset logger to a known state before each test.
    # This ensures that ENV var tests don't interfere with direct param tests.
    # `force_default: true` clears appenders and resets to defaults (or ENV).
    ENV.delete('HK_LOG_LEVEL')
    ENV.delete('HK_LOG_OUTPUT')
    # Reconfigure to default (stderr, info) to ensure clean state for each test example.
    # The `force_default: true` ensures it rebuilds appenders.
    HK.configure_logger(level: :info, output: 'stderr', force_default: true)
    log_string_io.string = "" # Clear StringIO buffer if it was used by a previous test
  end

  describe ".configure_logger" do
    it "defaults to INFO level and STDERR output" do
      # HK.configure_logger is called on load. We check its state.
      expect(HK.logger.name).to eq('HK') # Check logger name
      expect(HK.logger.level).to eq(Logging.level_num(:info))
      # Check appender type (might be tricky if multiple appenders or complex setup)
      # For simplicity, check if there's at least one appender and it's Stderr.
      # This assumes default setup adds only one appender.
      expect(HK.logger.appenders.first).to be_a(Logging::Appenders::Stderr)
    end

    it "configures level via HK_LOG_LEVEL environment variable" do
      with_env 'HK_LOG_LEVEL' => 'debug' do
        HK.configure_logger(force_default: true) # Re-init to pick up ENV
        expect(HK.logger.level).to eq(Logging.level_num(:debug))
      end
    end

    it "configures output to STDOUT via HK_LOG_OUTPUT environment variable" do
      with_env 'HK_LOG_OUTPUT' => 'stdout' do
        HK.configure_logger(force_default: true)
        expect(HK.logger.appenders.first).to be_a(Logging::Appenders::Stdout)
      end
    end

    it "configures output to a file via HK_LOG_OUTPUT environment variable" do
      log_file = "tmp/env_test.log"
      FileUtils.rm_f(log_file)
      with_env 'HK_LOG_OUTPUT' => log_file do
        HK.configure_logger(force_default: true)
        expect(HK.logger.appenders.first).to be_a(Logging::Appenders::File)
        # The 'name' of the file appender is its path.
        expect(HK.logger.appenders.first.name).to eq(log_file)
        HK.logger.info("Test log to file via ENV") # Write something
      end
      expect(File.read(log_file)).to include("Test log to file via ENV")
      FileUtils.rm_f(log_file)
    end

    it "configures level via direct parameter, overriding ENV" do
      with_env 'HK_LOG_LEVEL' => 'error' do
        # Pass force_default:true if we want to ensure only this direct param affects config
        # and not merge with previous ENV-based config (e.g., if appender was different).
        HK.configure_logger(level: :warn, force_default: true)
        expect(HK.logger.level).to eq(Logging.level_num(:warn))
      end
    end

    it "configures output via direct parameter, overriding ENV" do
      log_file = "tmp/param_test.log"
      FileUtils.rm_f(log_file)
      with_env 'HK_LOG_OUTPUT' => 'stdout' do
        HK.configure_logger(output: log_file, force_default: true)
        expect(HK.logger.appenders.first).to be_a(Logging::Appenders::File)
        expect(HK.logger.appenders.first.name).to eq(log_file)
        HK.logger.info("Test log to file via param")
      end
      expect(File.read(log_file)).to include("Test log to file via param")
      FileUtils.rm_f(log_file)
    end

    it "handles invalid log level string by defaulting to INFO" do
        # Capture $stderr to check for the warning message from configure_logger
        original_stderr = $stderr
        $stderr = captured_stderr = StringIO.new
        begin
            HK.configure_logger(level: "bogus_level", force_default: true, output: 'stderr') # Output to stderr to simplify
        ensure
            $stderr = original_stderr
        end
        expect(HK.logger.level).to eq(Logging.level_num(:info))
        # The SUT's configure_logger comments out the warning to $stderr. If it were active:
        # expect(captured_stderr.string).to include("Warning: Invalid log level 'bogus_level'. Defaulting to :info.")
    end

    it "defaults to STDERR if log file path is invalid/unwritable" do
        original_stderr = $stderr
        $stderr = captured_stderr = StringIO.new
        begin
            HK.configure_logger(output: "/nonexistent_dir/logfile.log", force_default: true)
        ensure
            $stderr = original_stderr
        end
        expect(HK.logger.appenders.first).to be_a(Logging::Appenders::Stderr)
        expect(captured_stderr.string).to include("Warning: Could not open log file '/nonexistent_dir/logfile.log'")
    end
  end

  describe "Logging basic messages" do
    before(:each) do
      # For these tests, specifically set up the string logger
      setup_string_logger_for_hk(:debug)
    end

    it "logs an INFO message correctly" do
      HK.logger.info "This is an info test."
      expect(log_string_io.string).to include(" INFO HK : This is an info test.")
    end

    it "logs a DEBUG message correctly if level allows" do
      HK.logger.debug "This is a debug test."
      expect(log_string_io.string).to include("DEBUG HK : This is a debug test.")
    end

    it "does not log a DEBUG message if level is INFO" do
      # Reconfigure logger to :info for this specific test through the helper
      setup_string_logger_for_hk(:info)
      HK.logger.debug "This debug message should not appear."
      expect(log_string_io.string).not_to include("This debug message should not appear.")
    end
  end
end
