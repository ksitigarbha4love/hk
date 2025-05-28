require 'socket'
require 'timeout'
require 'thread' 
require 'json' # For parsing Elasticsearch banner

module HK
  module Net
    class Scanner
      DEFAULT_PROBES = {
        21 => { name: 'ftp', probe: "SYST\r\nQUIT\r\n" },
        22 => { name: 'ssh', probe: nil }, 
        23 => { name: 'telnet', probe: "\r\n\r\n" },
        25 => { name: 'smtp', probe: "EHLO test.com\r\nQUIT\r\n" },
        53 => { name: 'dns', probe: nil }, 
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
        6379 => { name: 'redis', probe: "PING\r\n" }, # Corrected to \r\n
        9200 => { name: 'elasticsearch', probe: "GET / HTTP/1.0\r\n\r\n" }, # Corrected to \r\n
        27017 => { name: 'mongodb', probe: nil } 
      }
      BANNER_READ_TIMEOUT = 2.0 
      BANNER_READ_MAX_SIZE = 2048 

      def initialize
        if defined?(TTY::Color)
          @pastel = TTY::Color
        else
          @pastel = Object.new
          def @pastel.method_missing(*args, &block); args.first; end
          def @pastel.respond_to_missing?(method_name, include_private = false); true; end
        end
      end

      def tcp_scan(target_host, ports_array, options = {})
        connect_timeout = options.fetch(:timeout, 1.0).to_f
        num_threads = options.fetch(:threads, 10).to_i.clamp(1, 100)
        progress_bar = options[:progress_bar] 

        open_ports_details = []
        closed_ports = []
        filtered_ports = []
        results_mutex = Mutex.new
        host_error = nil

        begin
            Addrinfo.getaddrinfo(target_host, nil, :INET, :STREAM)
        rescue SocketError => e 
            host_error = "Host resolution failed: #{e.message}"
            progress_bar&.finish 
            return {
                target: target_host, open_ports: [], closed_ports: [], filtered_ports: [],
                error: host_error, options: options
            }
        end

        ports_queue = Queue.new
        ports_array.each { |port| ports_queue.push(port) }

        threads = []
        num_threads.times do
          threads << Thread.new do
            while !ports_queue.empty? 
                port_to_check = nil
                begin
                    port_to_check = ports_queue.pop(true) 
                rescue ThreadError 
                    break 
                end
                next unless port_to_check 

                status = _check_port(target_host, port_to_check, connect_timeout)
                port_detail_to_add = nil
                category_array = nil 

                case status
                when :open
                    port_details = { port: port_to_check, status: :open, service: "unknown", version: nil, banner: nil }
                    
                    probe_config = DEFAULT_PROBES[port_to_check] || 
                                   (port_to_check == 8080 || port_to_check == 8000 ? DEFAULT_PROBES[80] : nil) ||
                                   (port_to_check == 9201 || port_to_check == 9300 ? DEFAULT_PROBES[9200] : nil)

                    if probe_config 
                        banner = _grab_banner(target_host, port_to_check, connect_timeout, probe_config)
                        if banner
                            port_details[:banner] = banner.strip.gsub(/[\r\n]+/, ' ') 
                            service_info = _parse_banner(banner, port_to_check, probe_config)
                            port_details[:service] = service_info[:service_name] if service_info[:service_name]
                            port_details[:version] = service_info[:version] if service_info[:version]
                        elsif probe_config[:name] && probe_config[:probe].nil? 
                            port_details[:service] = probe_config[:name]
                        end
                    elsif port_to_check == 443 
                        port_details[:service] = "https" 
                    end
                    port_detail_to_add = port_details
                    category_array = open_ports_details
                when :closed
                    port_detail_to_add = port_to_check
                    category_array = closed_ports
                when :filtered, :unreachable_host 
                    port_detail_to_add = port_to_check
                    category_array = filtered_ports
                end

                results_mutex.synchronize do
                    category_array << port_detail_to_add if port_detail_to_add && category_array
                    progress_bar&.advance 
                end
            end 
          end 
        end 

        threads.each(&:join)
        progress_bar&.finish 

        {
          target: target_host,
          open_ports: open_ports_details.sort_by { |p_info| p_info[:port] },
          closed_ports: closed_ports.sort,
          filtered_ports: filtered_ports.sort,
          options: options, 
          error: host_error 
        }
      end
      
      private

      def _grab_banner(host, port, connect_timeout, probe_config)
        begin
          Timeout.timeout(connect_timeout + BANNER_READ_TIMEOUT) do 
            sock = Socket.tcp(host, port, connect_timeout: connect_timeout)
            if sock
              begin
                if probe_config[:probe]
                  sock.write_nonblock(probe_config[:probe]) 
                end
                if IO.select([sock], nil, nil, BANNER_READ_TIMEOUT)
                  return sock.read_nonblock(BANNER_READ_MAX_SIZE) 
                else
                  return nil 
                end
              rescue IO::WaitWritable 
                return nil
              rescue IO::WaitReadable 
                return nil 
              rescue EOFError 
                return nil 
              ensure
                sock.close
              end
            end
          end
        rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET, SystemCallError, SocketError
          return nil
        end
        nil 
      end

      # Updated _parse_banner method
      def _parse_banner(banner_string, port, probe_config)
        service_name = probe_config[:name] 
        version = nil
        banner_s = banner_string.to_s.strip # Ensure string and strip for easier regex

        # If banner is empty but we have a known service for the port (e.g. probe:nil), keep service name
        return { service_name: service_name, version: nil } if banner_s.empty? && service_name != 'unknown' && service_name != 'https' # HTTPS is special
        return { service_name: "unknown", version: nil } if banner_s.empty?
        
        case service_name 
        when 'http', 'winrm-http', 'elasticsearch' 
          if banner_s =~ /Server: (.*?)(?:\r\n|$)/i
            version = $1.strip
          elsif banner_s =~ /HTTP\/\d\.\d \d{3}.*?\r\n.*?Server: (.*?)(?:\r\n|$)/im 
            version = $1.strip
          end
          if service_name == 'elasticsearch' && version.nil? 
              begin
                  json_banner = JSON.parse(banner_s[/({.*})/, 1] || banner_s) 
                  if json_banner['version'] && json_banner['version']['number']
                      version = "Elasticsearch #{json_banner['version']['number']}"
                      service_name = 'elasticsearch' 
                  elsif json_banner['tagline'] == "You Know, for Search" 
                      version = "Elasticsearch (generic)"
                      service_name = 'elasticsearch'
                  end
              rescue JSON::ParserError
                  # Not JSON or malformed
              end
          end
        when 'ssh'
          if banner_s =~ /SSH-\d\.\d-(.*?)(?:[ \r\n]|$)/
            version = $1.strip
          end
        when 'ftp'
          if banner_s =~ /^220[- ](?:ProFTPD|Pure-FTPd|vsFTPd|FileZilla Server|Microsoft FTP Service) ?(v?[\d\w\.\-]+)/i
            version_candidate = $1.strip
            version = version_candidate if version_candidate && !version_candidate.empty? && version_candidate.length < 60
          elsif banner_s =~ /^220 (.*?) FTP server ready/i 
              version_candidate = $1.strip
              version = version_candidate if version_candidate && !version_candidate.empty? && version_candidate.length < 50
          end
        when 'redis'
          if banner_s.include?("+PONG")
            service_name = 'redis' # Confirmed
            # Redis version is usually obtained by INFO command, not from PING response.
          end
        # For 'mysql', 'postgres', 'rdp', 'mongodb', 'smb', 'vnc', 'ldap', 'dns', 
        # 'smtp', 'pop3', 'imap', 'telnet', 'winrm-https':
        # If banner is present, it might contain version info, but it's often not standardized.
        # For these, if a banner is not empty, we'll keep the service_name from DEFAULT_PROBES
        # and the raw banner will be available in port_details[:banner].
        # Further specific parsing can be added here if common patterns are identified.
        # If probe_config[:name] is already set (e.g. 'mysql'), and banner is not empty,
        # we might still try a generic version extraction if one exists.
        # else
        #   if !banner_s.empty? && service_name != 'unknown'
        #     # Generic attempt (very basic)
        #     # if banner_s =~ /(\d+\.\d+(\.\d+)*)/ 
        #     #   version = $1
        #     # end
        #   end
        end
        { service_name: service_name, version: version }
      end
      
      def _check_port(host, port, timeout_seconds)
        begin
          Timeout.timeout(timeout_seconds) do
            sock = Socket.tcp(host, port, connect_timeout: timeout_seconds)
            sock.close if sock
            return :open
          end
        rescue Timeout::Error
          return :filtered 
        rescue Errno::ECONNREFUSED
          return :closed
        rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL
          return :filtered 
        rescue SocketError => e 
          return :filtered # As per prompt's code block for _check_port in Scanner
        rescue SystemCallError => e 
          return :filtered
        end
      end
    end
  end
end
