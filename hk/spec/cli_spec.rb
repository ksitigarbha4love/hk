require 'spec_helper'
require 'hk/cli' # Ensure the CLI class is loaded

RSpec.describe HK::CLI do
  # Helper to capture stdout
  def capture_stdout(&block)
    original_stdout = $stdout
    $stdout = fake = StringIO.new
    begin
      yield
    ensure
      $stdout = original_stdout
    end
    fake.string
  end

  # Helper to run CLI commands
  # ARGV needs to be cleared and set for each Thor command invocation
  def run_cli_command(*args)
    capture_stdout do
      ARGV.replace(args) # Set ARGV for Thor
      HK::CLI.start(ARGV)
    end
  end
  
  # More robust helper that resets ARGV after command
  def run_cli(*args)
    original_argv = ARGV.dup
    ARGV.replace(args)
    output = capture_stdout { HK::CLI.start(ARGV) }
  ensure
    ARGV.replace(original_argv)
    output # Ensure output is returned even if there's an error during ARGV reset
  end


  describe "hk version" do
    it "prints the version" do
      output = run_cli("version")
      expect(output).to include(HK::VERSION)
      expect(output).to include("Hēi Kè (HK) Security Framework version")
    end
  end

  describe "hk scan TARGET" do
    it "invokes scan with a target" do
      output = run_cli("scan", "example.com")
      expect(output).to include("CLI: Received scan command for target: example.com")
      expect(output).to include("HK::Scanner initialized for target: example.com") # From HK.scan
    end

    it "shows help for scan" do
      output = run_cli("help", "scan")
      expect(output).to include("Usage:")
      expect(output).to include("hk scan TARGET")
      expect(output).to include("Performs a scan against the specified TARGET.")
    end
  end

  describe "hk ports TARGET" do
    it "invokes ports scan with a target and default ports" do
      output = run_cli("ports", "example.net")
      expect(output).to include("CLI: Received ports command for target: example.net")
      expect(output).to include("Ports to be scanned:") # Default list
      expect(output).to include("Open Ports:") # Simulated result
    end

    it "invokes ports scan with specified ports" do
      output = run_cli("ports", "example.com", "-p", "80,443")
      expect(output).to include("CLI: Received ports command for target: example.com")
      expect(output).to include("Ports to be scanned: [\"80\", \"443\"]") # Corrected expectation for string array
      expect(output).to include("Open Ports: 80, 443") # Based on current simulation for example.com
    end

    it "shows help for ports" do
      output = run_cli("help", "ports")
      expect(output).to include("Usage:")
      expect(output).to include("hk ports TARGET")
      expect(output).to include("Scans ports on a target using simulated TCP scan.")
    end
  end

  describe "hk http URL" do
    it "invokes http probe for a URL" do
      output = run_cli("http", "https://example.com")
      expect(output).to include("CLI: Received http command for URL: https://example.com")
      expect(output).to include("HK::Web::Client initialized.")
      expect(output).to include("Probing URL https://example.com")
    end

    it "invokes http probe with boolean flags" do
      output = run_cli("http", "https://example.com", "--status-code", "--title")
      expect(output).to include("CLI: Received http command for URL: https://example.com")
      # Thor converts kebab-case options to snake_case symbols in the options hash
      expect(output).to include("CLI options: {:status_code=>true, :title=>true}") # Corrected expectation
      expect(output).to include("Status Code: 200") # From placeholder
      expect(output).to include("Title: Dummy Title")  # From placeholder
    end

    it "shows help for http" do
      output = run_cli("help", "http")
      expect(output).to include("Usage:")
      expect(output).to include("hk http URL")
      expect(output).to include("Performs HTTP probing on a URL.")
    end
  end

  describe "hk crawl URL" do
    it "invokes crawl for a URL" do
      output = run_cli("crawl", "https://example.com")
      expect(output).to include("CLI: Received crawl command for URL: https://example.com")
      expect(output).to include("HK.crawl called with target: https://example.com") # From HK.crawl
    end

    it "invokes crawl with options" do
      output = run_cli("crawl", "https://example.com", "--depth", "3")
      expect(output).to include("CLI: Received crawl command for URL: https://example.com")
      expect(output).to include("CLI options: {:depth=>3}") # Corrected expectation
      expect(output).to include("CLI: Crawl depth specified: 3")
    end

    it "shows help for crawl" do
      output = run_cli("help", "crawl")
      expect(output).to include("Usage:")
      expect(output).to include("hk crawl URL")
      expect(output).to include("Crawls a web target.")
    end
  end
end
