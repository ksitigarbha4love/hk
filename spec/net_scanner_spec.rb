require 'spec_helper'
require 'hk/net/scanner' # Make sure TTY::Color is available or mock it

RSpec.describe HK::Net::Scanner do
  let(:scanner) { HK::Net::Scanner.new }
  
  # Helper to capture HK::Net::Scanner's internal puts
  def capture_scanner_output(&block)
    original_stdout = $stdout
    $stdout = fake = StringIO.new
    begin
      yield
    ensure
      $stdout = original_stdout
    end
    fake.string
  end

  describe "#tcp_scan" do
    it "sanitizes the input ports array (sorts, uniques, validates)" do
      # This test verifies the sanitization within tcp_scan.
      # Input: mixed valid and invalid ports, unsorted, with duplicates.
      # Expected: only valid ports, sorted, unique.
      output = ""
      results = {}
      output = capture_scanner_output do
        results = scanner.tcp_scan("test.com", [80, 22, 80, 0, 65536, 443, "invalid", nil], {})
      end
      # Check the "Targeting ports" log output
      expect(output).to include("Targeting ports: [22, 80, 443]")
      # Check the returned :scanned_ports in the result hash
      expect(results[:scanned_ports]).to eq([22, 80, 443])
    end

    it "returns expected open ports for 'example.com' based on simulation" do
      # Test with a specific set of ports for example.com
      # The simulation logic in HK::Net::Scanner for example.com opens [80, 443, 8080, 8081]
      # if they are in the input list.
      input_ports = [80, 443, 22, 8080, 9999, 8081]
      results = scanner.tcp_scan("example.com", input_ports, {})
      
      expect(results[:open_ports]).to match_array([80, 443, 8080, 8081])
      expect(results[:closed_ports]).to match_array([22, 9999])
      expect(results[:scanned_ports]).to match_array(input_ports.sort) # Should be all input ports, sorted
    end

    it "returns some simulated open ports for other targets" do
      # For non-"example.com" targets, the simulation is more random.
      # We can check if it returns an array and that scanned_ports matches input.
      input_ports = [80, 443, 22, 1234, 5678]
      results = scanner.tcp_scan("another.host.com", input_ports, {})
      
      expect(results[:open_ports]).to be_an(Array)
      # Ensure all input ports were considered "scanned"
      expect(results[:scanned_ports]).to match_array(input_ports.sort)
      # Ensure open_ports is a subset of scanned_ports
      expect(results[:open_ports] - results[:scanned_ports]).to be_empty
    end

    it "logs rate and timeout options if provided" do
      output = capture_scanner_output do
        scanner.tcp_scan("test.com", [80], { rate: 1000, timeout: 5 })
      end
      expect(output).to include("Rate limit specified: 1000 pps (simulation)")
      expect(output).to include("Timeout specified: 5s (simulation)")
    end
    
    it "includes original options in the result" do
      opts = { rate: 100, detail: true, some_other_option: "value" }
      results = scanner.tcp_scan("test.com", [80], opts)
      # The HK::Net::Scanner's tcp_scan method currently returns the passed 'options' hash
      # as part of its result.
      expect(results[:options]).to eq(opts)
    end
  end
end
