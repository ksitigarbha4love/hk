require 'set'
require 'uri'
require 'nokogiri'
require 'thread'
require 'robots'

module HK
  module Web
    class Crawler
      attr_reader :initial_url_str, :initial_url, :options, :visited_urls, :depth_limit, :web_client, :scope, :threads, :robots_rules

      VALID_SCOPES = [:host, :subdomain, :path, :domain].freeze

      def initialize(initial_url, options = {})
        @initial_url_str = initial_url
        normalized_url_string = self.class.normalize_url(initial_url_str)
        unless normalized_url_string
          # Error already logged by normalize_url if needed, or raise here
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
        @respect_robots_txt = options.fetch(:respect_robots_txt, true)

        @web_client = HK::Web::Client.new

        @visited_urls = Set.new
        @links_to_crawl = Queue.new
        @found_links_set = Set.new
        @crawl_errors = []
        @mutex = Mutex.new
        @robots_rules = nil

        # @pastel removed, using HK.logger

        HK.logger.debug "HK::Web::Crawler initialized. URL: '#{@initial_url.to_s}', Depth: #{@depth_limit}, Scope: #{@scope}, Threads: #{@threads}, Robots: #{@respect_robots_txt}"
        _fetch_and_parse_robots_txt if @respect_robots_txt

        @links_to_crawl.push({ url: @initial_url.to_s, depth: 0 })
      end

      def crawl(progress_bar = nil)
        HK.logger.info "Crawler starting. Target: '#{@initial_url_str}', Max Depth: #{@depth_limit}, Scope: #{@scope}, Threads: #{@threads}"
        worker_threads = []; @active_threads = 0
        @threads.times do
          worker_threads << Thread.new do
            begin
              loop do
                current_task = nil; begin; current_task = @links_to_crawl.pop(true); rescue ThreadError; @mutex.synchronize { break if @active_threads == 0 && @links_to_crawl.empty? }; Thread.pass; next; end
                @mutex.synchronize { @active_threads += 1 }
                url_to_crawl_str = current_task[:url]; current_depth = current_task[:depth]
                should_skip = false; skip_reason = ""

                @mutex.synchronize do
                  if @visited_urls.include?(url_to_crawl_str)
                    should_skip = true; skip_reason = "already visited"
                  elsif current_depth > @depth_limit
                    should_skip = true; skip_reason = "depth limit exceeded"
                  elsif @visited_urls.size >= @options.fetch(:max_pages, 1000)
                    should_skip = true; skip_reason = "max pages limit reached"
                    # Potentially signal other threads to stop by closing queue or setting a flag
                    @links_to_crawl.close unless @links_to_crawl.closed? # Close queue to stop other threads from blocking on pop
                  else
                    @visited_urls.add(url_to_crawl_str)
                  end
                end

                if should_skip
                  HK.logger.debug "Skipping #{url_to_crawl_str}: #{skip_reason}"
                  progress_bar&.advance # Advance even if skipped, as it was pulled from queue
                  @mutex.synchronize { @active_threads -= 1 }
                  next
                end

                HK.logger.debug "Crawling [D#{current_depth}, T#{Thread.current.object_id}]: #{url_to_crawl_str}"
                progress_bar&.increment # Use increment instead of advance if total is not fixed or can change
                                        # Or, if bar total is initial queue size, advance is fine.
                                        # The CLI sets total to max_pages or nil. If nil, advance is fine.
                                        # If max_pages, advance is also fine.

                client_probe_options = { timeout: @options.fetch(:timeout, 5), headers: @options[:headers] }.compact
                page_data = @web_client.probe(url_to_crawl_str, client_probe_options)

                if page_data[:error]; @mutex.synchronize { @crawl_errors << { url: url_to_crawl_str, error: page_data[:error] }; HK.logger.warn "Error fetching #{url_to_crawl_str}: #{page_data[:error]}" };
                elsif page_data[:status_code] && (200..299).cover?(page_data[:status_code].to_i) && page_data[:body]
                  content_type = page_data.dig(:raw_headers, 'content-type') || page_data.dig(:raw_headers, 'Content-Type') || ""
                  if content_type.include?('text/html')
                    html_doc = Nokogiri::HTML(page_data[:body]); current_page_uri = URI.parse(url_to_crawl_str)
                    links_on_page = 0
                    html_doc.css('a[href]').each do |link_tag|
                      href_value = link_tag['href']; next if href_value.nil? || href_value.strip.empty? || href_value.start_with?('mailto:', 'tel:', 'javascript:', '#')
                      begin; absolute_url_obj = current_page_uri.merge(URI.parse(href_value.strip)); absolute_url_obj.fragment = nil; normalized_url_str = absolute_url_obj.normalize.to_s; rescue URI::InvalidURIError; next; end

                      if _in_scope?(absolute_url_obj) && _is_allowed_by_robots?(normalized_url_str)
                        links_on_page += 1
                        @mutex.synchronize { @found_links_set.add(normalized_url_str) }
                        @mutex.synchronize do
                          if !@visited_urls.include?(normalized_url_str) && (current_depth + 1 <= @depth_limit)
                            @links_to_crawl.push({ url: normalized_url_str, depth: current_depth + 1 })
                            HK.logger.debug "  Queued [D#{current_depth + 1}]: #{normalized_url_str}"
                          end
                        end
                      else
                        # HK.logger.debug "  Skipped (out of scope or disallowed): #{normalized_url_str}"
                      end
                    end
                    HK.logger.debug "  Parsed #{links_on_page} in-scope/allowed links from #{url_to_crawl_str}"
                  else @mutex.synchronize { @crawl_errors << { url: url_to_crawl_str, error: "Skipping non-HTML content (Content-Type: #{content_type})" }; HK.logger.debug "  Skipping non-HTML: #{url_to_crawl_str} (Content-Type: #{content_type})" }; end
                else @mutex.synchronize { @crawl_errors << { url: url_to_crawl_str, error: "Non-successful or no body (Status: #{page_data[:status_code]})" }; HK.logger.debug "  Non-successful/no body: #{url_to_crawl_str} (Status: #{page_data[:status_code]})"}; end
                @mutex.synchronize { @active_threads -= 1 }
              end
            rescue => e; @mutex.synchronize { @crawl_errors << { url: "Thread error", error: "#{e.class.name}: #{e.message} - #{e.backtrace.first(3).join('; ')}" }; HK.logger.error "Thread error: #{e.message}"; @active_threads -= 1 if @active_threads && @active_threads > 0 }; end
          end
        end
        worker_threads.each(&:join); progress_bar&.finish
        HK.logger.info "Crawler finished. Visited: #{@visited_urls.size}, Found: #{@found_links_set.size}, Errors: #{@crawl_errors.size}"
        { initial_url: @initial_url_str, crawled_count: @visited_urls.size, found_links_count: @found_links_set.size, found_links: @found_links_set.to_a.sort, errors: @crawl_errors }
      end

      def self.normalize_url(url_string); return nil if url_string.nil? || url_string.strip.empty?; uri = URI.parse(url_string.strip); uri.scheme = 'http' if uri.scheme.nil?; uri.path = '/' if uri.path.nil? || uri.path.empty?; uri.normalize.to_s; rescue URI::InvalidURIError => e; HK.logger.warn "Invalid URL for normalization '#{url_string}': #{e.message}"; nil; end

      private

      def _fetch_and_parse_robots_txt
        robots_url = @initial_url.merge("/robots.txt").to_s
        HK.logger.debug "Fetching robots.txt from: #{robots_url}"
        probe_options = { timeout: 5, headers: {'User-Agent' => HK::Web::Client::DEFAULT_USER_AGENT} }
        response = @web_client.probe(robots_url, probe_options)
        if response[:error] || !(200..299).cover?(response[:status_code].to_i) || response[:body].nil? || response[:body].empty?
          HK.logger.warn "Could not fetch or got empty robots.txt (Status: #{response[:status_code]}, Error: #{response[:error]}). Allowing all paths."
          @robots_rules = nil; return
        end
        begin
          @robots_rules = Robots.parse(response[:body])
          HK.logger.info "Successfully fetched and parsed robots.txt from #{robots_url}"
        rescue => e
          HK.logger.warn "Error parsing robots.txt from #{robots_url}: #{e.message}. Allowing all paths."
          @robots_rules = nil
        end
      end

      def _is_allowed_by_robots?(url_string)
        return true unless @respect_robots_txt && @robots_rules
        allowed = @robots_rules.allowed?(url_string, HK::Web::Client::DEFAULT_USER_AGENT)
        HK.logger.debug "Robots check for '#{url_string}': #{allowed ? 'Allowed' : 'Disallowed'}" unless allowed # Log only disallowed for brevity
        allowed
      rescue StandardError => e
        HK.logger.warn "Error checking robots.txt allowance for #{url_string}: #{e.message}. Allowing path."
        true
      end

      def _in_scope?(url_obj_to_check)
        return false unless url_obj_to_check.is_a?(URI)
        in_scope_result = case @scope
                          when :host; url_obj_to_check.host == @initial_url.host
                          when :subdomain; url_obj_to_check.host == @initial_url.host || url_obj_to_check.host&.end_with?(".#{@initial_url.host}")
                          when :path; (url_obj_to_check.scheme == @initial_url.scheme && url_obj_to_check.host == @initial_url.host && url_obj_to_check.port == @initial_url.port && url_obj_to_check.path.start_with?(@initial_url.path))
                          when :domain; url_obj_to_check.host == @initial_url.host || url_obj_to_check.host&.end_with?(".#{@initial_url.host}")
                          else false
                          end
        # HK.logger.debug "Scope check for '#{url_obj_to_check.to_s}' against '#{@initial_url.to_s}' (scope: #{@scope}): #{in_scope_result}" unless in_scope_result
        in_scope_result
      end
    end
  end
end
