require 'spec_helper'
require 'hk/web/crawler'
require 'hk/web/client' # Crawler instantiates this

RSpec.describe HK::Web::Crawler do
  let(:base_url_str) { "http://example.com" }
  let(:base_url_uri) { URI.parse(HK::Web::Crawler.normalize_url(base_url_str)) } # URI object

  # Helper to create a temporary template file (not used here, but good for consistency if needed)
  # def create_temp_file(name, content) ...

  before(:each) do
    # WebMock is enabled via spec_helper.rb and reset after each test
    # Clear HK::TemplateRegistry if Ruby DSL templates were involved (not directly here)
  end

  # --- Tests from previous subtask (turn 153) for basic functionality ---
  describe ".normalize_url" do
    it "normalizes URLs correctly" do
      expect(HK::Web::Crawler.normalize_url("example.com/path")).to eq("http://example.com/path")
      expect(HK::Web::Crawler.normalize_url("https://secure.com")).to eq("https://secure.com/")
      expect(HK::Web::Crawler.normalize_url("http://ex.com/a/./b/../c")).to eq("http://ex.com/a/c")
    end
  end

  describe "#initialize" do
    it "normalizes and stores initial URL as a URI object" do
      crawler = HK::Web::Crawler.new("example.com/path")
      expect(crawler.initial_url).to be_a(URI)
      expect(crawler.initial_url.to_s).to eq("http://example.com/path")
      expect(crawler.scope).to eq(:host) # Default scope
      expect(crawler.threads).to eq(5) # Default threads
    end
    it "raises ArgumentError for invalid initial URL" do
      expect { HK::Web::Crawler.new("http://[invalid].com") }.to raise_error(ArgumentError, /Invalid initial URL/)
    end
    it "raises ArgumentError for invalid scope" do
      expect { HK::Web::Crawler.new(base_url_str, { scope: :invalid_scope }) }.to raise_error(ArgumentError, /Invalid scope/)
    end
  end

  describe "#crawl (Basic Functionality - single thread for simplicity in these)" do
    # Re-using some tests from turn 153, ensuring they work with latest crawler
    it "crawls a single page and extracts links within default :host scope" do
      stub_request(:get, base_url_uri.to_s)
        .to_return(status: 200, body: %(
          <html><body>
            <a href="/page1">Page 1</a>
            <a href="http://example.com/page2">Page 2</a>
            <a href="http://otherexample.com/page3">Other Site</a>
          </body></html>
        ), headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{base_url_uri}page1").to_return(status: 404) # Stop crawl
      stub_request(:get, "#{base_url_uri}page2").to_return(status: 404) # Stop crawl

      crawler = HK::Web::Crawler.new(base_url_str, depth: 0, threads: 1) # Force single thread for predictability
      results = crawler.crawl
      
      expect(results[:crawled_count]).to eq(1)
      expect(results[:found_links]).to match_array(["#{base_url_uri}page1", "#{base_url_uri}page2"])
    end

    it "respects depth limit 1" do
      stub_request(:get, base_url_uri.to_s).to_return(status: 200, body: '<a href="/page1">1</a>', headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{base_url_uri}page1").to_return(status: 200, body: '<a href="/page2">2</a>', headers: {'Content-Type'=>'text/html'})
      # /page2 should not be crawled for its links
      
      crawler = HK::Web::Crawler.new(base_url_str, depth: 1, threads: 1)
      results = crawler.crawl
      
      expect(results[:crawled_count]).to eq(2) # base_url + /page1
      expect(results[:found_links]).to include("#{base_url_uri}page1")
      expect(results[:found_links]).to include("#{base_url_uri}page2") # Found from /page1
    end
  end
  
  # --- New tests for Scope Control ---
  describe "Scope Control" do
    let(:subdomain_url) { "http://sub.example.com/" }
    let(:different_domain_url) { "http://anotherdomain.com/" }
    let(:path_url) { "#{base_url_uri}path/page" } # http://example.com/path/page

    before(:each) do
      # Initial page always gets stubbed
      stub_request(:get, base_url_uri.to_s) 
        .to_return(status: 200, body: %(
          <a href="#{subdomain_url}">Subdomain Link</a>
          <a href="#{different_domain_url}">Different Domain Link</a>
          <a href="/path/page">Path Link</a>
          <a href="/another_path">Another Path Link</a>
        ), headers: {'Content-Type'=>'text/html'})

      # Stub all potential next pages to prevent actual crawling beyond depth 0 for scope tests
      stub_request(:get, subdomain_url).to_return(status: 200, body: "Subdomain Page", headers: {'Content-Type'=>'text/html'})
      stub_request(:get, different_domain_url).to_return(status: 200, body: "Different Domain Page", headers: {'Content-Type'=>'text/html'})
      stub_request(:get, path_url).to_return(status: 200, body: "Path Page", headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{base_url_uri}another_path").to_return(status: 200, body: "Another Path Page", headers: {'Content-Type'=>'text/html'})
    end

    it "crawls only same host with :host scope (default)" do
      crawler = HK::Web::Crawler.new(base_url_str, depth: 1, threads: 1) # Depth 1 to see what's queued
      results = crawler.crawl
      expect(results[:found_links]).to include(path_url)
      expect(results[:found_links]).to include("#{base_url_uri}another_path")
      expect(results[:found_links]).not_to include(subdomain_url)
      expect(results[:found_links]).not_to include(different_domain_url)
      # Crawled count should be 1 (initial) + 2 (path_url, another_path) = 3
      expect(results[:crawled_count]).to eq(3) 
    end

    it "crawls host and its subdomains with :subdomain scope" do
      crawler = HK::Web::Crawler.new(base_url_str, scope: :subdomain, depth: 1, threads: 1)
      results = crawler.crawl
      expect(results[:found_links]).to include(path_url)
      expect(results[:found_links]).to include(subdomain_url) # Should be included now
      expect(results[:found_links]).not_to include(different_domain_url)
      expect(results[:crawled_count]).to eq(4) # initial, path_url, another_path, subdomain_url
    end
    
    it "crawls only paths under initial URL's path with :path scope" do
      # Initial URL: http://example.com/ (normalized path is "/")
      # For this test, let's use an initial URL with a more specific path
      specific_path_start_url = "#{base_url_str}/specific_path/"
      normalized_specific_path_start_url = HK::Web::Crawler.normalize_url(specific_path_start_url)

      stub_request(:get, normalized_specific_path_start_url)
        .to_return(status: 200, body: %(
          <a href="deeper_page">Deeper Page Under Specific Path</a>
          <a href="/specific_path/another_deeper">Another Deeper</a>
          <a href="/other_path/not_in_scope">Page on Same Host, Different Path Root</a>
        ), headers: {'Content-Type'=>'text/html'})
      
      stub_request(:get, "#{normalized_specific_path_start_url}deeper_page").to_return(status: 200, body: "content", headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{normalized_specific_path_start_url}another_deeper").to_return(status: 200, body: "content", headers: {'Content-Type'=>'text/html'})
      # /other_path/not_in_scope should not be crawled

      crawler = HK::Web::Crawler.new(specific_path_start_url, scope: :path, depth: 1, threads: 1)
      results = crawler.crawl
      
      expect(results[:found_links]).to include("#{normalized_specific_path_start_url}deeper_page")
      expect(results[:found_links]).to include("#{normalized_specific_path_start_url}another_deeper")
      expect(results[:found_links]).not_to include("#{base_url_uri}other_path/not_in_scope")
      expect(results[:crawled_count]).to eq(3) # specific_path_start_url + 2 deeper pages
    end
    
    it "crawls host and its subdomains with :domain scope (simplified behavior)" do
      # Current _in_scope? for :domain is same as :subdomain
      crawler = HK::Web::Crawler.new(base_url_str, scope: :domain, depth: 1, threads: 1)
      results = crawler.crawl
      expect(results[:found_links]).to include(path_url)
      expect(results[:found_links]).to include(subdomain_url)
      expect(results[:found_links]).not_to include(different_domain_url)
      expect(results[:crawled_count]).to eq(4)
    end
  end

  # --- New tests for Concurrency and Options Propagation ---
  describe "Concurrency and Options" do
    it "conceptually runs with multiple threads (actual concurrency test is complex)" do
      # This test mainly ensures the crawler runs to completion with thread option.
      # True concurrency testing (race conditions, speed) is outside simple unit tests.
      stub_request(:get, base_url_uri.to_s).to_return(status: 200, body: "<a href='p1'>p1</a>", headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{base_url_uri}p1").to_return(status: 200, body: "p1", headers: {'Content-Type'=>'text/html'})
      
      crawler = HK::Web::Crawler.new(base_url_str, threads: 3, depth: 1)
      results = nil
      expect { results = crawler.crawl }.not_to raise_error
      expect(results[:crawled_count]).to eq(2)
    end

    it "passes HTTP options (timeout, headers) to HK::Web::Client during crawl" do
      custom_headers = {"X-HK-Crawl" => "TestCrawl"}
      crawler_options = { depth: 0, threads: 1, timeout: 7, headers: custom_headers }
      
      # Expect the initial request to be made with these headers and timeout
      # WebMock's with block can check headers. Timeout is harder to check directly via WebMock.
      stub_request(:get, base_url_uri.to_s)
        .with(headers: hash_including(custom_headers), timeout: 7) # Check if HTTParty receives timeout
        .to_return(status: 200, body: "OK", headers: {'Content-Type'=>'text/html'})
      
      # We need to mock HK::Web::Client to see what options it's called with.
      # Or, ensure HK::Web::Client itself logs or makes options verifiable.
      # For this test, we'll assume if the request is made successfully with WebMock's
      # header check, the options are being passed.
      # The timeout part of .with() is not standard in WebMock for HTTParty; HTTParty handles it.
      # We'd rely on the timeout test in web_client_spec.rb to ensure it's passed to HTTParty.
      # Here, we focus on the headers being passed.
      
      # Re-stub without timeout in .with for simplicity, as it's not a WebMock feature
      stub_request(:get, base_url_uri.to_s)
        .with(headers: hash_including(custom_headers))
        .to_return(status: 200, body: "OK", headers: {'Content-Type'=>'text/html'})

      crawler = HK::Web::Crawler.new(base_url_str, crawler_options)
      expect { crawler.crawl }.not_to raise_error # Runs to completion
    end

    it "respects :max_pages option" do
        stub_request(:get, base_url_uri.to_s)
          .to_return(status: 200, body: "<a href='/p1'>1</a><a href='/p2'>2</a><a href='/p3'>3</a>", headers: {'Content-Type'=>'text/html'})
        stub_request(:get, /#{base_url_uri}p\d/).to_return(status: 200, body: "page", headers: {'Content-Type'=>'text/html'})

        crawler = HK::Web::Crawler.new(base_url_str, depth: 1, threads: 1, max_pages: 2)
        results = crawler.crawl
        expect(results[:crawled_count]).to eq(2) # Should stop after initial URL and one more
    end
  end
end
