require 'spec_helper'
require 'hk/net/scanner'
require 'socket'
require 'json'
require 'tty-progressbar'
require 'yaml' # For stubbing YAML.safe_load_file

RSpec.describe HK::Net::Scanner do
  let(:scanner) { HK::Net::Scanner.new } # Initializes @udp_probes_data
  let(:target_host) { "udp-scan.hk.local" }
  let(:default_tcp_timeout) { 0.05 } # Shorter for TCP tests
  let(:default_udp_timeout) { HK::Net::Scanner::UDP_RESPONSE_TIMEOUT } # Use constant from SUT

  # --- Top-level before(:each) for general stubs ---
  before(:each) do
    # Default Addrinfo stub for TCP and UDP, can be overridden in specific tests
    allow(Addrinfo).to receive(:getaddrinfo)
      .with(target_host, nil, :INET, :STREAM) # For TCP
      .and_return([Addrinfo.tcp(target_host, 0)])
    allow(Addrinfo).to receive(:getaddrinfo)
      .with(target_host, nil, :INET, :DGRAM)  # For UDP
      .and_return([Addrinfo.udp(target_host, 0)])

    # Stub TCP constants for existing TCP tests (values from turn 156)
    stub_const("HK::Net::Scanner::BANNER_READ_TIMEOUT", 0.05)
    stub_const("HK::Net::Scanner::BANNER_READ_MAX_SIZE", 128)
    stub_const("HK::Net::Scanner::DEFAULT_TCP_PROBES", { # Renamed to avoid clash
      22 => { name: 'ssh', probe: nil },
      80 => { name: 'http', probe: "GET / HTTP/1.0\r\n\r\n" }
      # Add other TCP probes if other TCP tests rely on them
    })
    # UDP constants are part of the SUT, no need to stub them unless overriding for a specific test.
  end

  # --- TCP Scan Tests (condensed from turn 156 for brevity) ---
  describe "#tcp_scan" do
    it "identifies an open TCP port" do
      mock_socket = instance_double(Socket, close: nil)
      allow(Socket).to receive(:tcp).with(target_host, 80, connect_timeout: default_tcp_timeout).and_return(mock_socket)
      allow(mock_socket).to receive(:write_nonblock).and_return(1)
      allow(IO).to receive(:select).and_return(nil) # No banner
      results = scanner.tcp_scan(target_host, [80], { timeout: default_tcp_timeout })
      expect(results[:open_ports].first[:port]).to eq(80)
    end
  end

  # --- UDP Scan Tests ---
  describe "#udp_scan" do
    let(:mock_udp_socket) { instance_double(UDPSocket, close: nil) }
    # Sample UDP probes for stubbing YAML load
    let(:sample_udp_probes_content) do
      [
        { 'name' => 'dns_mock', 'port' => 53, 'probe' => '010203', # Simple hex
          'match' => { 'type' => 'regex', 'pattern' => 'MOCKDNS(.*)VERSION(.*)', 'version_capture_group' => 2 } }, # Captures second group
        { 'name' => 'snmp_mock', 'port' => 161, 'probe' => '040506',
          'match' => { 'type' => 'exact', 'pattern' => 'MOCKSNMP_RESPONSE' } },
        { 'name' => 'diag_echo', 'port' => 7, 'probe' => 'abcdef', # echo
          'match' => { 'type' => 'exact', 'pattern' => 'abcdef' } }
        # Port 12345 has no entry, will use null probe
        # Port 999 (for ECONNREFUSED test) has no entry
      ]
    end
    let(:mock_progress_bar) { instance_double(TTY::ProgressBar, advance: nil, finish: nil) }


    before(:each) do
      allow(YAML).to receive(:safe_load_file)
        .with(HK::Net::Scanner::UDP_PROBES_FILE, permitted_classes: [Symbol], aliases: true)
        .and_return(sample_udp_probes_content)

      # Critical: Ensure scanner instance in tests uses these stubbed probes
      # `let(:scanner)` is lazy-loaded, so it will be created with these stubs in place.

      # Default mock for UDPSocket.new. This will be used for all calls unless overridden in a specific context.
      # Individual tests will set more specific expectations on this mock or provide their own.
      allow(UDPSocket).to receive(:new).and_return(mock_udp_socket)
    end

    context "when scanning a single port" do
      it "identifies an open/responsive UDP port with a matching regex probe (DNS)" do
        dns_probe_binary = [sample_udp_probes_content.find { |p| p['port'] == 53 }['probe']].pack('H*')
        dns_response_text = "Data MOCKDNS_SERVICE_VERSION_1.2.3_MOREDATA" # Regex: MOCKDNS(.*)VERSION(.*) -> $2 = _1.2.3_MOREDATA

        # Ensure UDPSocket.new is called and returns our mock_udp_socket for this specific test
        expect(UDPSocket).to receive(:new).and_return(mock_udp_socket)
        expect(mock_udp_socket).to receive(:send).with(dns_probe_binary, 0, target_host, 53)
        expect(IO).to receive(:select).with([mock_udp_socket], nil, nil, default_udp_timeout).and_return([[mock_udp_socket], [], []])
        expect(mock_udp_socket).to receive(:recvfrom_nonblock).with(HK::Net::Scanner::UDP_PACKET_READ_SIZE).and_return([dns_response_text, "sender_info"])
        expect(mock_udp_socket).to receive(:close)

        results = scanner.udp_scan(target_host, [53], { timeout: default_udp_timeout, threads: 1, progress_bar: mock_progress_bar })

        expect(results[:open_ports].size).to eq(1)
        port_info = results[:open_ports].first
        expect(port_info[:port]).to eq(53)
        expect(port_info[:status]).to eq(:open_responsive)
        expect(port_info[:service]).to eq("dns_mock")
        expect(port_info[:version]).to eq("_1.2.3_MOREDATA")
        expect(port_info[:banner]).to include("MOCKDNS_SERVICE_VERSION_1.2.3_MOREDATA")
        expect(mock_progress_bar).to have_received(:advance).once
      end

      it "identifies an open/responsive UDP port with an exact match (SNMP)" do
        snmp_probe_binary = [sample_udp_probes_content.find { |p| p['port'] == 161 }['probe']].pack('H*')
        snmp_response_text = "MOCKSNMP_RESPONSE"

        expect(UDPSocket).to receive(:new).and_return(mock_udp_socket)
        expect(mock_udp_socket).to receive(:send).with(snmp_probe_binary, 0, target_host, 161)
        expect(IO).to receive(:select).with([mock_udp_socket], nil, nil, default_udp_timeout).and_return([[mock_udp_socket], [], []])
        expect(mock_udp_socket).to receive(:recvfrom_nonblock).with(HK::Net::Scanner::UDP_PACKET_READ_SIZE).and_return([snmp_response_text, "sender_info"])
        expect(mock_udp_socket).to receive(:close)

        results = scanner.udp_scan(target_host, [161], { timeout: default_udp_timeout, threads: 1, progress_bar: mock_progress_bar })
        port_info = results[:open_ports].first
        expect(port_info[:port]).to eq(161)
        expect(port_info[:service]).to eq("snmp_mock")
        expect(port_info[:banner]).to eq("MOCKSNMP_RESPONSE")
        expect(mock_progress_bar).to have_received(:advance).once
      end

      it "identifies an open port using a NULL probe if no specific probe is defined" do
        null_byte_probe = "\0"
        response_text = "Some generic response from 12345"

        expect(UDPSocket).to receive(:new).and_return(mock_udp_socket)
        expect(mock_udp_socket).to receive(:send).with(null_byte_probe, 0, target_host, 12345)
        expect(IO).to receive(:select).with([mock_udp_socket], nil, nil, default_udp_timeout).and_return([[mock_udp_socket], [], []])
        expect(mock_udp_socket).to receive(:recvfrom_nonblock).with(HK::Net::Scanner::UDP_PACKET_READ_SIZE).and_return([response_text, "sender_info"])
        expect(mock_udp_socket).to receive(:close)

        results = scanner.udp_scan(target_host, [12345], { timeout: default_udp_timeout, threads:1, progress_bar: mock_progress_bar })
        port_info = results[:open_ports].first
        expect(port_info[:port]).to eq(12345)
        expect(port_info[:service]).to eq("unknown")
        expect(port_info[:banner]).to eq(response_text)
        expect(mock_progress_bar).to have_received(:advance).once
      end

      it "marks a port as filtered if no response is received (timeout)" do
        null_byte_probe = "\0"
        expect(UDPSocket).to receive(:new).and_return(mock_udp_socket)
        expect(mock_udp_socket).to receive(:send).with(null_byte_probe, 0, target_host, 12345)
        expect(IO).to receive(:select).with([mock_udp_socket], nil, nil, default_udp_timeout).and_return(nil)
        expect(mock_udp_socket).to receive(:close)

        results = scanner.udp_scan(target_host, [12345], { timeout: default_udp_timeout, threads:1, progress_bar: mock_progress_bar })
        expect(results[:open_ports]).to be_empty
        expect(results[:filtered_ports]).to include(12345)
        expect(mock_progress_bar).to have_received(:advance).once
      end

      it "marks a port as closed on Errno::ECONNREFUSED" do
        null_byte_probe = "\0"
        # Port 999 is not in sample_udp_probes_content, so it uses null_byte_probe
        expect(UDPSocket).to receive(:new).and_return(mock_udp_socket)
        expect(mock_udp_socket).to receive(:send).with(null_byte_probe, 0, target_host, 999).and_raise(Errno::ECONNREFUSED)
        expect(mock_udp_socket).to receive(:close)

        results = scanner.udp_scan(target_host, [999], { timeout: default_udp_timeout, threads:1, progress_bar: mock_progress_bar })
        # _check_udp_port returns [:closed, { port: port, status: :closed }]
        # The main udp_scan method then puts this into :open_ports with status :closed.
        closed_port_info = results[:open_ports].find { |p| p[:port] == 999 }
        expect(closed_port_info).not_to be_nil
        expect(closed_port_info[:status]).to eq(:closed)
        expect(mock_progress_bar).to have_received(:advance).once
      end
    end

    context "general behavior" do
      it "handles host resolution failure for UDP scan" do
        allow(Addrinfo).to receive(:getaddrinfo).with("unknownudp.hk.local", nil, :INET, :DGRAM).and_raise(SocketError.new("UDP host resolve error"))
        # No UDPSocket.new, send, select, or recvfrom_nonblock should be called if host resolution fails early.
        expect(UDPSocket).not_to receive(:new)

        results = scanner.udp_scan("unknownudp.hk.local", [53], {timeout: default_udp_timeout, progress_bar: mock_progress_bar})
        expect(results[:error]).to include("Host resolution failed for UDP: SocketError: UDP host resolve error")
        expect(results[:open_ports]).to be_empty
        expect(mock_progress_bar).to have_received(:finish)
      end

      it "correctly uses default UDP ports if none are specified by user" do
        stub_const("HK::Net::Scanner::DEFAULT_UDP_PORTS", [53, 161]) # dns_mock, snmp_mock

        dns_probe_binary = [sample_udp_probes_content.find { |p| p['port'] == 53 }['probe']].pack('H*')
        dns_response_text = "MOCKDNS_DEFAULT_RESPONSE"
        snmp_probe_binary = [sample_udp_probes_content.find { |p| p['port'] == 161 }['probe']].pack('H*')

        socket_for_53 = instance_double(UDPSocket, :socket_for_53, send: nil, recvfrom_nonblock: [dns_response_text, "sender"], close: nil)
        socket_for_161 = instance_double(UDPSocket, :socket_for_161, send: nil, close: nil) # Will timeout

        expect(UDPSocket).to receive(:new).ordered.and_return(socket_for_53)
        expect(socket_for_53).to receive(:send).with(dns_probe_binary, 0, target_host, 53)
        expect(IO).to receive(:select).with([socket_for_53], nil, nil, default_udp_timeout).ordered.and_return([[socket_for_53], [], []])

        expect(UDPSocket).to receive(:new).ordered.and_return(socket_for_161)
        expect(socket_for_161).to receive(:send).with(snmp_probe_binary, 0, target_host, 161)
        expect(IO).to receive(:select).with([socket_for_161], nil, nil, default_udp_timeout).ordered.and_return(nil) # Timeout for 161

        results = scanner.udp_scan(target_host, [], { timeout: default_udp_timeout, threads:1, progress_bar: mock_progress_bar })

        expect(results[:open_ports].size).to eq(1)
        expect(results[:open_ports].first[:port]).to eq(53)
        expect(results[:open_ports].first[:service]).to eq("dns_mock")
        expect(results[:filtered_ports]).to include(161)
        expect(mock_progress_bar).to have_received(:advance).twice
        expect(mock_progress_bar).to have_received(:finish)
      end

      it "scans multiple ports using multiple threads (conceptual check via call counts and behavior)" do
        ports_to_scan = [53, 161, 12345] # dns_mock (open), snmp_mock (filtered), unknown (open)

        dns_probe_binary = [sample_udp_probes_content.find { |p| p['port'] == 53 }['probe']].pack('H*')
        dns_response_text = "MOCKDNS_MULTI_RESPONSE_V2"
        snmp_probe_binary = [sample_udp_probes_content.find { |p| p['port'] == 161 }['probe']].pack('H*')
        null_byte_probe = "\0"
        unknown_response_text = "Response from 12345 multi"

        # Since threads will interleave, we can't use `ordered` across all calls easily.
        # Instead, we'll allow UDPSocket.new to be called multiple times and configure behavior
        # for IO.select and recvfrom_nonblock based on the port using a block if possible,
        # or by having UDPSocket.new return distinct pre-configured mocks.

        # Let UDPSocket.new return a new mock each time to simulate different socket objects per thread/port.
        socket_dns = instance_double(UDPSocket, :socket_dns, send: nil, recvfrom_nonblock: [dns_response_text, "sender_dns"], close: nil)
        socket_snmp = instance_double(UDPSocket, :socket_snmp, send: nil, close: nil) # for timeout
        socket_unknown = instance_double(UDPSocket, :socket_unknown, send: nil, recvfrom_nonblock: [unknown_response_text, "sender_unknown"], close: nil)

        # Expect UDPSocket.new to be called for each port.
        # The order of these calls isn't strictly guaranteed due to threading, so don't use .ordered here.
        expect(UDPSocket).to receive(:new).and_return(socket_dns, socket_snmp, socket_unknown)

        # Configure behavior for each socket mock
        # DNS (port 53)
        expect(socket_dns).to receive(:send).with(dns_probe_binary, 0, target_host, 53)
        expect(IO).to receive(:select).with([socket_dns], nil, nil, default_udp_timeout).and_return([[socket_dns],[],[]])

        # SNMP (port 161)
        expect(socket_snmp).to receive(:send).with(snmp_probe_binary, 0, target_host, 161)
        expect(IO).to receive(:select).with([socket_snmp], nil, nil, default_udp_timeout).and_return(nil) # Timeout

        # Unknown (port 12345)
        expect(socket_unknown).to receive(:send).with(null_byte_probe, 0, target_host, 12345)
        expect(IO).to receive(:select).with([socket_unknown], nil, nil, default_udp_timeout).and_return([[socket_unknown],[],[]])

        results = scanner.udp_scan(target_host, ports_to_scan, { timeout: default_udp_timeout, threads: 3, progress_bar: mock_progress_bar })

        expect(results[:open_ports].size).to eq(2)
        expect(results[:open_ports].map { |p| p[:port] }).to contain_exactly(53, 12345)
        expect(results[:filtered_ports]).to contain_exactly(161)

        dns_result = results[:open_ports].find { |p| p[:port] == 53 }
        expect(dns_result[:service]).to eq("dns_mock")
        expect(dns_result[:version]).to eq("V2") # From "MOCKDNS(.*)VERSION(.*)" capturing "V2"

        unknown_result = results[:open_ports].find { |p| p[:port] == 12345 }
        expect(unknown_result[:service]).to eq("unknown")
        expect(unknown_result[:banner]).to eq(unknown_response_text)

        expect(mock_progress_bar).to have_received(:advance).exactly(ports_to_scan.size).times
        expect(mock_progress_bar).to have_received(:finish)
      end
    end
  end
end
end
