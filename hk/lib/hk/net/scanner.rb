require 'socket'
require 'timeout'
require 'thread'
require 'json'
require 'yaml' # For udp_probes.yml

module HK
  module Net
    class Scanner
      # --- TCP Related Constants and Methods ---
      DEFAULT_TCP_PROBES = { # Renamed from DEFAULT_PROBES to avoid conflict
        21 => { name: 'ftp', probe: "SYST\r\nQUIT\r\n" },
        22 => { name: 'ssh', probe: nil },
        23 => { name: 'telnet', probe: "\r\n\r\n" },
        # ... (other TCP probes from turn 162) ...
        25 => { name: 'smtp', probe: "EHLO test.com\r\nQUIT\r\n" },
        53 => { name: 'dns', probe: nil }, # TCP DNS (zone transfers)
        80 => { name: 'http', probe: "HEAD / HTTP/1.0\r\n\r\n" },
        110 => { name: 'pop3', probe: "CAPA\r\nQUIT\r\n" },
        143 => { name: 'imap', probe: "CAPABILITY\r\nLOGOUT\r\n" },
        389 => { name: 'ldap', probe: nil },
        443 => { name: 'https', probe: nil },
        445 => { name: 'smb', probe: nil },
        3306 => { name: 'mysql', probe: nil },
        3389 => { name: 'rdp', probe: nil },
        5432 => { name: 'postgres', probe: nil },
        5900 => { name: 'vnc', probe: nil },
        5985 => { name: 'winrm-http', probe: "GET /wsman HTTP/1.1\r\n\r\n" },
        5986 => { name: 'winrm-https', probe: nil },
        6379 => { name: 'redis', probe: "PING\r\n" },
        9200 => { name: 'elasticsearch', probe: "GET / HTTP/1.0\r\n\r\n" },
        27017 => { name: 'mongodb', probe: nil }
      }
      BANNER_READ_TIMEOUT = 2.0
      BANNER_READ_MAX_SIZE = 2048

      # --- UDP Related Constants and Methods ---
      UDP_PROBES_FILE = File.expand_path('net/udp_probes.yml', __dir__)
      DEFAULT_UDP_PORTS = [53, 123, 161, 7, 19] # Example default UDP ports to scan
      UDP_RESPONSE_TIMEOUT = 2.0 # Timeout for waiting for a UDP response
      UDP_PACKET_READ_SIZE = 1024


      def initialize(options = {}) # options is not used in current initialize
        if defined?(TTY::Color)
          @pastel = TTY::Color
        else
          @pastel = Object.new
          def @pastel.method_missing(*args, &block); args.first; end
          def @pastel.respond_to_missing?(method_name, include_private = false); true; end
        end
        @udp_probes_data = _load_udp_probes # Load UDP probes on init
      end

      # --- TCP Scan Methods (from turn 162) ---
      def tcp_scan(target_host, ports_array, options = {})
        connect_timeout = options.fetch(:timeout, 1.0).to_f
        num_threads = options.fetch(:threads, 10).to_i.clamp(1, 100)
        progress_bar = options[:progress_bar]
        open_ports_details = []; closed_ports = []; filtered_ports = []; results_mutex = Mutex.new; host_error = nil
        begin Addrinfo.getaddrinfo(target_host, nil, :INET, :STREAM); rescue SocketError => e; host_error = "Host resolution failed: #{e.message}"; progress_bar&.finish; return { target: target_host, open_ports: [], closed_ports: [], filtered_ports: [], error: host_error, options: options }; end
        ports_queue = Queue.new; ports_array.each { |port| ports_queue.push(port) }
        threads = []; num_threads.times do; threads << Thread.new do; while !ports_queue.empty? ; port_to_check = nil; begin port_to_check = ports_queue.pop(true); rescue ThreadError; break; end; next unless port_to_check; status = _check_tcp_port(target_host, port_to_check, connect_timeout); port_detail_to_add = nil; category_array = nil; case status; when :open; port_details = { port: port_to_check, status: :open, service: "unknown", version: nil, banner: nil }; probe_config = DEFAULT_TCP_PROBES[port_to_check] || (port_to_check == 8080 || port_to_check == 8000 ? DEFAULT_TCP_PROBES[80] : nil) || (port_to_check == 9201 || port_to_check == 9300 ? DEFAULT_TCP_PROBES[9200] : nil); if probe_config; banner = _grab_tcp_banner(target_host, port_to_check, connect_timeout, probe_config); if banner; port_details[:banner] = banner.strip.gsub(/[\r\n]+/, ' '); service_info = _parse_tcp_banner(banner, port_to_check, probe_config); port_details[:service] = service_info[:service_name] if service_info[:service_name]; port_details[:version] = service_info[:version] if service_info[:version]; elsif probe_config[:name] && probe_config[:probe].nil?; port_details[:service] = probe_config[:name]; end; elsif port_to_check == 443; port_details[:service] = "https"; end; port_detail_to_add = port_details; category_array = open_ports_details; when :closed; port_detail_to_add = port_to_check; category_array = closed_ports; when :filtered, :unreachable_host; port_detail_to_add = port_to_check; category_array = filtered_ports; end; results_mutex.synchronize { category_array << port_detail_to_add if port_detail_to_add && category_array; progress_bar&.advance; }; end; end; end; threads.each(&:join); progress_bar&.finish
        { target: target_host, open_ports: open_ports_details.sort_by { |p_info| p_info[:port] }, closed_ports: closed_ports.sort, filtered_ports: filtered_ports.sort, options: options, error: host_error }
      end

      private def _check_tcp_port(host, port, timeout_seconds) # Renamed from _check_port
        begin; Timeout.timeout(timeout_seconds) do; sock = Socket.tcp(host, port, connect_timeout: timeout_seconds); sock.close if sock; return :open; end; rescue Timeout::Error; return :filtered; rescue Errno::ECONNREFUSED; return :closed; rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL; return :filtered; rescue SocketError; return :filtered; rescue SystemCallError; return :filtered; end
      end
      private def _grab_tcp_banner(host, port, connect_timeout, probe_config) # Renamed from _grab_banner
        begin; Timeout.timeout(connect_timeout + BANNER_READ_TIMEOUT) do; sock = Socket.tcp(host, port, connect_timeout: connect_timeout); if sock; begin; if probe_config[:probe]; sock.write_nonblock(probe_config[:probe]); end; if IO.select([sock], nil, nil, BANNER_READ_TIMEOUT); return sock.read_nonblock(BANNER_READ_MAX_SIZE); else; return nil; end; rescue IO::WaitWritable; return nil; rescue IO::WaitReadable; return nil; rescue EOFError; return nil; ensure; sock.close; end; end; end; rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET, SystemCallError, SocketError; return nil; end; nil
      end
      private def _parse_tcp_banner(banner_string, port, probe_config) # Renamed from _parse_banner
        service_name = probe_config[:name]; version = nil; banner_s = banner_string.to_s.strip; return { service_name: service_name, version: nil } if banner_s.empty? && service_name != 'unknown' && service_name != 'https'; return { service_name: "unknown", version: nil } if banner_s.empty?; case service_name; when 'http', 'winrm-http', 'elasticsearch'; if banner_s =~ /Server: (.*?)(?:\r\n|$)/i; version = $1.strip; elsif banner_s =~ /HTTP\/\d\.\d \d{3}.*?\r\n.*?Server: (.*?)(?:\r\n|$)/im; version = $1.strip; end; if service_name == 'elasticsearch' && version.nil?; begin; json_banner = JSON.parse(banner_s[/({.*})/, 1] || banner_s); if json_banner['version'] && json_banner['version']['number']; version = "Elasticsearch #{json_banner['version']['number']}"; service_name = 'elasticsearch'; elsif json_banner['tagline'] == "You Know, for Search"; version = "Elasticsearch (generic)"; service_name = 'elasticsearch'; end; rescue JSON::ParserError; end; end; when 'ssh'; if banner_s =~ /SSH-\d\.\d-(.*?)(?:[ \r\n]|$)/; version = $1.strip; end; when 'ftp'; if banner_s =~ /^220[- ](?:ProFTPD|Pure-FTPd|vsFTPd|FileZilla Server|Microsoft FTP Service) ?(v?[\d\w\.\-]+)/i; version_candidate = $1.strip; version = version_candidate if version_candidate && !version_candidate.empty? && version_candidate.length < 60; elsif banner_s =~ /^220 (.*?) FTP server ready/i; version_candidate = $1.strip; version = version_candidate if version_candidate && !version_candidate.empty? && version_candidate.length < 50; end; when 'redis'; if banner_s.include?("+PONG"); service_name = 'redis'; end; end; { service_name: service_name, version: version }
      end

      # --- UDP Scan Methods (New) ---
      public
      def udp_scan(target_host, ports_array, options = {})
        scan_timeout = options.fetch(:timeout, UDP_RESPONSE_TIMEOUT).to_f # Overall timeout for each port's send/recv
        progress_bar = options[:progress_bar]

        open_or_responsive_ports = [] # Ports that gave some response (might be open or just responsive)
        filtered_ports = [] # Ports that timed out (no response)
        results_mutex = Mutex.new
        host_error = nil

        begin
            Addrinfo.getaddrinfo(target_host, nil, :INET, :DGRAM) # Check for DGRAM for UDP
        rescue SocketError => e
            host_error = "Host resolution failed for UDP: #{e.message}"
            progress_bar&.finish
            return { target: target_host, open_ports: [], filtered_ports: [], error: host_error, options: options }
        end

        # Use default UDP ports if none are specified by user in CLI (CLI will handle this)
        ports_to_scan = ports_array.empty? ? DEFAULT_UDP_PORTS : ports_array

        ports_queue = Queue.new
        ports_to_scan.each { |port| ports_queue.push(port) }

        num_threads = options.fetch(:threads, 5).to_i.clamp(1, 50) # UDP scanning can be slower, fewer default threads

        threads = []
        num_threads.times do
          threads << Thread.new do
            while !ports_queue.empty?
              port_to_check = nil
              begin; port_to_check = ports_queue.pop(true); rescue ThreadError; break; end
              next unless port_to_check

              probe_entry = @udp_probes_data.find { |p| p['port'] == port_to_check }
              status, details = _check_udp_port(target_host, port_to_check, probe_entry, scan_timeout)

              results_mutex.synchronize do
                case status
                when :open_responsive # Matched probe or got any response
                  open_or_responsive_ports << details
                when :filtered # Timeout
                  filtered_ports << port_to_check
                # UDP rarely gives :closed (ICMP Port Unreachable), usually just times out.
                end
                progress_bar&.advance
              end
            end
          end
        end
        threads.each(&:join)
        progress_bar&.finish

        {
          target: target_host,
          open_ports: open_or_responsive_ports.sort_by { |p_info| p_info[:port] }, # "open" here means responsive/matched
          filtered_ports: filtered_ports.sort,
          options: options,
          error: host_error
        }
      end

      private

      def _load_udp_probes
        return [] unless File.exist?(UDP_PROBES_FILE)
        begin
          YAML.safe_load_file(UDP_PROBES_FILE, permitted_classes: [Symbol], aliases: true) || []
        rescue Psych::Exception
          # puts @pastel.red("Error loading UDP probes file: #{UDP_PROBES_FILE}")
          []
        end
      end

      def _hex_decode(hex_string)
        [hex_string].pack('H*')
      end

      def _check_udp_port(host, port, probe_entry, timeout_seconds)
        response_data = nil
        sock = UDPSocket.new(Socket.const_defined?(:AF_INET6) && host.include?(':') ? Socket::AF_INET6 : Socket::AF_INET)

        begin
          # Connect helps with ICMP errors on some OS, but not required for send/recv
          # sock.connect(host, port) # Not using connect for general UDP probe

          probe_payload = probe_entry ? _hex_decode(probe_entry['probe']) : nil

          if probe_payload && !probe_payload.empty?
            sock.send(probe_payload, 0, host, port)
          else
            # If no probe, send a minimal UDP packet (e.g. empty or just a newline)
            # This is to elicit a response from services like echo, or an ICMP error
            sock.send("\0", 0, host, port) # Sending a null byte
          end

          # Wait for response using IO.select for timeout handling
          if IO.select([sock], nil, nil, timeout_seconds)
            # Data available, attempt to read
            response_data, _sender_addrinfo = sock.recvfrom_nonblock(UDP_PACKET_READ_SIZE)
          else
            # Timeout, no data received
            return :filtered, { port: port, status: :filtered, service: probe_entry ? probe_entry['name'] : 'unknown', banner: "Timeout" }
          end
        rescue IO::WaitReadable # recvfrom_nonblock would block
          # This means select said readable, but recvfrom_nonblock would block.
          # Usually indicates no data actually arrived or a race. Treat as timeout/filtered.
          return :filtered, { port: port, status: :filtered, service: probe_entry ? probe_entry['name'] : 'unknown', banner: "WaitReadable Timeout" }
        rescue Errno::ECONNREFUSED
          # This is the ICMP "port unreachable" - definitively closed.
          # Note: This is OS and firewall dependent. Many systems don't send this for UDP.
          return :closed, { port: port, status: :closed } # Not typically used in UDP scan results directly
        rescue SystemCallError, SocketError => e # Other errors (host unreachable, network down, etc.)
          return :filtered, { port: port, status: :filtered, service: probe_entry ? probe_entry['name'] : 'unknown', banner: "Error: #{e.class.name}"}
        ensure
          sock.close if sock
        end

        # If we got a response
        if response_data && !response_data.empty?
          return :open_responsive, _parse_udp_banner_match(response_data, port, probe_entry)
        else
          # No response after probe (and no timeout if probe was nil and we didn't send anything that expects reply)
          # This is effectively filtered for services that should respond to their probe.
          # For nil probes, any response would have been caught above. No response to a null byte means filtered.
          return :filtered, { port: port, status: :filtered, service: probe_entry ? probe_entry['name'] : 'unknown', banner: "No response" }
        end
      end

      def _parse_udp_banner_match(banner_binary, port, probe_entry)
        details = { port: port, status: :open_responsive, service: "unknown", version: nil, banner: nil }
        return details unless probe_entry # Should always have probe_entry if called from _check_udp_port with response

        details[:service] = probe_entry['name'] # Default service name from probe

        # Convert binary banner to string for regex; be careful with encoding.
        # For many UDP protocols, banner might be binary. For display, hex or safe string.
        # For regex, we might need to match against raw binary or specific string encodings.
        # For simplicity, try UTF-8, replace invalid.
        banner_text = banner_binary.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '.')
        details[:banner] = banner_text.strip.gsub(/[\r\n]+/, ' ')

        match_config = probe_entry['match']
        if match_config
          pattern_str = match_config['pattern']
          match_type = match_config['type']&.downcase

          if pattern_str
            match_found = false
            if match_type == "regex"
              begin
                regex = Regexp.new(pattern_str, Regexp::IGNORECASE | Regexp::MULTILINE)
                match_data = regex.match(banner_text) # Match against textual representation
                if match_data
                  match_found = true
                  # Capture version if group specified
                  if match_config['version_capture_group'].is_a?(Integer) && match_data[match_config['version_capture_group']]
                    details[:version] = match_data[match_config['version_capture_group']]
                  end
                end
              rescue RegexpError
                # Invalid regex in probe file
              end
            elsif match_type == "exact"
              # Exact match might be on binary if probe was binary and response is too.
              # For now, assuming text after conversion.
              match_found = banner_text.include?(pattern_str) # Simple include for "exact" for now
            end

            # If match was required and not found, this isn't our service, or it's a non-confirming version.
            # For now, if a match was defined but not found, we don't override service, just no version.
            # More advanced logic could downgrade confidence or set service to 'unknown'.
          end
        end
        details
      end
    end
  end
end
