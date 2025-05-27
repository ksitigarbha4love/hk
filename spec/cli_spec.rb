require 'spec_helper'
require 'hk/cli' # Ensure the CLI class is loaded
require 'json' # For parsing JSON string in helper

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

  # More robust helper that resets ARGV after command
  def run_cli(*args)
    original_argv = ARGV.dup
    ARGV.replace(args.map(&:to_s)) # Ensure all args are strings
    output = capture_stdout { HK::CLI.start(ARGV) }
  ensure
    ARGV.replace(original_argv)
    output # Ensure output is returned
  end

  # Tests from previous subtask (around turn 106)
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
    end
  end

  # Original tests for "hk ports TARGET" (from around turn 106)
  # These might be a bit redundant with the new detailed parsing tests,
  # but keeping them for now to show the merge.
  describe "hk ports TARGET (basic invocation)" do
    it "invokes ports scan with a target and default ports" do
      output = run_cli("ports", "example.net") # Target changed to avoid example.com specific logic for this basic test
      expect(output).to include("CLI: Received ports command for target: example.net")
      expect(output).to include("(No ports specified, using default list:")
      expect(output).to include("Open Ports:") # Simulated result
    end

    it "shows help for ports" do
      output = run_cli("help", "ports")
      expect(output).to include("Usage:")
      expect(output).to include("hk ports TARGET")
    end
  end
  
  # New context for detailed 'hk ports' argument parsing (from current task)
  context "when testing 'hk ports' command argument parsing" do
    # Helper to extract the "Effective ports to be scanned" line from output
    def extract_scanned_ports_from_output(output)
      match = output.match(/Effective ports to be scanned \(\d+\): (\[.*\])/)
      return JSON.parse(match[1].gsub('=>', ':')) if match && match[1] # JSON.parse and handle rocket if any
      return nil
    end
    
    # Helper to extract warning messages
    def extract_warnings_from_output(output)
      output.scan(/Warning: Invalid port.*Skipping\./).join("\n") # Corrected join character
    end

    it "parses single port for 'ports' command" do
      output = run_cli("ports", "target", "-p", "80")
      expect(extract_scanned_ports_from_output(output)).to eq([80])
    end

    it "parses multiple comma-separated ports" do
      output = run_cli("ports", "target", "-p", "80,443,22")
      expect(extract_scanned_ports_from_output(output)).to eq([22, 80, 443]) # Expect sorted
    end

    it "parses a single port range" do
      output = run_cli("ports", "target", "-p", "80-82")
      expect(extract_scanned_ports_from_output(output)).to eq([80, 81, 82])
    end

    it "parses multiple port ranges" do
      output = run_cli("ports", "target", "-p", "80-81,443-444")
      expect(extract_scanned_ports_from_output(output)).to eq([80, 81, 443, 444])
    end

    it "parses mixed single ports and ranges, ensuring uniqueness and order" do
      output = run_cli("ports", "target", "-p", "443,80-81,443,22")
      expect(extract_scanned_ports_from_output(output)).to eq([22, 80, 81, 443])
    end

    it "handles invalid port numbers and skips them, showing warnings" do
      output = run_cli("ports", "target", "-p", "80,abc,0,65536,22")
      expect(extract_scanned_ports_from_output(output)).to eq([22, 80])
      warnings = extract_warnings_from_output(output)
      expect(warnings).to include("Invalid port number 'abc'")
      expect(warnings).to include("Invalid port number '0'")
      expect(warnings).to include("Invalid port number '65536'")
    end

    it "handles invalid port ranges and skips them, showing warnings" do
      output = run_cli("ports", "target", "-p", "80,70-60,443-xyz")
      expect(extract_scanned_ports_from_output(output)).to eq([80])
      warnings = extract_warnings_from_output(output)
      expect(warnings).to include("Invalid port range '70-60'")
      expect(warnings).to include("Invalid port range '443-xyz'")
    end
    
    it "uses --top-ports N if provided, overriding -p" do
      output = run_cli("ports", "target", "--top-ports", "3", "-p", "1,2,3,4,5,6")
      # Placeholder top_n_list = [80, 443, 22, 21, 25, ...]
      expect(extract_scanned_ports_from_output(output)).to eq([80, 443, 22]) # Sorted
      expect(output).to include("Using top 3 ports based on --top-ports 3")
      expect(output).not_to include("Using ports from -p option")
    end

    it "uses default port list if no options are given" do
      output = run_cli("ports", "target_default_ports") # Use a different target to avoid example.com logic interfering
      expect(output).to include("(No ports specified, using default list:")
      expect(extract_scanned_ports_from_output(output)).not_to be_empty
    end
    
    it "reports an error if port parsing results in an empty list from -p and not using default/top-ports" do
      output = run_cli("ports", "target", "-p", "abc,def")
      expect(output).to include("Error: No valid ports specified or derived.")
      expect(extract_scanned_ports_from_output(output)).to be_nil # No "Effective ports" line
    end
  end

  # Tests from previous subtask (around turn 106)
  describe "hk http URL (basic invocation)" do
    it "invokes http probe for a URL" do
      output = run_cli("http", "https://example.com")
      expect(output).to include("CLI: Received http command for URL: https://example.com")
      expect(output).to include("HK::Web::Client initialized.")
    end

    it "invokes http probe with boolean flags" do
      output = run_cli("http", "https://example.com", "--status-code", "--title")
      expect(output).to include("CLI options: {:status_code=>true, :title=>true}")
      expect(output).to include("Status Code: 200")
      expect(output).to include("Title: Dummy Title")
    end

    it "shows help for http" do
      output = run_cli("help", "http")
      expect(output).to include("Usage:")
      expect(output).to include("hk http URL")
    end
  end

  describe "hk crawl URL (basic invocation)" do
    it "invokes crawl for a URL" do
      output = run_cli("crawl", "https://example.com")
      expect(output).to include("CLI: Received crawl command for URL: https://example.com")
      expect(output).to include("HK.crawl called with target: https://example.com")
    end

    it "invokes crawl with options" do
      output = run_cli("crawl", "https://example.com", "--depth", "3")
      expect(output).to include("CLI options: {:depth=>3}")
      expect(output).to include("CLI: Crawl depth specified: 3")
    end

    it "shows help for crawl" do
      output = run_cli("help", "crawl")
      expect(output).to include("Usage:")
      expect(output).to include("hk crawl URL")
    end
  end
end
