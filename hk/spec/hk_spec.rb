require 'spec_helper'

RSpec.describe HK do
  it "has a version number" do
    expect(HK::VERSION).not_to be nil
  end

  describe ".scan (direct call)" do
    it "responds to .scan" do
      expect(HK).to respond_to(:scan)
    end

    it "executes without error and returns a Scanner object" do
      # Suppress stdout for this test
      allow($stdout).to receive(:puts)
      expect { HK.scan("example.com") }.not_to raise_error
      expect(HK.scan("example.com")).to be_an_instance_of(HK::Scanner)
    end
  end

  describe ".crawl (direct call)" do
    it "responds to .crawl" do
      expect(HK).to respond_to(:crawl)
    end

    it "executes without error" do
      allow($stdout).to receive(:puts)
      expect { HK.crawl("example.com") }.not_to raise_error
    end
  end

  describe ".scan (chainable calls)" do
    let(:scanner) { HK.scan("example.com") }

    before do
      allow($stdout).to receive(:puts) # Suppress messages from placeholder methods
    end

    it "returns a Scanner object that supports chaining" do
      expect(scanner).to be_an_instance_of(HK::Scanner)
      expect(scanner.filter_open_ports).to eq(scanner)
      expect(scanner.identify_services.check_vulnerabilities).to eq(scanner)
    end

    it "allows chaining multiple methods" do
      expect {
        scanner.filter_open_ports.identify_services.check_vulnerabilities.generate_report
      }.not_to raise_error
    end
  end

  describe ".scan (block syntax)" do
    it "yields a Scanner object to the block" do
      allow($stdout).to receive(:puts)
      yielded_scanner = nil
      returned_scanner = HK.scan("example.com") do |s|
        yielded_scanner = s
        expect(s).to be_an_instance_of(HK::Scanner)
        s.check_vulnerabilities # Call a method on the scanner
      end
      expect(yielded_scanner).to be_an_instance_of(HK::Scanner)
      expect(returned_scanner).to eq(yielded_scanner) # Check if HK.scan returns the scanner
    end
  end

  describe "HK::Net::Scanner (modular usage)" do
    let(:net_scanner) { HK::Net::Scanner.new }

    before do
      allow($stdout).to receive(:puts)
    end

    it "can be instantiated" do
      expect(net_scanner).to be_an_instance_of(HK::Net::Scanner)
    end

    it "responds to tcp_scan and executes" do
      expect(net_scanner).to respond_to(:tcp_scan)
      expect {
        net_scanner.tcp_scan("example.com", [80, 443])
      }.not_to raise_error
      expect(net_scanner.tcp_scan("example.com", [80, 443])).to eq({ target: "example.com", open_ports: [] })
    end
  end

  describe ".security_scan (DSL syntax)" do
    it "executes without error when called with a block" do
      allow($stdout).to receive(:puts)
      expect {
        HK.security_scan do
          # test DSL block
        end
      }.not_to raise_error
    end

    it "executes without error when called without a block" do
      allow($stdout).to receive(:puts)
      expect { HK.security_scan }.not_to raise_error
    end
  end

  describe ".interactive (interactive mode)" do
    it "executes without error when called with a block" do
      allow($stdout).to receive(:puts)
      expect {
        HK.interactive do
          # test interactive block
        end
      }.not_to raise_error
    end

    it "executes without error when called without a block" do
      allow($stdout).to receive(:puts)
      expect { HK.interactive }.not_to raise_error
    end
  end
end
