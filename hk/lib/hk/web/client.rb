require 'httparty'
require 'timeout' 

module HK
  module Web
    class Client
      def initialize
        # Ensuring TTY::Color is available or providing a fallback for robustness,
        # even if the prompt's version is simpler. This was in my previous versions.
        if defined?(TTY::Color)
          @pastel = TTY::Color
        else
          @pastel = Object.new
          def @pastel.method_missing(*args, &block); args.first; end
          def @pastel.respond_to_missing?(method_name, include_private = false); true; end
        end
      end

      def probe(url, options = {})
        # Initialize with body: nil as per the prompt
        response_data = { url: url, status_code: nil, title: nil, error: nil, raw_headers: nil, body: nil } 
        
        begin
          # Ensure URL has a scheme - using the logic from the prompt
          parsed_url_obj = URI.parse(url.strip) # Renamed to avoid conflict if url is reassigned
          if parsed_url_obj.scheme.nil?
            url_to_probe = "http://" + url.strip # Default to http
          else
            url_to_probe = parsed_url_obj.to_s
          end

          request_timeout = options.fetch(:timeout, 5).to_i
          # Using verify: false as per prompt, acknowledge security implications for real use.
          httparty_options = { timeout: request_timeout, verify: false } 
          
          if options[:headers]
            httparty_options[:headers] = options[:headers]
          end

          response = HTTParty.get(url_to_probe, httparty_options)
          
          response_data[:status_code] = response.code
          response_data[:raw_headers] = response.headers.to_h
          response_data[:body] = response.body # *** Ensure body is explicitly added ***

          # Title extraction should happen after body is assigned and checked
          if response_data[:body] # Check if body is not nil
            title_match = response_data[:body].match(/<title[^>]*>(.*?)<\/title>/im)
            response_data[:title] = title_match[1].strip if title_match && title_match[1]
          end

        rescue HTTParty::Error, SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError, StandardError => e
          response_data[:error] = e.class.name + ": " + e.message
        end
        
        response_data
      end
    end
  end
end
