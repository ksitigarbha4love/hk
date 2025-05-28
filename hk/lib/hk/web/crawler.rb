require 'set'
require 'uri'
require 'nokogiri'
# require_relative 'client' # Assumed loaded via hk.rb

module HK
  module Web
    class Crawler
      attr_reader :initial_url_str, :initial_url, :options, :visited_urls, :depth_limit, :web_client, :scope

      VALID_SCOPES = [:host, :subdomain, :path, :domain].freeze

      def initialize(initial_url, options = {})
        @initial_url_str = initial_url
        normalized_url_string = self.class.normalize_url(initial_url_str)
        unless normalized_url_string
          raise ArgumentError, "Invalid initial URL: #{initial_url_str}"
        end
        @initial_url = URI.parse(normalized_url_string) # Store as URI object

        @options = options
        @depth_limit = options.fetch(:depth, 2).to_i
        @scope = options.fetch(:scope, :host).to_sym # Default to :host
        unless VALID_SCOPES.include?(@scope)
          raise ArgumentError, "Invalid scope: #{@scope}. Valid scopes are: #{VALID_SCOPES.join(', ')}"
        end

        @web_client = HK::Web::Client.new

        @visited_urls = Set.new
        @links_to_crawl = Queue.new
        @found_links_set = Set.new
        @crawl_errors = []

        @links_to_crawl.push({ url: @initial_url.to_s, depth: 0 })
        
        if defined?(TTY::Color)
            @pastel = TTY::Color
        else 
            @pastel = Object.new # Fallback
            def @pastel.method_missing(*args, &block); args.first; end
            def @pastel.respond_to_missing?(method_name, include_private = false); true; end
        end
        # puts @pastel.cyan("HK::Web::Crawler initialized.") + " URL: " + @pastel.yellow.bold(@initial_url.to_s) + " Depth: #{@depth_limit}, Scope: #{@scope}"
      end

      def crawl
        while !@links_to_crawl.empty? && @visited_urls.size < @options.fetch(:max_pages, 1000)
          current_task = @links_to_crawl.pop
          url_to_crawl_str = current_task[:url]
          current_depth = current_task[:depth]

          next if @visited_urls.include?(url_to_crawl_str)
          if current_depth > @depth_limit
            next
          end

          @visited_urls.add(url_to_crawl_str)
          
          client_probe_options = {
            timeout: @options.fetch(:timeout, 5),
            headers: @options[:headers]
          }.compact

          page_data = @web_client.probe(url_to_crawl_str, client_probe_options)

          if page_data[:error]
            @crawl_errors << { url: url_to_crawl_str, error: page_data[:error] }
            next
          end

          unless page_data[:status_code] && (200..299).cover?(page_data[:status_code].to_i) && page_data[:body]
            @crawl_errors << { url: url_to_crawl_str, error: "Non-successful or no body (Status: #{page_data[:status_code]})" }
            next
          end
          
          content_type = page_data.dig(:raw_headers, 'content-type') || page_data.dig(:raw_headers, 'Content-Type') || ""
          unless content_type.include?('text/html')
            @crawl_errors << { url: url_to_crawl_str, error: "Skipping non-HTML content (Content-Type: #{content_type})" }
            next
          end

          html_doc = Nokogiri::HTML(page_data[:body])
          current_page_uri = URI.parse(url_to_crawl_str)

          html_doc.css('a[href]').each do |link_tag|
            href_value = link_tag['href']
            next if href_value.nil? || href_value.strip.empty? || href_value.start_with?('mailto:', 'tel:', 'javascript:', '#')

            begin
              absolute_url_obj = current_page_uri.merge(URI.parse(href_value.strip))
              absolute_url_obj.fragment = nil
              normalized_url_str = absolute_url_obj.normalize.to_s
            rescue URI::InvalidURIError
              next
            end

            # Use the new _in_scope? method
            if _in_scope?(absolute_url_obj) # Pass URI object
              @found_links_set.add(normalized_url_str) 
              if !@visited_urls.include?(normalized_url_str) && (current_depth + 1 <= @depth_limit)
                @links_to_crawl.push({ url: normalized_url_str, depth: current_depth + 1 })
              end
            end
          end
        end
        
        {
          initial_url: @initial_url_str,
          crawled_count: @visited_urls.size,
          found_links_count: @found_links_set.size,
          found_links: @found_links_set.to_a.sort,
          errors: @crawl_errors
        }
      end
      
      def self.normalize_url(url_string)
        return nil if url_string.nil? || url_string.strip.empty?
        uri = URI.parse(url_string.strip)
        uri.scheme = 'http' if uri.scheme.nil?
        uri.path = '/' if uri.path.nil? || uri.path.empty? 
        uri.normalize.to_s # Return string
      rescue URI::InvalidURIError
        nil
      end

      private

      def _in_scope?(url_obj_to_check)
        return false unless url_obj_to_check.is_a?(URI) # Ensure we have a URI object

        case @scope
        when :host
          url_obj_to_check.host == @initial_url.host
        when :subdomain
          # Ends with .initial_domain or is initial_domain
          # e.g. initial: example.com, checks: sub.example.com, example.com
          # initial_domain_parts = @initial_url.host.split('.').last(2).join('.') # Simplistic, fails for .co.uk
          # A more robust way is to check if url_obj_to_check.host ends with ".#{@initial_url.host}"
          # or is equal to @initial_url.host. This handles subdomains correctly.
          # For example, if initial is "a.b.com", "x.a.b.com" is a subdomain. "b.com" is not.
          # If initial is "b.com", "a.b.com" is a subdomain.
          #
          # A common way to get "domain" part is to use a list of TLDs or a library.
          # For simplicity here: initial_host is a.b.c. Check host must be x.a.b.c or a.b.c
          # Or if initial_host is b.c, check host must be x.b.c or b.c
          # This means check_host must end with ".<initial_host_parent_domain>" or be <initial_host> or be <initial_host_parent_domain>
          # This logic is tricky. A simpler approach for this context:
          # Check if url_obj_to_check.host is identical to @initial_url.host OR
          # ends with a dot followed by @initial_url.host.
          # e.g. initial: example.com. Check: sub.example.com (true), example.com (true), badexample.com (false)
          url_obj_to_check.host == @initial_url.host || url_obj_to_check.host&.end_with?(".#{@initial_url.host}")
        when :path
          # Same scheme, host, port, and path starts with initial path
          # e.g. initial: http://ex.com/blog/. Checks: http://ex.com/blog/post1 (true), http://ex.com/other (false)
          (url_obj_to_check.scheme == @initial_url.scheme &&
           url_obj_to_check.host == @initial_url.host &&
           url_obj_to_check.port == @initial_url.port &&
           url_obj_to_check.path.start_with?(@initial_url.path))
        when :domain # More permissive: subdomains and parent domain (if initial was a subdomain)
          # For example, if initial_url is sub.example.com,
          # then example.com, another.sub.example.com, and sub.example.com are in scope.
          # This requires extracting the "registrable domain" (e.g., example.com from sub.example.com)
          # This is complex without a proper TLD list/library (like public_suffix gem).
          # Simplified: allow same host, subdomains of initial, or if initial is subdomain, allow parent.
          # For now, let's make :domain behave like :subdomain for simplicity, can be enhanced later.
          url_obj_to_check.host == @initial_url.host || url_obj_to_check.host&.end_with?(".#{@initial_url.host}")
        else
          false # Should not happen due to validation in initialize
        end
      end
    end
  end
end
