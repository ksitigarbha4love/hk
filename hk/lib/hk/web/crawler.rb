require 'set'
require 'uri'
require 'nokogiri' # Added
# require_relative 'client' # HK::Web::Client should be available via load path

module HK
  module Web
    class Crawler
      attr_reader :initial_url, :options, :visited_urls, :depth_limit, :web_client # Removed initial_url_str

      def initialize(initial_url_str, options = {}) # Changed param name for clarity
        @initial_url = self.class.normalize_url(initial_url_str) # Store normalized string
        unless @initial_url
          raise ArgumentError, "Invalid initial URL: #{initial_url_str}"
        end
        
        @options = options
        @depth_limit = options.fetch(:depth, 2).to_i
        @web_client = HK::Web::Client.new # Instantiate client once

        @visited_urls = Set.new
        @links_to_crawl = Queue.new
        @found_links_set = Set.new # To store all unique valid links found
        @crawl_errors = [] # To store errors encountered

        @links_to_crawl.push({ url: @initial_url, depth: 0 }) # Use string URL for queue
        
        @pastel = TTY::Color # As per prompt
        # puts @pastel.cyan("HK::Web::Crawler initialized.") + " URL: " + @pastel.yellow.bold(@initial_url) + " Depth: #{@depth_limit}"
      end

      def crawl
        # puts @pastel.dim("  Crawler: Starting crawl...")

        while !@links_to_crawl.empty?
          current_task = @links_to_crawl.pop
          url_to_crawl = current_task[:url]
          current_depth = current_task[:depth]

          next if @visited_urls.include?(url_to_crawl) 
          if current_depth > @depth_limit
            next
          end

          @visited_urls.add(url_to_crawl)
          
          client_probe_options = {
            timeout: @options[:timeout], 
            headers: @options[:headers]
          }.compact

          page_data = @web_client.probe(url_to_crawl, client_probe_options)

          if page_data[:error]
            @crawl_errors << { url: url_to_crawl, error: page_data[:error] }
            next
          end

          unless page_data[:status_code] && (200..299).cover?(page_data[:status_code].to_i) && page_data[:body]
            @crawl_errors << { url: url_to_crawl, error: "Non-HTML or no body (Status: #{page_data[:status_code]})" }
            next
          end
          
          html_doc = Nokogiri::HTML(page_data[:body])
          base_uri_for_resolve = URI.parse(url_to_crawl) # URI object for resolving

          html_doc.css('a[href]').each do |link_tag|
            href_value = link_tag['href']
            next if href_value.nil? || href_value.strip.empty? || href_value.start_with?('mailto:', 'tel:', 'javascript:')

            begin
              # Resolve and normalize the URL
              absolute_url_obj = base_uri_for_resolve.merge(URI.parse(href_value.strip))
              absolute_url = absolute_url_obj.normalize.to_s # Use normalized string
            rescue URI::InvalidURIError
              next
            end
            
            # Scope control: same host as initial_url (which is now a string)
            # To compare hosts, we need to parse @initial_url back to URI or compare string hosts.
            # Storing @initial_url as URI object in initialize is better for this.
            # Reverting that part from my previous implementation for consistency with prompt's class structure.
            # For now, let's parse @initial_url string to get its host for comparison.
            # This is slightly inefficient but matches the prompt's variable types.
            begin
              initial_uri_host = URI.parse(@initial_url).host
              new_uri_host = URI.parse(absolute_url).host # Re-parse absolute_url to get its host
            rescue URI::InvalidURIError
              next # If any URL is unparseable at this stage, skip
            end

            if new_uri_host == initial_uri_host
              @found_links_set.add(absolute_url) 
              if !@visited_urls.include?(absolute_url) && (current_depth + 1 <= @depth_limit)
                @links_to_crawl.push({ url: absolute_url, depth: current_depth + 1 })
              end
            end
          end
        end
        
        {
          initial_url: @initial_url, # Report the normalized initial URL string
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
    end
  end
end
