require 'set'
require 'uri'
require 'nokogiri'
require 'thread'
require 'robots' # For robots.txt parsing

module HK
  module Web
    class Crawler
      attr_reader :initial_url_str, :initial_url, :options, :visited_urls, :depth_limit, :web_client, :scope, :threads, :robots_rules

      VALID_SCOPES = [:host, :subdomain, :path, :domain].freeze

      def initialize(initial_url, options = {})
        @initial_url_str = initial_url
        normalized_url_string = self.class.normalize_url(initial_url_str)
        unless normalized_url_string
          raise ArgumentError, "Invalid initial URL: #{initial_url_str}"
        end
        @initial_url = URI.parse(normalized_url_string)

        @options = options
        @depth_limit = options.fetch(:depth, 2).to_i
        @scope = options.fetch(:scope, :host).to_sym
        unless VALID_SCOPES.include?(@scope)
          raise ArgumentError, "Invalid scope: #{@scope}. Valid scopes are: #{VALID_SCOPES.join(', ')}"
        end
        @threads = options.fetch(:threads, 5).to_i.clamp(1,100)
        @respect_robots_txt = options.fetch(:respect_robots_txt, true) # New option

        @web_client = HK::Web::Client.new

        @visited_urls = Set.new
        @links_to_crawl = Queue.new
        @found_links_set = Set.new
        @crawl_errors = []
        @mutex = Mutex.new
        @robots_rules = nil # Will store parsed robots.txt rules

        if defined?(TTY::Color); @pastel = TTY::Color; else; @pastel = Object.new; def @pastel.method_missing(*a,&b); a.first; end; end

        _fetch_and_parse_robots_txt if @respect_robots_txt

        @links_to_crawl.push({ url: @initial_url.to_s, depth: 0 })
        # puts @pastel.cyan("HK::Web::Crawler initialized.") # ... (existing puts)
      end

      def crawl
        worker_threads = []; @active_threads = 0
        @threads.times do
          worker_threads << Thread.new do
            begin
              loop do
                current_task = nil; begin; current_task = @links_to_crawl.pop(true); rescue ThreadError; @mutex.synchronize { break if @active_threads == 0 && @links_to_crawl.empty? }; Thread.pass; next; end
                @mutex.synchronize { @active_threads += 1 }
                url_to_crawl_str = current_task[:url]; current_depth = current_task[:depth]
                should_skip = false
                @mutex.synchronize do
                  if @visited_urls.include?(url_to_crawl_str) || current_depth > @depth_limit || @visited_urls.size >= @options.fetch(:max_pages, 1000)
                    should_skip = true
                  else
                    @visited_urls.add(url_to_crawl_str)
                  end
                end
                @options[:progress_bar]&.advance if !should_skip # Advance bar if processing
                if should_skip; @mutex.synchronize { @active_threads -= 1 }; next; end

                client_probe_options = { timeout: @options.fetch(:timeout, 5), headers: @options[:headers] }.compact
                page_data = @web_client.probe(url_to_crawl_str, client_probe_options)

                if page_data[:error]; @mutex.synchronize { @crawl_errors << { url: url_to_crawl_str, error: page_data[:error] } };
                elsif page_data[:status_code] && (200..299).cover?(page_data[:status_code].to_i) && page_data[:body]
                  content_type = page_data.dig(:raw_headers, 'content-type') || page_data.dig(:raw_headers, 'Content-Type') || ""
                  if content_type.include?('text/html')
                    html_doc = Nokogiri::HTML(page_data[:body]); current_page_uri = URI.parse(url_to_crawl_str)
                    html_doc.css('a[href]').each do |link_tag|
                      href_value = link_tag['href']; next if href_value.nil? || href_value.strip.empty? || href_value.start_with?('mailto:', 'tel:', 'javascript:', '#')
                      begin; absolute_url_obj = current_page_uri.merge(URI.parse(href_value.strip)); absolute_url_obj.fragment = nil; normalized_url_str = absolute_url_obj.normalize.to_s; rescue URI::InvalidURIError; next; end
                      if _in_scope?(absolute_url_obj) && _is_allowed_by_robots?(normalized_url_str) # Check robots.txt
                        @mutex.synchronize { @found_links_set.add(normalized_url_str) }
                        @mutex.synchronize do
                          if !@visited_urls.include?(normalized_url_str) && (current_depth + 1 <= @depth_limit)
                            @links_to_crawl.push({ url: normalized_url_str, depth: current_depth + 1 })
                          end
                        end
                      end
                    end
                  else @mutex.synchronize { @crawl_errors << { url: url_to_crawl_str, error: "Skipping non-HTML content (Content-Type: #{content_type})" } }; end
                else @mutex.synchronize { @crawl_errors << { url: url_to_crawl_str, error: "Non-successful or no body (Status: #{page_data[:status_code]})" } }; end
                @mutex.synchronize { @active_threads -= 1 }
              end # loop
            rescue => e; @mutex.synchronize { @crawl_errors << { url: "Thread error", error: "#{e.class.name}: #{e.message} - #{e.backtrace.first(3).join('; ')}" }; @active_threads -= 1 if @active_threads && @active_threads > 0 }; end
          end
        end
        worker_threads.each(&:join); @options[:progress_bar]&.finish
        { initial_url: @initial_url_str, crawled_count: @visited_urls.size, found_links_count: @found_links_set.size, found_links: @found_links_set.to_a.sort, errors: @crawl_errors }
      end

      def self.normalize_url(url_string); return nil if url_string.nil? || url_string.strip.empty?; uri = URI.parse(url_string.strip); uri.scheme = 'http' if uri.scheme.nil?; uri.path = '/' if uri.path.nil? || uri.path.empty?; uri.normalize.to_s; rescue URI::InvalidURIError; nil; end

      private

      def _fetch_and_parse_robots_txt
        robots_url = @initial_url.merge("/robots.txt").to_s
        # puts @pastel.dim("  Fetching robots.txt from: #{robots_url}")

        # Use a short timeout for robots.txt, don't pass crawler's main page timeout
        probe_options = { timeout: 5, headers: {'User-Agent' => HK::Web::Client::DEFAULT_USER_AGENT} }
        response = @web_client.probe(robots_url, probe_options)

        if response[:error] || !(200..299).cover?(response[:status_code].to_i) || response[:body].nil? || response[:body].empty?
          # puts @pastel.yellow("    Could not fetch or got empty robots.txt (Status: #{response[:status_code]}, Error: #{response[:error]}). Allowing all paths.")
          @robots_rules = nil # Explicitly nil, meaning allow all
          return
        end

        begin
          @robots_rules = Robots.parse(response[:body])
          # puts @pastel.dim("    Successfully parsed robots.txt")
        rescue => e
          # puts @pastel.yellow("    Error parsing robots.txt: #{e.message}. Allowing all paths.")
          @robots_rules = nil # On parse error, allow all
        end
      end

      def _is_allowed_by_robots?(url_string)
        return true unless @respect_robots_txt && @robots_rules
        @robots_rules.allowed?(url_string, HK::Web::Client::DEFAULT_USER_AGENT)
      rescue StandardError => e # Catch any error from robots gem itself
        # puts @pastel.yellow("    Error checking robots.txt allowance for #{url_string}: #{e.message}. Allowing path.")
        true # Default to allowing if robots gem has an issue
      end

      def _in_scope?(url_obj_to_check) # Logic from turn 155
        return false unless url_obj_to_check.is_a?(URI); case @scope; when :host; url_obj_to_check.host == @initial_url.host; when :subdomain; url_obj_to_check.host == @initial_url.host || url_obj_to_check.host&.end_with?(".#{@initial_url.host}"); when :path; (url_obj_to_check.scheme == @initial_url.scheme && url_obj_to_check.host == @initial_url.host && url_obj_to_check.port == @initial_url.port && url_obj_to_check.path.start_with?(@initial_url.path)); when :domain; url_obj_to_check.host == @initial_url.host || url_obj_to_check.host&.end_with?(".#{@initial_url.host}"); else; false; end
      end
    end
  end
end
