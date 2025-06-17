require 'json'
require 'set'
require 'uri'

module HK
  class SubdomainFinder
    attr_reader :domain, :options, :web_client, :original_input

    def initialize(domain_or_url, options = {})
      @original_input = domain_or_url
      @domain = self.class.sanitize_domain(domain_or_url) # sanitize_domain now uses HK.logger
      unless @domain
        # Error already logged by sanitize_domain if input was problematic
        raise ArgumentError, "Invalid domain or URL provided: '#{@original_input}'"
      end

      @options = options
      @web_client = HK::Web::Client.new

      # @pastel removed, using HK.logger
      HK.logger.debug "HK::SubdomainFinder initialized. Original: '#{@original_input}', Domain: '#{@domain}'"
    end

    def discover
      HK.logger.info "SubdomainFinder: Discovering subdomains for #{@domain}"

      all_found_subdomains = Set.new

      # Currently only one source, crt.sh
      HK.logger.debug "Fetching from 1 source(s)..."
      crtsh_subdomains = _fetch_from_crtsh
      if crtsh_subdomains
        HK.logger.debug "  Found #{crtsh_subdomains.size} raw entries from crt.sh"
        all_found_subdomains.merge(crtsh_subdomains)
      end

      cleaned_subdomains = all_found_subdomains
                            .map(&:downcase)
                            .reject { |sd| sd.include?('*') || sd == @domain }
                            .sort

      HK.logger.info "Found #{cleaned_subdomains.size} unique, valid subdomains for #{@domain}."
      cleaned_subdomains
    end

    private

    def _fetch_from_crtsh
      HK.logger.debug "  Fetching from crt.sh for %.#{@domain}"
      crtsh_url = "https://crt.sh/?q=%.#{@domain}&output=json"
      found_names = Set.new

      client_options = { timeout: @options.fetch(:timeout, 15) }

      probe_result = @web_client.probe(crtsh_url, client_options) # HK.Web.Client already logs its actions

      if probe_result[:error]
        HK.logger.warn "    Error fetching from crt.sh for #{@domain}: #{probe_result[:error]}"
        return found_names
      end

      unless probe_result[:body]
        HK.logger.warn "    No body returned from crt.sh for #{@domain}"
        return found_names
      end

      begin
        json_data = JSON.parse(probe_result[:body])
        unless json_data.is_a?(Array)
          HK.logger.warn "    crt.sh JSON response was not an array for #{@domain}. Body: #{probe_result[:body].truncate(100)}"
          return found_names
        end

        json_data.each do |entry|
          if entry.is_a?(Hash) && entry['name_value']
            entry['name_value'].split("\n").each do |name|
              cleaned_name = name.strip
              if !cleaned_name.empty?
                found_names.add(cleaned_name)
              end
            end
          end
        end
        HK.logger.debug "    Successfully parsed #{found_names.size} unique names from crt.sh response."
      rescue JSON::ParserError => e
        HK.logger.error "    Error parsing JSON from crt.sh for #{@domain}: #{e.message}. Body: #{probe_result[:body].truncate(100)}"
      end

      found_names
    end

    def self.sanitize_domain(domain_or_url)
        return nil if domain_or_url.nil? || domain_or_url.strip.empty?
        input = domain_or_url.strip.downcase

        input_after_scheme_strip = input.gsub(%r{^https?://}, '')

        uri_host = nil
        begin
            uri_host = URI.parse("http://#{input_after_scheme_strip}").host # Add temp scheme for robust host extraction
            uri_host = uri_host.gsub(/^www\./, '') if uri_host
            if uri_host && !uri_host.empty? && uri_host.include?('.')
              # HK.logger.debug "Sanitized '#{domain_or_url}' to '#{uri_host}' via URI parsing." # Too verbose for a class method usually
              return uri_host
            end
        rescue URI::InvalidURIError
            # Fallthrough to regex if URI parsing complexly fails (e.g. bad chars not in host part)
        end

        # Fallback for simple domain names or if URI parsing didn't yield a valid host
        # This regex is basic and primarily for "domain.tld" type inputs.
        # It won't correctly extract from full paths if URI.parse failed badly.
        if input_after_scheme_strip.match?(/\A([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}\z/i)
            # HK.logger.debug "Sanitized '#{domain_or_url}' to '#{input_after_scheme_strip}' via regex fallback."
            return input_after_scheme_strip
        end

        HK.logger.warn "Could not reliably sanitize domain from input: '#{domain_or_url}'"
        nil
    end
  end
end
