require 'socket'
require 'timeout'
require 'thread'
require 'json'
require 'yaml'

module HK
  module Net
    class Scanner
      DEFAULT_TCP_PROBES = {
        21 => { name: 'ftp', probe: "SYST\r\nQUIT\r\n" }, 22 => { name: 'ssh', probe: nil }, 23 => { name: 'telnet', probe: "\r\n\r\n" },
        25 => { name: 'smtp', probe: "EHLO test.com\r\nQUIT\r\n" }, 53 => { name: 'dns', probe: nil }, 80 => { name: 'http', probe: "HEAD / HTTP/1.0\r\n\r\n" },
        110 => { name: 'pop3', probe: "CAPA\r\nQUIT\r\n" }, 143 => { name: 'imap', probe: "CAPABILITY\r\nLOGOUT\r\n" }, 389 => { name: 'ldap', probe: nil },
        443 => { name: 'https', probe: nil }, 445 => { name: 'smb', probe: nil }, 3306 => { name: 'mysql', probe: nil },
        3389 => { name: 'rdp', probe: nil }, 5432 => { name: 'postgres', probe: nil }, 5900 => { name: 'vnc', probe: nil },
        5985 => { name: 'winrm-http', probe: "GET /wsman HTTP/1.1\r\n\r\n" }, 5986 => { name: 'winrm-https', probe: nil },
        6379 => { name: 'redis', probe: "PING\r\n" }, 9200 => { name: 'elasticsearch', probe: "GET / HTTP/1.0\r\n\r\n" },
        27017 => { name: 'mongodb', probe: nil }
      }
      BANNER_READ_TIMEOUT = 2.0
      BANNER_READ_MAX_SIZE = 2048
      UDP_PROBES_FILE = File.expand_path('net/udp_probes.yml', __dir__)
      DEFAULT_UDP_PORTS = [53, 123, 161, 7, 19]
      UDP_RESPONSE_TIMEOUT = 2.0
      UDP_PACKET_READ_SIZE = 1024

      def initialize(options = {})
        # @pastel removed, using HK.logger which has its own coloring via TTY::Color if configured
        @udp_probes_data = _load_udp_probes
        HK.logger.debug "HK::Net::Scanner initialized."
      end

      def tcp_scan(target_host, ports_array, options = {})
        connect_timeout = options.fetch(:timeout, 1.0).to_f
        num_threads = options.fetch(:threads, 10).to_i.clamp(1, 100)
        progress_bar = options[:progress_bar]
        open_ports_details = []; closed_ports = []; filtered_ports = []; results_mutex = Mutex.new; host_error = nil

        HK.logger.info "Starting TCP Connect scan for #{target_host} on #{ports_array.size} port(s) with #{num_threads} thread(s)."
        HK.logger.debug "  Options: timeout=#{connect_timeout}s"

        begin Addrinfo.getaddrinfo(target_host, nil, :INET, :STREAM); rescue SocketError => e; host_error = "Host resolution failed: #{e.message}"; HK.logger.error "  #{host_error}"; progress_bar&.finish; return { target: target_host, open_ports: [], closed_ports: [], filtered_ports: [], error: host_error, options: options }; end

        ports_queue = Queue.new; ports_array.each { |port| ports_queue.push(port) }
        threads = []; num_threads.times do; threads << Thread.new do; while !ports_queue.empty? ; port_to_check = nil; begin port_to_check = ports_queue.pop(true); rescue ThreadError; break; end; next unless port_to_check; status = _check_tcp_port(target_host, port_to_check, connect_timeout); port_detail_to_add = nil; category_array = nil; case status; when :open; port_details = { port: port_to_check, status: :open, service: "unknown", version: nil, banner: nil }; probe_config = DEFAULT_TCP_PROBES[port_to_check] || (port_to_check == 8080 || port_to_check == 8000 ? DEFAULT_TCP_PROBES[80] : nil) || (port_to_check == 9201 || port_to_check == 9300 ? DEFAULT_TCP_PROBES[9200] : nil); if probe_config; banner = _grab_tcp_banner(target_host, port_to_check, connect_timeout, probe_config); if banner; port_details[:banner] = banner.strip.gsub(/[\r\n]+/, ' '); service_info = _parse_tcp_banner(banner, port_to_check, probe_config); port_details[:service] = service_info[:service_name] if service_info[:service_name]; port_details[:version] = service_info[:version] if service_info[:version]; elsif probe_config[:name] && probe_config[:probe].nil?; port_details[:service] = probe_config[:name]; end; elsif port_to_check == 443; port_details[:service] = "https"; end; port_detail_to_add = port_details; category_array = open_ports_details; when :closed; port_detail_to_add = port_to_check; category_array = closed_ports; when :filtered, :unreachable_host; port_detail_to_add = port_to_check; category_array = filtered_ports; end; results_mutex.synchronize { category_array << port_detail_to_add if port_detail_to_add && category_array; progress_bar&.advance; }; end; end; end; threads.each(&:join); progress_bar&.finish
        HK.logger.info "TCP Connect scan complete for #{target_host}."
        { target: target_host, open_ports: open_ports_details.sort_by { |p_info| p_info[:port] }, closed_ports: closed_ports.sort, filtered_ports: filtered_ports.sort, options: options, error: host_error }
      end

      private def _check_tcp_port(host, port, timeout_seconds)
        HK.logger.debug "Checking TCP port #{host}:#{port} (timeout: #{timeout_seconds}s)"
        begin; Timeout.timeout(timeout_seconds) do; sock = Socket.tcp(host, port, connect_timeout: timeout_seconds); sock.close if sock; HK.logger.debug "  Port #{host}:#{port} is open"; return :open; end;
        rescue Timeout::Error; HK.logger.debug "  Port #{host}:#{port} filtered (timeout)"; return :filtered;
        rescue Errno::ECONNREFUSED; HK.logger.debug "  Port #{host}:#{port} closed (refused)"; return :closed;
        rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL; HK.logger.debug "  Port #{host}:#{port} filtered (host/net unreachable)"; return :filtered;
        rescue SocketError => e; HK.logger.debug "  Port #{host}:#{port} filtered (SocketError: #{e.message})"; return :filtered;
        rescue SystemCallError => e; HK.logger.debug "  Port #{host}:#{port} filtered (SystemCallError: #{e.message})"; return :filtered;
        end
      end

      private def _grab_tcp_banner(host, port, connect_timeout, probe_config)
        HK.logger.debug "Grabbing TCP banner for #{host}:#{port} (service: #{probe_config[:name]})"
        begin; Timeout.timeout(connect_timeout + BANNER_READ_TIMEOUT) do; sock = Socket.tcp(host, port, connect_timeout: connect_timeout); if sock; begin; if probe_config[:probe]; sock.write_nonblock(probe_config[:probe]); HK.logger.debug "  Sent probe for #{probe_config[:name]} to #{host}:#{port}"; end; if IO.select([sock], nil, nil, BANNER_READ_TIMEOUT); banner = sock.read_nonblock(BANNER_READ_MAX_SIZE); HK.logger.debug "  Received banner for #{host}:#{port} (approx #{banner&.length} bytes)"; return banner; else; HK.logger.debug "  No banner received (IO.select timeout) for #{host}:#{port}"; return nil; end; rescue IO::WaitWritable; HK.logger.debug "  write_nonblock would block for #{host}:#{port}"; return nil; rescue IO::WaitReadable; HK.logger.debug "  read_nonblock would block for #{host}:#{port}"; return nil; rescue EOFError; HK.logger.debug "  EOFError reading banner from #{host}:#{port}"; return nil; ensure; sock.close; end; end; end;
        rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET, SystemCallError, SocketError => e; HK.logger.debug "  Error grabbing banner for #{host}:#{port} - #{e.class.name}: #{e.message}"; return nil; end; nil
      end

      private def _parse_tcp_banner(banner_string, port, probe_config)
        service_name = probe_config[:name]; version = nil; banner_s = banner_string.to_s.strip;
        HK.logger.debug "Parsing TCP banner for port #{port} (service hint: #{service_name}): '#{banner_s.truncate(80)}'"
        return { service_name: service_name, version: nil } if banner_s.empty? && service_name != 'unknown' && service_name != 'https'; return { service_name: "unknown", version: nil } if banner_s.empty?;
        # ... (rest of parsing logic from turn 162, potentially adding more debug logs if complex decisions are made) ...
        case service_name; when 'http', 'winrm-http', 'elasticsearch'; if banner_s =~ /Server: (.*?)(?:\r\n|$)/i; version = $1.strip; elsif banner_s =~ /HTTP\/\d\.\d \d{3}.*?\r\n.*?Server: (.*?)(?:\r\n|$)/im; version = $1.strip; end; if service_name == 'elasticsearch' && version.nil?; begin; json_banner = JSON.parse(banner_s[/({.*})/, 1] || banner_s); if json_banner['version'] && json_banner['version']['number']; version = "Elasticsearch #{json_banner['version']['number']}"; service_name = 'elasticsearch'; elsif json_banner['tagline'] == "You Know, for Search"; version = "Elasticsearch (generic)"; service_name = 'elasticsearch'; end; rescue JSON::ParserError; end; end; when 'ssh'; if banner_s =~ /SSH-\d\.\d-(.*?)(?:[ \r\n]|$)/; version = $1.strip; end; when 'ftp'; if banner_s =~ /^220[- ](?:ProFTPD|Pure-FTPd|vsFTPd|FileZilla Server|Microsoft FTP Service) ?(v?[\d\w\.\-]+)/i; version_candidate = $1.strip; version = version_candidate if version_candidate && !version_candidate.empty? && version_candidate.length < 60; elsif banner_s =~ /^220 (.*?) FTP server ready/i; version_candidate = $1.strip; version = version_candidate if version_candidate && !version_candidate.empty? && version_candidate.length < 50; end; when 'redis'; if banner_s.include?("+PONG"); service_name = 'redis'; end; end;
        HK.logger.debug "  Parsed service: #{service_name}, version: #{version || 'N/A'}"
        { service_name: service_name, version: version }
      end

      public
      def udp_scan(target_host, ports_array, options = {})
        scan_timeout = options.fetch(:timeout, UDP_RESPONSE_TIMEOUT).to_f; progress_bar = options[:progress_bar]; open_or_responsive_ports = []; filtered_ports = []; results_mutex = Mutex.new; host_error = nil
        HK.logger.info "Starting UDP scan for #{target_host} on #{ports_array.size} port(s)."
        HK.logger.debug "  Options: timeout=#{scan_timeout}s, threads=#{options.fetch(:threads, 5)}"
        begin Addrinfo.getaddrinfo(target_host, nil, :INET, :DGRAM); rescue SocketError => e; host_error = "Host resolution failed for UDP: #{e.message}"; HK.logger.error "  #{host_error}"; progress_bar&.finish; return { target: target_host, open_ports: [], filtered_ports: [], error: host_error, options: options }; end
        ports_to_scan = ports_array.empty? ? DEFAULT_UDP_PORTS : ports_array; ports_queue = Queue.new; ports_to_scan.each { |port| ports_queue.push(port) }; num_threads = options.fetch(:threads, 5).to_i.clamp(1, 50); threads = []; num_threads.times do; threads << Thread.new do; while !ports_queue.empty?; port_to_check = nil; begin port_to_check = ports_queue.pop(true); rescue ThreadError; break; end; next unless port_to_check; probe_entry = @udp_probes_data.find { |p| p['port'] == port_to_check }; status, details = _check_udp_port(target_host, port_to_check, probe_entry, scan_timeout); results_mutex.synchronize { case status; when :open_responsive; open_or_responsive_ports << details; when :filtered; filtered_ports << port_to_check; end; progress_bar&.advance; }; end; end; end; threads.each(&:join); progress_bar&.finish
        HK.logger.info "UDP scan complete for #{target_host}."
        { target: target_host, open_ports: open_or_responsive_ports.sort_by { |p_info| p_info[:port] }, filtered_ports: filtered_ports.sort, options: options, error: host_error }
      end

      private
      def _load_udp_probes; return [] unless File.exist?(UDP_PROBES_FILE); begin YAML.safe_load_file(UDP_PROBES_FILE, permitted_classes: [Symbol], aliases: true) || []; rescue Psych::Exception => e; HK.logger.error "Error loading UDP probes file #{UDP_PROBES_FILE}: #{e.message}"; []; end; end
      def _hex_decode(hex_string); [hex_string].pack('H*'); end
      def _check_udp_port(host, port, probe_entry, timeout_seconds)
        HK.logger.debug "Checking UDP port #{host}:#{port} (timeout: #{timeout_seconds}s)"
        response_data = nil; sock = UDPSocket.new(Socket.const_defined?(:AF_INET6) && host.include?(':') ? Socket::AF_INET6 : Socket::AF_INET)
        begin
          probe_payload = probe_entry ? _hex_decode(probe_entry['probe']) : nil
          service_name_for_log = probe_entry ? probe_entry['name'] : 'nil_probe'
          if probe_payload && !probe_payload.empty?; sock.send(probe_payload, 0, host, port); HK.logger.debug "  Sent UDP probe for #{service_name_for_log} to #{host}:#{port}"; else; sock.send("\0", 0, host, port); HK.logger.debug "  Sent NULL byte UDP probe to #{host}:#{port}"; end
          if IO.select([sock], nil, nil, timeout_seconds); response_data, sender_addrinfo = sock.recvfrom_nonblock(UDP_PACKET_READ_SIZE); HK.logger.debug "  Response received from #{host}:#{port} (sender: #{sender_addrinfo.inspect_sockaddr}, size: #{response_data&.length})"; else; HK.logger.debug "  UDP port #{host}:#{port} filtered (timeout on read)"; return :filtered, { port: port, status: :filtered, service: probe_entry ? probe_entry['name'] : 'unknown', banner: "Timeout" }; end
        rescue IO::WaitReadable; HK.logger.debug "  UDP port #{host}:#{port} filtered (WaitReadable timeout)"; return :filtered, { port: port, status: :filtered, service: probe_entry ? probe_entry['name'] : 'unknown', banner: "WaitReadable Timeout" };
        rescue Errno::ECONNREFUSED; HK.logger.debug "  UDP port #{host}:#{port} closed (refused)"; return :closed, { port: port, status: :closed }; # Though rare for UDP
        rescue SystemCallError, SocketError => e; HK.logger.debug "  UDP port #{host}:#{port} filtered (Error: #{e.class.name} - #{e.message})"; return :filtered, { port: port, status: :filtered, service: probe_entry ? probe_entry['name'] : 'unknown', banner: "Error: #{e.class.name}"};
        ensure; sock.close if sock; end
        if response_data && !response_data.empty?; return :open_responsive, _parse_udp_banner_match(response_data, port, probe_entry); else; HK.logger.debug "  UDP port #{host}:#{port} filtered (no response data)"; return :filtered, { port: port, status: :filtered, service: probe_entry ? probe_entry['name'] : 'unknown', banner: "No response" }; end
      end
      def _parse_udp_banner_match(banner_binary, port, probe_entry)
        details = { port: port, status: :open_responsive, service: "unknown", version: nil, banner: nil }; return details unless probe_entry
        details[:service] = probe_entry['name']; banner_text = banner_binary.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '.'); details[:banner] = banner_text.strip.gsub(/[\r\n]+/, ' '); match_config = probe_entry['match']
        HK.logger.debug "Parsing UDP banner for port #{port} (service hint: #{details[:service]}): '#{details[:banner].truncate(80)}'"
        if match_config; pattern_str = match_config['pattern']; match_type = match_config['type']&.downcase
          if pattern_str; match_found = false
            if match_type == "regex"; begin; regex = Regexp.new(pattern_str, Regexp::IGNORECASE | Regexp::MULTILINE); match_data = regex.match(banner_text); if match_data; match_found = true; HK.logger.debug "    Regex '#{pattern_str}' matched."; if match_config['version_capture_group'].is_a?(Integer) && match_data[match_config['version_capture_group']]; details[:version] = match_data[match_config['version_capture_group']]; HK.logger.debug "      Version captured: #{details[:version]}"; end; end; rescue RegexpError => e; HK.logger.warn "    Invalid regex in UDP probe for #{details[:service]}: #{pattern_str} - #{e.message}";end
            elsif match_type == "exact"; match_found = banner_text.include?(pattern_str); HK.logger.debug "    Exact match for '#{pattern_str}': #{match_found}"; end
            # If match was required but not found, could reset service to unknown, but current logic keeps probe's name.
            # HK.logger.debug "    Match result for port #{port}: #{match_found}"
          end;
        else
          HK.logger.debug "    No specific match defined for port #{port}, service '#{details[:service]}'. Response itself indicates service presence."
        end;
        HK.logger.debug "  Parsed UDP service: #{details[:service]}, version: #{details[:version] || 'N/A'}"
        details
      end
    end
  end
end
