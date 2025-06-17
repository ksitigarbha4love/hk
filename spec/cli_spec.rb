require 'spec_helper'
require 'hk/cli'
require 'hk/web/crawler'
require 'fileutils'
require 'yaml'
require 'json'
require 'tty-progressbar'
require 'rouge'
require 'stringio' # For log capture in tests

RSpec.describe HK::CLI do
  # --- Top-level Helpers ---
  def capture_stdout_and_stderr(&block)
    original_stdout = $stdout; original_stderr = $stderr
    $stdout = fake_out = StringIO.new; $stderr = fake_err = StringIO.new
    begin; yield; ensure; $stdout = original_stdout; $stderr = original_stderr; end
    { stdout: fake_out.string, stderr: fake_err.string }
  end

  def run_cli(*args)
    original_argv = ARGV.dup; ARGV.replace(args.map(&:to_s)); output_streams = {}
    begin; output_streams = capture_stdout_and_stderr { HK::CLI.start(ARGV) };
    rescue SystemExit => e; output_streams[:stdout] = $stdout.string if $stdout.is_a?(StringIO) && output_streams[:stdout].nil?; output_streams[:stderr] = $stderr.string if $stderr.is_a?(StringIO) && output_streams[:stderr].nil?;
    end
    { stdout: output_streams[:stdout] || "", stderr: output_streams[:stderr] || "" }
  ensure; ARGV.replace(original_argv); end

  def create_temp_file(base_dir, filename, content); path = File.join(base_dir, filename); FileUtils.mkdir_p(File.dirname(path)); File.write(path, content); path; end
  def create_temp_yaml_template(base_dir, filename, content_hash); create_temp_file(base_dir, filename, content_hash.to_yaml); end
  def create_temp_ruby_template(base_dir, filename, content_string); create_temp_file(base_dir, filename, content_string); end

  # --- General Test Setup ---
  let(:cli_test_tmp_root) { "tmp/cli_logging_tests" }
  let(:log_capture_io) { StringIO.new } # For capturing log output directly

  around(:each) do |example|
    original_home = ENV['HOME']; ENV['HOME'] = File.join(cli_test_tmp_root, "home_user");
    FileUtils.rm_rf(cli_test_tmp_root); FileUtils.mkdir_p(cli_test_tmp_root);
    FileUtils.mkdir_p(File.join(cli_test_tmp_root, "home_user", ".hk", "templates"))
    FileUtils.mkdir_p(File.join(cli_test_tmp_root, "project", "templates"))

    # Store and reset HK.logger configuration around each test
    original_logger_appenders = HK.logger.appenders.dup
    original_logger_level = HK.logger.level
    ENV.delete('HK_LOG_LEVEL'); ENV.delete('HK_LOG_OUTPUT') # Clear ENV vars that affect logger
    # Reconfigure to a known default (stderr, info) before each test, then allow test to override
    HK.configure_logger(level: :info, output: 'stderr', force_default: true)

    HK::TemplateRegistry.clear! if defined?(HK::TemplateRegistry)

    example.run

    ENV['HOME'] = original_home; FileUtils.rm_rf(cli_test_tmp_root);
    # Restore logger
    HK.logger.level = original_logger_level
    HK.logger.clear_appenders
    original_logger_appenders.each { |appender| HK.logger.add_appenders(appender) }
  end

  # Helper to configure HK.logger to use a StringIO for a specific test
  def setup_hk_logger_to_stringio(io_object, level_sym = :info)
    HK.logger.clear_appenders
    appender = Logging.appenders.string_io('spec_string_io', string_io: io_object)
    appender.layout = Logging.layouts.pattern(
      pattern: '[%5l] %d HK : %m\n', # Simplified logger name for easier matching
      date_pattern: '%Y-%m-%d %H:%M:%S.%3N'
    )
    HK.logger.add_appenders(appender)
    HK.logger.level = level_sym
    io_object.string = "" # Clear it
  end

  # --- Basic CLI Command Tests (condensed) ---
  describe "hk version" do
    it "prints the version to STDOUT (now via logger.info)" do
      # Default logger goes to STDERR. If we want to check STDOUT for this command's specific output:
      # The `version` command in CLI uses HK.logger.info.
      # For this test, let's configure logger to STDOUT to check easily.
      HK.configure_logger(output: 'stdout', force_default: true)
      outputs = run_cli("version")
      expect(outputs[:stdout]).to include(HK::VERSION)
      expect(outputs[:stdout]).to include("Hēi Kè (HK) Security Framework version")
      expect(outputs[:stdout]).to include(" INFO HK : Hēi Kè") # Check log format
    end
  end

  # --- Tests for CLI logging options ---
  describe "CLI logging options" do
    let(:log_file_path) { File.join(cli_test_tmp_root, "clitest.log") }
    after(:each) { FileUtils.rm_f(log_file_path) }

    it "sets log level via --log-level" do
      setup_hk_logger_to_stringio(log_capture_io, :info) # Initial setup to capture
      run_cli("version", "--log-level", "debug") # This will reconfigure HK.logger
      # After run_cli, HK.logger is now at debug.
      expect(HK.logger.level).to eq(Logging.level_num(:debug))
      # Check if debug messages would be produced by some action here (version command itself is info)
      # This test mainly ensures the level is set on the logger object.
    end

    it "sets log output to a file via --log-output" do
      run_cli("version", "--log-output", log_file_path)
      expect(File.exist?(log_file_path)).to be true
      expect(File.read(log_file_path)).to include("HK : Hēi Kè (HK) Security Framework")
    end

    it "logs to STDERR by default if --log-output is not given" do
      outputs = run_cli("version") # No log options
      expect(outputs[:stderr]).to include(" INFO HK : Hēi Kè (HK) Security Framework")
      expect(outputs[:stdout]).to be_empty # Version output now goes via logger
    end

    it "logs to STDOUT if --log-output stdout is given" do
      outputs = run_cli("version", "--log-output", "stdout")
      expect(outputs[:stdout]).to include(" INFO HK : Hēi Kè (HK) Security Framework")
      expect(outputs[:stderr]).to be_empty
    end
  end

  # --- Tests for command-specific log messages ---
  describe "Command-specific log messages" do
    before(:each) do
      setup_hk_logger_to_stringio(log_capture_io, :info) # Capture all info+ level logs
    end

    context "for 'hk scan'" do
      let(:scan_target) { "http://scannable.example.com" }
      let(:templates_dir) { File.join(cli_test_tmp_root, "scan_cmd_log_templates") }
      let(:template_file) { create_temp_yaml_template(templates_dir, "log_test.yml", {'id'=>'log-test', 'info'=>{'name'=>'LogTest','severity'=>'low'},'requests'=>[{'path'=>'/'}]}) }

      before(:each) { FileUtils.mkdir_p(templates_dir) } # Ensure dir exists

      it "logs key operational INFO messages during a scan" do
        stub_request(:get, HK::Web::Crawler.normalize_url(scan_target)).to_return(status: 200, body: "content")
        run_cli("scan", scan_target, "-t", template_file)

        log_content = log_capture_io.string
        expect(log_content).to include("INFO HK : CLI: Scan command for target: #{HK::Web::Crawler.normalize_url(scan_target)}")
        expect(log_content).to include("INFO HK : Loading templates...")
        expect(log_content).to include("INFO HK : Successfully loaded 1 template(s).")
        expect(log_content).to include("INFO HK : Executing templates against #{HK::Web::Crawler.normalize_url(scan_target)}...")
        expect(log_content).to include("INFO HK : Scan finished.")
      end

      it "logs an ERROR if the target URL is invalid" do
        run_cli("scan", "::invalid_url::", "-t", template_file)
        expect(log_capture_io.string).to include("ERROR HK : Error: Invalid target URL provided: ::invalid_url::")
      end

      it "logs an ERROR if no templates are loaded" do
        non_existent_path = File.join(templates_dir, "non_existent_dir")
        run_cli("scan", scan_target, "-t", non_existent_path)
        # First, TemplateEngine logs errors about path not existing via load_from_path's error array
        # Then, CLI logs the "No templates were successfully loaded" error.
        log_content = log_capture_io.string
        expect(log_content).to include("WARN HK : Path '#{non_existent_path}': Path does not exist") # From TemplateEngine via CLI
        expect(log_content).to include("ERROR HK : No templates were successfully loaded. Aborting scan.")
      end
    end

    context "for 'hk ports'" do
      it "logs an ERROR if host resolution fails" do
        allow(Addrinfo).to receive(:getaddrinfo).with("unresolvable.host.hk", nil, :INET, :STREAM).and_raise(SocketError.new("Failed to resolve"))
        run_cli("ports", "unresolvable.host.hk", "-p", "80")
        expect(log_capture_io.string).to include("ERROR HK : Error: Host resolution failed: SocketError: Failed to resolve")
      end
    end
  end
  # ... (other CLI command tests can be added/updated similarly)
end
