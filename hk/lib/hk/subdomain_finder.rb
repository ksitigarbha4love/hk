require 'json'
require 'set'
require 'uri' # For domain parsing from full URLs if provided
# Assuming HK::Web::Client is loaded via hk.rb or explicitly required if not.

module HK
  class SubdomainFinder
    attr_reader :domain, :options, :web_client, :original_input # Added original_input

    def initialize(domain_or_url, options = {})
      @original_input = domain_or_url # Store original input for error messages
      @domain = self.class.sanitize_domain(domain_or_url)
      unless @domain
        # Use @original_input in error message for clarity
        raise ArgumentError, "Invalid domain or URL provided: '#{@original_input}'" 
      end

      @options = options
      @web_client = HK::Web::Client.new 
      
      # Using robust pastel instantiation from previous consistent implementations
      if defined?(TTY::Color)
        @pastel = TTY::Color
      else
        @pastel = Object.new
        def @pastel.method_missing(*args, &block); args.first; end
        def @pastel.respond_to_missing?(method_name, include_private = false); true; end
      end
      # puts @pastel.cyan("HK::SubdomainFinder initialized.") + " Original: '#{@original_input}', Domain: '#{@domain}'"
    end

    def discover
      # puts @pastel.cyan("SubdomainFinder:") + " Discovering subdomains for " + @pastel.yellow.bold(@domain)
      
      all_found_subdomains = Set.new

      crtsh_subdomains = _fetch_from_crtsh
      all_found_subdomains.merge(crtsh_subdomains) if crtsh_subdomains
      
      cleaned_subdomains = all_found_subdomains
                            .map(&:downcase)
                            .reject { |sd| sd.include?('*') || sd == @domain }
                            .sort
          
      # puts @pastel.green("  Found #{cleaned_subdomains.size} unique subdomains.")
      cleaned_subdomains
    end

    private

    def _fetch_from_crtsh
      # puts @pastel.dim("  Fetching from crt.sh for %.#{@domain}")
      crtsh_url = "https://crt.sh/?q=%.#{@domain}&output=json"
      found_names = Set.new
      
      client_options = { timeout: @options.fetch(:timeout, 15) } 

      probe_result = @web_client.probe(crtsh_url, client_options)

      if probe_result[:error]
        # puts @pastel.red("    Error fetching from crt.sh: #{probe_result[:error]}")
        return found_names 
      end

      unless probe_result[:body]
        # puts @pastel.yellow("    No body returned from crt.sh for #{@domain}")
        return found_names
      end
      
      begin
        json_data = JSON.parse(probe_result[:body])
        unless json_data.is_a?(Array)
          # puts @pastel.yellow("    crt.sh JSON response was not an array for #{@domain}")
          return found_names
        end

        json_data.each do |entry|
          if entry.is_a?(Hash) && entry['name_value']
            # name_value can contain multiple domains separated by newlines
            entry['name_value'].split("\n").each do |name| # Using "\n" as per SUT
              cleaned_name = name.strip
              if !cleaned_name.empty? 
                found_names.add(cleaned_name)
              end
            end
          end
        end
      rescue JSON::ParserError => e
        # puts @pastel.red("    Error parsing JSON from crt.sh for #{@domain}: #{e.message}")
      end
      
      found_names
    end
    
    # Helper to sanitize domain input (using logic from prompt)
    def self.sanitize_domain(domain_or_url)
        return nil if domain_or_url.nil? || domain_or_url.strip.empty?
        input = domain_or_url.strip.downcase
        
        input = input.gsub(%r{^https?://}, '')
        
        begin
            # Add temp scheme for URI to parse host correctly, handles ports etc.
            uri_host = URI.parse("http://#{input}").host 
            # Basic validation: must have a dot and not be empty.
            # The prompt's version also had: uri_host = uri_host.gsub(/^www\./, '') if uri_host
            # This is reasonable to get the "effective" domain for crt.sh search.
            uri_host = uri_host.gsub(/^www\./, '') if uri_host 
            return uri_host if uri_host && !uri_host.empty? && uri_host.include?('.')
        rescue URI::InvalidURIError
            # Fallback for inputs that URI can't parse as a host part of a URL
            return nil if !input.include?('.') 
            # Match if it looks like a valid hostname (simplistic check from prompt)
            return input if input.match?(/\A([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}\z/i)
        end
        nil
    end

  end
end
