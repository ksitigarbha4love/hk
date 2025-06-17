require 'httparty'
require 'timeout'

module HK
  module Web
    class Client
      DEFAULT_USER_AGENT = "HK Security Scanner/#{HK::VERSION}"

      def initialize
        # @pastel removed, using HK.logger
        HK.logger.debug "HK::Web::Client initialized."
      end

      def probe(url, options = {})
        response_data = { url: url, status_code: nil, title: nil, error: nil, raw_headers: nil, body: nil, final_url: url, cookies: nil }

        method = options.fetch(:method, 'GET').to_s.upcase
        body_data = options[:body_data]
        request_timeout = options.fetch(:timeout, 5).to_i

        HK.logger.info "Probing (#{method}) URL: #{url}"
        HK.logger.debug "  Probe Options: #{options.reject { |k,v| k == :body_data && v.is_a?(String) && v.length > 100 } }" # Avoid logging large bodies

        begin
          httparty_options = {
            timeout: request_timeout,
            verify: false,
            headers: { 'User-Agent' => DEFAULT_USER_AGENT }
          }

          if options[:headers].is_a?(Hash)
            httparty_options[:headers].merge!(options[:headers])
          end

          if body_data && %w[POST PUT PATCH].include?(method)
            httparty_options[:body] = body_data
          end

          if options[:cookie_jar].is_a?(HTTParty::CookieHash)
            httparty_options[:cookies] = options[:cookie_jar]
          end

          parsed_url_obj = URI.parse(url.strip)
          url_to_probe = parsed_url_obj.scheme.nil? ? "http://" + url.strip : parsed_url_obj.to_s

          HK.logger.debug "  Final HTTParty Options (body redacted if long): #{httparty_options.reject{|k,v| k==:body && v.is_a?(String) && v.length > 100 }}"

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
          response_data[:cookies] = response.cookies.to_h

          if response_data[:body]
            title_match = response_data[:body].match(/<title[^>]*>(.*?)<\/title>/im)
            response_data[:title] = title_match[1].strip if title_match && title_match[1]
          end
          HK.logger.debug "  Probe successful for #{url_to_probe}. Status: #{response_data[:status_code]}. Final URL: #{response_data[:final_url]}"

        rescue ArgumentError => e
            response_data[:error] = e.class.name + ": " + e.message
            HK.logger.error "  Probe argument error for #{url}: #{response_data[:error]}"
        rescue HTTParty::Error, SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError, StandardError => e
          response_data[:error] = e.class.name + ": " + e.message
          response_data[:final_url] = url_to_probe if defined?(url_to_probe)
          HK.logger.warn "  Probe failed for #{defined?(url_to_probe) ? url_to_probe : url}: #{response_data[:error]}"
        end

        response_data
      end

      def probe_multiple(urls, common_options = {})
        HK.logger.info "Probing multiple URLs (count: #{urls.size})."
        HK.logger.debug "  Common options for batch: #{common_options.reject { |k,v| k == :body_data && v.is_a?(String) && v.length > 100 }}"
        results = []
        batch_cookie_jar = common_options[:cookie_jar] || HTTParty::CookieHash.new
        options_with_batch_jar = common_options.merge(cookie_jar: batch_cookie_jar)

        urls.each do |url|
          # HK.logger.debug "  Batch probing URL: #{url}" # Covered by individual probe logs
          results << probe(url, options_with_batch_jar)
        end
        results
      end
    end
  end
end
