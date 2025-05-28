require 'spec_helper'
require 'hk/net/scanner' 
require 'socket' # Required for SocketError, Addrinfo etc.

RSpec.describe HK::Net::Scanner do
  let(:scanner) { HK::Net::Scanner.new }
  let(:target_host) { "testhost.hk.local" } 
  let(:connect_timeout) { 0.1 } 
  # banner_timeout is not directly used as a parameter in the current HK::Net::Scanner methods
  # but BANNER_READ_TIMEOUT constant is used internally.
  
  before(:each) do
    allow(Addrinfo).to receive(:getaddrinfo).with(target_host, nil, :INET, :STREAM)
      .and_return([Addrinfo.tcp(target_host, 0)]) 
    
    stub_const("HK::Net::Scanner::BANNER_READ_TIMEOUT", 0.05)
    stub_const("HK::Net::Scanner::BANNER_READ_MAX_SIZE", 128) 
    stub_const("HK::Net::Scanner::DEFAULT_PROBES", {
      22 => { name: 'ssh', probe: nil },
      80 => { name: 'http', probe: "GET / HTTP/1.0\r\n\r\n" }, # Test uses GET
      21 => { name: 'ftp', probe: "SYST\r\nQUIT\r\n" }
    })
  end

  describe "#tcp_scan (Connect Scan Logic - via _check_port)" do
    it "identifies an open port" do
      mock_socket = instance_double(Socket)
      allow(Socket).to receive(:tcp).with(target_host, 80, connect_timeout: connect_timeout).and_return(mock_socket)
      allow(mock_socket).to receive(:close)
      # For banner grabbing on port 80 (http probe)
      # Simulate probe write and then no banner data
      allow(mock_socket).to receive(:write_nonblock).with(HK::Net::Scanner::DEFAULT_PROBES[80][:probe]).and_return(HK::Net::Scanner::DEFAULT_PROBES[80][:probe].length)
      allow(IO).to receive(:select).with([mock_socket], nil, nil, HK::Net::Scanner::BANNER_READ_TIMEOUT).and_return(nil) 

      results = scanner.tcp_scan(target_host, [80], { timeout: connect_timeout })
      expect(results[:open_ports].first[:port]).to eq(80)
      expect(results[:open_ports].first[:status]).to eq(:open)
      expect(results[:open_ports].first[:service]).to eq("http") # From probe config
      expect(results[:open_ports].first[:banner]).to be_nil # As IO.select returned nil
    end

    it "identifies a closed port (Connection Refused)" do
      allow(Socket).to receive(:tcp).with(target_host, 22, connect_timeout: connect_timeout).and_raise(Errno::ECONNREFUSED)
      results = scanner.tcp_scan(target_host, [22], { timeout: connect_timeout })
      expect(results[:closed_ports]).to include(22)
    end

    it "identifies a filtered port (Timeout)" do
      allow(Socket).to receive(:tcp).with(target_host, 443, connect_timeout: connect_timeout).and_raise(Timeout::Error)
      results = scanner.tcp_scan(target_host, [443], { timeout: connect_timeout })
      expect(results[:filtered_ports]).to include(443)
    end
    
    it "handles host resolution failure gracefully" do
        allow(Addrinfo).to receive(:getaddrinfo).with("unknownhost.hk.local", nil, :INET, :STREAM).and_raise(SocketError.new("getaddrinfo: name or service not known"))
        results = scanner.tcp_scan("unknownhost.hk.local", [80], {timeout: connect_timeout})
        expect(results[:error]).to match(/Host resolution failed: SocketError: getaddrinfo: name or service not known/)
        expect(results[:open_ports]).to be_empty
        expect(results[:closed_ports]).to be_empty
        expect(results[:filtered_ports]).to be_empty
    end
  end

  describe "Service Detection (_grab_banner and _parse_banner via tcp_scan)" do
    let(:mock_open_socket) { instance_double(Socket, close: nil) }

    # In these tests, we assume _check_port would return :open, so we mock Socket.tcp directly.
    # The `_check_port` method itself is tested by the "Connect Scan Logic" describe block.

    it "detects SSH service from banner" do
      ssh_banner = "SSH-2.0-OpenSSH_8.2p1 Ubuntu-4ubuntu0.5\r\n"
      allow(Socket).to receive(:tcp).with(target_host, 22, connect_timeout: connect_timeout).and_return(mock_open_socket)
      # SSH sends banner on connect, DEFAULT_PROBES[22][:probe] is nil.
      # So, no write_nonblock call is expected for SSH probe nil.
      allow(IO).to receive(:select).with([mock_open_socket], nil, nil, HK::Net::Scanner::BANNER_READ_TIMEOUT).and_return([[mock_open_socket], [], []])
      allow(mock_open_socket).to receive(:read_nonblock).with(HK::Net::Scanner::BANNER_READ_MAX_SIZE).and_return(ssh_banner)
      
      results = scanner.tcp_scan(target_host, [22], { timeout: connect_timeout })
      port_info = results[:open_ports].first
      expect(port_info[:port]).to eq(22)
      expect(port_info[:service]).to eq("ssh")
      expect(port_info[:version]).to eq("OpenSSH_8.2p1 Ubuntu-4ubuntu0.5")
      expect(port_info[:banner]).to eq(ssh_banner.strip.gsub(/[\r\n]+/, ' '))
    end

    it "detects HTTP service and version from Server header" do
      http_banner = "HTTP/1.1 200 OK\r\nServer: Apache/2.4.52 (Ubuntu)\r\nContent-Length: 0\r\n\r\n"
      allow(Socket).to receive(:tcp).with(target_host, 80, connect_timeout: connect_timeout).and_return(mock_open_socket)
      allow(mock_open_socket).to receive(:write_nonblock).with(HK::Net::Scanner::DEFAULT_PROBES[80][:probe]).and_return(HK::Net::Scanner::DEFAULT_PROBES[80][:probe].length)
      allow(IO).to receive(:select).with([mock_open_socket], nil, nil, HK::Net::Scanner::BANNER_READ_TIMEOUT).and_return([[mock_open_socket], [], []])
      allow(mock_open_socket).to receive(:read_nonblock).with(HK::Net::Scanner::BANNER_READ_MAX_SIZE).and_return(http_banner)

      results = scanner.tcp_scan(target_host, [80], { timeout: connect_timeout })
      port_info = results[:open_ports].first
      expect(port_info[:port]).to eq(80)
      expect(port_info[:service]).to eq("http")
      expect(port_info[:version]).to eq("Apache/2.4.52 (Ubuntu)")
    end

    it "handles banner read timeout gracefully" do
      allow(Socket).to receive(:tcp).with(target_host, 80, connect_timeout: connect_timeout).and_return(mock_open_socket)
      allow(mock_open_socket).to receive(:write_nonblock) # Probe sent
      allow(IO).to receive(:select).with([mock_open_socket], nil, nil, HK::Net::Scanner::BANNER_READ_TIMEOUT).and_return(nil) # Simulate select timeout

      results = scanner.tcp_scan(target_host, [80], { timeout: connect_timeout })
      port_info = results[:open_ports].first
      expect(port_info[:service]).to eq("http") # Default name from probe config
      expect(port_info[:version]).to be_nil
      expect(port_info[:banner]).to be_nil
    end
    
    it "marks service as 'https' for port 443 if TCP connect is open (basic check)" do
        allow(Socket).to receive(:tcp).with(target_host, 443, connect_timeout: connect_timeout).and_return(mock_open_socket)
        # DEFAULT_PROBES for 443 is nil, so _grab_banner is not called.
        # The special logic in tcp_scan for port 443 should mark service as 'https'.
        # The `_check_port` method (mocked by `allow(Socket).to receive(:tcp).and_return(mock_open_socket)`) effectively returns :open.

        results = scanner.tcp_scan(target_host, [443], { timeout: connect_timeout })
        port_info = results[:open_ports].first
        expect(port_info[:port]).to eq(443)
        expect(port_info[:service]).to eq("https") 
        expect(port_info[:version]).to be_nil
        expect(port_info[:banner]).to be_nil
    end
  end
end
