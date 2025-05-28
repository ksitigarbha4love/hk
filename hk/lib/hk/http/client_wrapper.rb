require 'uri'
# Assumes HK::Web::Client is already loaded via hk.rb

module HK
  module Http
    class ClientWrapper
      attr_reader :base_target_url, :web_client

      def initialize(web_client_instance, base_target_url)
        @web_client = web_client_instance
        # Ensure base_target_url ends with a slash for URI.join to work as expected with relative paths
        @base_target_url = base_target_url
        @base_target_url += '/' unless @base_target_url.end_with?('/')
      end

      def get(path = "", options = {})
        full_url = URI.join(@base_target_url, path).to_s
        # puts "ClientWrapper GET: #{full_url}"
        # Probe options should be passed through, e.g. timeout, custom headers for this request
        probe_options = { timeout: options[:timeout], headers: options[:headers] }.compact
        result = @web_client.probe(full_url, probe_options)
        # Simplify result for template authors
        { status: result[:status_code], body: result[:body], headers: result[:raw_headers], error: result[:error] }
      end

      # Placeholder for POST, etc.
      def post(path = "", body_data = {}, options = {})
        full_url = URI.join(@base_target_url, path).to_s
        # puts "ClientWrapper POST: #{full_url} with body #{body_data}"
        # HK::Web::Client.probe currently only does GET. This would need extension.
        # For now, simulate or return error.
        { error: "POST not yet implemented in HK::Web::Client via wrapper" }
      end
    end
  end
end
