require 'httparty'
require 'timeout'

module HK
  module Web
    class Client
      # Default User-Agent for HK Web Client
      DEFAULT_USER_AGENT = "HK Security Scanner/#{HK::VERSION}"

      def initialize
        if defined?(TTY::Color)
          @pastel = TTY::Color
        else
          @pastel = Object.new
          def @pastel.method_missing(*args, &block); args.first; end
          def @pastel.respond_to_missing?(method_name, include_private = false); true; end
        end
      end

      def probe(url, options = {})
        response_data = {
          url: url,
          status_code: nil,
          title: nil,
          error: nil,
          raw_headers: nil,
          body: nil,
          final_url: url,
          cookies: nil # To store returned cookies or state of jar
        }

        begin
          method = options.fetch(:method, 'GET').to_s.upcase
          body_data = options[:body_data]
          request_timeout = options.fetch(:timeout, 5).to_i

          httparty_options = {
            timeout: request_timeout,
            verify: false,
            headers: { 'User-Agent' => DEFAULT_USER_AGENT },
            # HTTParty handles redirects by default (follow_redirects: true)
            # To get the final URL, we use response.request.last_uri
          }

          if options[:headers].is_a?(Hash)
            httparty_options[:headers].merge!(options[:headers])
          end

          if body_data && %w[POST PUT PATCH].include?(method)
            httparty_options[:body] = body_data
          end

          # Cookie Management
          # If a CookieHash object is passed in options, use it.
          # Otherwise, HTTParty uses its default cookie handling (often per-class instance or per-request).
          # For more persistent cookie sessions across multiple Client instances or calls,
          # the caller needs to manage and pass the cookie_jar.
          if options[:cookie_jar].is_a?(HTTParty::CookieHash)
            httparty_options[:cookies] = options[:cookie_jar]
          end

          parsed_url_obj = URI.parse(url.strip)
          url_to_probe = parsed_url_obj.scheme.nil? ? "http://" + url.strip : parsed_url_obj.to_s

          response = nil
          case method
          when 'GET'
            response = HTTParty.get(url_to_probe, httparty_options)
          when 'POST'
            response = HTTParty.post(url_to_probe, httparty_options)
          else
            raise ArgumentError, "Unsupported HTTP method: #{method}"
          end

          response_data[:status_code] = response.code
          response_data[:raw_headers] = response.headers.to_h
          response_data[:body] = response.body
          response_data[:final_url] = response.request.last_uri.to_s

          # Store cookies from the response (or the state of the provided jar)
          # HTTParty::Response#cookies is a CookieHash of cookies *sent back by the server*
          # If a cookie_jar was passed in options, it would have been updated by HTTParty.
          response_data[:cookies] = response.cookies.to_h # Store as a simple hash

          if response_data[:body]
            title_match = response_data[:body].match(/<title[^>]*>(.*?)<\/title>/im)
            response_data[:title] = title_match[1].strip if title_match && title_match[1]
          end

        rescue ArgumentError => e
            response_data[:error] = e.class.name + ": " + e.message
        rescue HTTParty::Error, SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError, StandardError => e
          response_data[:error] = e.class.name + ": " + e.message
          response_data[:final_url] = url_to_probe if defined?(url_to_probe)
        end

        response_data
      end

      def probe_multiple(urls, common_options = {})
        results = []
        # Create a single cookie jar for this batch of requests if one isn't provided
        # This allows cookies to persist across requests in this batch.
        # If a jar is in common_options, it will be used and potentially modified.
        # If not, a new one is created for the batch.
        batch_cookie_jar = common_options[:cookie_jar] || HTTParty::CookieHash.new
        options_with_batch_jar = common_options.merge(cookie_jar: batch_cookie_jar)

        urls.each do |url|
          results << probe(url, options_with_batch_jar)
        end
        results
      end
    end
  end
end
