require 'socket'
require 'timeout'

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
        443 => { name: 'https', probe: nil } 
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

      # Modified tcp_scan to accept and advance a progress bar
      def tcp_scan(target_host, ports_array, options = {}, progress_bar = nil)
        connect_timeout = options.fetch(:timeout, 1.0).to_f
        
        open_ports_details = [] 
        closed_ports = []
        filtered_ports = []
        host_error = nil

        begin
            Addrinfo.getaddrinfo(target_host, nil, :INET, :STREAM)
        rescue SocketError => e 
            host_error = "Host resolution failed: #{e.message}"
            progress_bar&.finish # Ensure bar is finished if it was started
            return {
                target: target_host, open_ports: [], closed_ports: [], filtered_ports: [],
                error: host_error, options: options
            }
        end

        # If progress_bar is given, its total should be set to ports_array.size by the caller
        ports_array.each do |port|
          status = _check_port(target_host, port, connect_timeout)
          case status
          when :open
            port_details = { port: port, status: :open, service: "unknown", version: nil, banner: nil }
            probe_config = DEFAULT_PROBES[port] || (port == 8080 || port == 8000 ? DEFAULT_PROBES[80] : nil) 

            if probe_config 
              banner = _grab_banner(target_host, port, connect_timeout, probe_config)
              if banner
                port_details[:banner] = banner.strip.gsub(/[\r\n]+/, ' ') 
                service_info = _parse_banner(banner, port, probe_config)
                port_details[:service] = service_info[:service_name] if service_info[:service_name]
                port_details[:version] = service_info[:version] if service_info[:version]
              end
            elsif port == 443 
                begin
                    Timeout.timeout(connect_timeout) do
                        sock = Socket.tcp(target_host, port, connect_timeout: connect_timeout)
                        if sock 
                            port_details[:service] = "https"
                            sock.close
                        end
                    end
                rescue 
                end
            end
            open_ports_details << port_details
          when :closed
            closed_ports << port
          when :filtered, :unreachable_host 
            filtered_ports << port
          end
          progress_bar&.advance # Advance progress bar after each port check
        end
        
        {
          target: target_host,
          open_ports: open_ports_details, 
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

      def _parse_banner(banner_string, port, probe_config) 
        banner_s = banner_string.to_s 
        return { service_name: probe_config[:name], version: nil } if banner_s.empty?
        
        service_name = probe_config[:name] 
        version = nil
        
        case service_name 
        when 'http'
          if banner_s =~ /Server: (.*?)(?:\r\n|$)/i
            version = $1.strip
          elsif banner_s =~ /HTTP\/\d\.\d \d{3}.*?\r\n.*?Server: (.*?)(?:\r\n|$)/im
            version = $1.strip
          end
        when 'ssh'
          if banner_s =~ /SSH-\d\.\d-(.*?)(?:[ \r\n]|$)/
            version = $1.strip
          end
        when 'ftp'
          if banner_s =~ /^220 (?:ProFTPD|Pure-FTPd|vsFTPd|FileZilla Server|Microsoft FTP Service) ?(.*?)(?:\r\n|$| Welcome)/i
            version = $1.strip if $1 && !$1.strip.empty?
          elsif banner_s =~ /^220 (.*?) FTP server ready/i 
              version = $1.strip unless $1.strip.empty?
          end
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
          return :filtered 
        rescue SystemCallError => e 
          return :filtered
        end
      end
    end
  end
end
