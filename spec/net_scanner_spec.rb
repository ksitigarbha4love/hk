require 'spec_helper'
require 'hk/net/scanner' 
require 'socket'
require 'json' 
require 'tty-progressbar' 

RSpec.describe HK::Net::Scanner do
  let(:scanner) { HK::Net::Scanner.new }
  let(:target_host) { "scannable.hk.local" }
  let(:connect_timeout) { 0.05 } 
  
  before(:each) do
    allow(Addrinfo).to receive(:getaddrinfo).with(any_args).and_return([Addrinfo.tcp(target_host, 0)])
    stub_const("HK::Net::Scanner::BANNER_READ_TIMEOUT", 0.05)
    stub_const("HK::Net::Scanner::BANNER_READ_MAX_SIZE", 256) 
    stub_const("HK::Net::Scanner::DEFAULT_PROBES", {
      21 => { name: 'ftp', probe: "SYST\r\nQUIT\r\n" },
      22 => { name: 'ssh', probe: nil },
      80 => { name: 'http', probe: "HEAD / HTTP/1.0\r\n\r\n" }, # Using HEAD as per SUT
      443 => { name: 'https', probe: nil },
      3306 => { name: 'mysql', probe: nil },
      5432 => { name: 'postgres', probe: nil },
      6379 => { name: 'redis', probe: "PING\r\n" },
      9200 => { name: 'elasticsearch', probe: "GET / HTTP/1.0\r\n\r\n" }
    })
  end

  describe "#tcp_scan" do
    context "when scanning with concurrency" do
      let(:ports_to_scan) { [22, 80, 3306, 6379, 9200, 12345] } 
      let(:mock_socket) { instance_double(Socket, close: nil) }

      def setup_port_mocks(port_behaviors)
        port_behaviors.each do |port, behavior|
          case behavior[:status]
          when :open
            allow(Socket).to receive(:tcp).with(target_host, port, connect_timeout: connect_timeout).and_return(mock_socket)
            probe_config = HK::Net::Scanner::DEFAULT_PROBES[port]
            # Mock write_nonblock only if probe is defined
            allow(mock_socket).to receive(:write_nonblock).with(probe_config[:probe]) if probe_config && probe_config[:probe]
            
            reads_banner = probe_config # True if probe_config exists (even if probe is nil for SSH)
            
            if reads_banner
                allow(IO).to receive(:select).with([mock_socket], nil, nil, HK::Net::Scanner::BANNER_READ_TIMEOUT)
                                         .and_return(behavior[:banner] ? [[mock_socket], [], []] : nil)
                if behavior[:banner]
                    allow(mock_socket).to receive(:read_nonblock).with(HK::Net::Scanner::BANNER_READ_MAX_SIZE).and_return(behavior[:banner])
                end
            end
          when :closed
            allow(Socket).to receive(:tcp).with(target_host, port, connect_timeout: connect_timeout).and_raise(Errno::ECONNREFUSED)
          when :filtered
            allow(Socket).to receive(:tcp).with(target_host, port, connect_timeout: connect_timeout).and_raise(Timeout::Error)
          end
        end
      end

      let(:port_behaviors_set1) {
        {
          22 => { status: :open, banner: "SSH-2.0-TestSSH" },    
          80 => { status: :open, banner: "HTTP/1.1 200 OK\r\nServer: TestWeb/1.0\r\n" }, 
          3306 => { status: :open, banner: nil },             
          6379 => { status: :closed },                         
          9200 => { status: :filtered },                       
          12345 => { status: :closed }                         
        }
      }
      
      it "produces consistent results between single and multiple threads" do
        setup_port_mocks(port_behaviors_set1)
        
        results_single_thread = scanner.tcp_scan(target_host, ports_to_scan, { timeout: connect_timeout, threads: 1 })
        sorted_open_single = results_single_thread[:open_ports].sort_by { |p| p[:port] }
        
        setup_port_mocks(port_behaviors_set1) 
        results_multi_thread = scanner.tcp_scan(target_host, ports_to_scan, { timeout: connect_timeout, threads: 5 })
        sorted_open_multi = results_multi_thread[:open_ports].sort_by { |p| p[:port] }

        expect(sorted_open_multi.map{|p| p.reject{|k,_| k==:banner}}).to eq(sorted_open_single.map{|p| p.reject{|k,_| k==:banner}}) # Banners can be verbose
        expect(results_multi_thread[:closed_ports].sort).to eq(results_single_thread[:closed_ports].sort)
        expect(results_multi_thread[:filtered_ports].sort).to eq(results_single_thread[:filtered_ports].sort)
      end

      it "interacts with the progress bar correctly" do
        mock_progress_bar = instance_double(TTY::ProgressBar, advance: nil, finish: nil)
        setup_port_mocks(port_behaviors_set1) 

        expect(mock_progress_bar).to receive(:advance).exactly(ports_to_scan.size).times
        expect(mock_progress_bar).to receive(:finish).once

        scanner.tcp_scan(target_host, ports_to_scan, { timeout: connect_timeout, threads: 3, progress_bar: mock_progress_bar })
      end
      
      # Conceptual test for thread error handling
      it "handles exceptions within threads gracefully (conceptual)" do
        allow(Socket).to receive(:tcp).with(target_host, 22, connect_timeout: connect_timeout).and_return(mock_socket)
        allow(mock_socket).to receive(:write_nonblock).and_raise(StandardError.new("Fake thread error on write")) # Error during banner grab
        allow(Socket).to receive(:tcp).with(target_host, 80, connect_timeout: connect_timeout).and_return(mock_socket) # Port 80 is fine
        allow(IO).to receive(:select).and_return(nil) # No banner for port 80

        results = scanner.tcp_scan(target_host, [22, 80], { timeout: connect_timeout, threads: 2 })
        
        # Port 22 might be filtered or open with no banner/service depending on exact error handling in _grab_banner
        # Port 80 should be open
        expect(results[:open_ports].any? {|p| p[:port] == 80}).to be true
        # Check if the error on port 22 was handled (e.g., not crashing, maybe port 22 is filtered or has no banner)
        # The current _grab_banner returns nil on StandardError, so it would appear as open with no banner.
        port22_info = results[:open_ports].find {|p| p[:port] == 22}
        expect(port22_info).not_to be_nil # It was opened by _check_port
        expect(port22_info[:banner]).to be_nil
        expect(port22_info[:service]).to eq("ssh") # Default from probe config
      end
    end 
  end 

  describe "#_parse_banner" do
    it "parses Redis PONG response" do
      probe_config = HK::Net::Scanner::DEFAULT_PROBES[6379]
      info = scanner.send(:_parse_banner, "+PONG\r\n", 6379, probe_config) 
      expect(info[:service_name]).to eq("redis")
      expect(info[:version]).to be_nil
    end

    it "parses Elasticsearch JSON banner for version" do
      probe_config = HK::Net::Scanner::DEFAULT_PROBES[9200]
      es_banner = '{"name":"es-node-1","cluster_name":"elasticsearch","version":{"number":"7.10.2", "build_flavor":"default"}}'
      info = scanner.send(:_parse_banner, es_banner, 9200, probe_config)
      expect(info[:service_name]).to eq("elasticsearch")
      expect(info[:version]).to eq("Elasticsearch 7.10.2")
    end
    
    it "parses older Elasticsearch tagline" do
        probe_config = HK::Net::Scanner::DEFAULT_PROBES[9200]
        es_banner_old = '{"tagline" : "You Know, for Search"}'
        info = scanner.send(:_parse_banner, es_banner_old, 9200, probe_config)
        expect(info[:service_name]).to eq("elasticsearch")
        expect(info[:version]).to eq("Elasticsearch (generic)")
    end

    it "identifies MySQL by port on successful connect (empty banner)" do
      probe_config = HK::Net::Scanner::DEFAULT_PROBES[3306]
      info = scanner.send(:_parse_banner, "", 3306, probe_config) 
      expect(info[:service_name]).to eq("mysql")
      expect(info[:version]).to be_nil
    end
    
    it "identifies PostgreSQL by port on successful connect (empty banner)" do
      probe_config = HK::Net::Scanner::DEFAULT_PROBES[5432] 
      info = scanner.send(:_parse_banner, "", 5432, probe_config)
      expect(info[:service_name]).to eq("postgres") 
      expect(info[:version]).to be_nil
    end

    it "correctly parses updated FTP banner regex for vsFTPd" do # Be more specific
        probe_config = HK::Net::Scanner::DEFAULT_PROBES[21]
        ftp_banner = "220 vsFTPd 3.0.5\r\n"
        info = scanner.send(:_parse_banner, ftp_banner, 21, probe_config)
        expect(info[:service_name]).to eq("ftp")
        expect(info[:version]).to eq("3.0.5")
    end
    
    it "returns default service name if banner is unparsable but service known by port" do
        probe_config = HK::Net::Scanner::DEFAULT_PROBES[22] # SSH
        unclear_banner = "Some cryptic welcome message\r\n"
        info = scanner.send(:_parse_banner, unclear_banner, 22, probe_config)
        expect(info[:service_name]).to eq("ssh") 
        expect(info[:version]).to be_nil
    end
    
    it "returns 'unknown' for unknown port with unparsable banner" do
        # For this, probe_config would effectively be {name: 'unknown', probe: nil}
        # if port is not in DEFAULT_PROBES and not a special case like 443.
        # Simulate this by passing a generic probe_config.
        generic_probe_config = { name: 'unknown', probe: nil }
        info = scanner.send(:_parse_banner, "Unrecognized Banner Text", 12345, generic_probe_config)
        expect(info[:service_name]).to eq('unknown')
        expect(info[:version]).to be_nil
    end
    
    it "returns service name for known port even if banner is empty and probe was nil" do
        probe_config = HK::Net::Scanner::DEFAULT_PROBES[22] # SSH, probe: nil
        info = scanner.send(:_parse_banner, "", 22, probe_config)
        expect(info[:service_name]).to eq("ssh")
        expect(info[:version]).to be_nil
    end
  end
end
