require 'spec_helper'
require 'hk/web/crawler'

RSpec.describe HK::Web::Crawler do
  let(:base_url) { "http://example.com" } 
  # HK::Web::Crawler.normalize_url returns string with trailing slash if host-only
  let(:normalized_base_url) { HK::Web::Crawler.normalize_url(base_url) } 

  before(:each) do
    # WebMock is enabled via spec_helper.rb and reset after each test
  end

  describe ".normalize_url" do
    it "adds http scheme to URLs without one" do
      expect(HK::Web::Crawler.normalize_url("example.com/path")).to eq("http://example.com/path")
    end
    it "preserves https scheme" do
      expect(HK::Web::Crawler.normalize_url("https://secure.com")).to eq("https://secure.com/")
    end
    it "normalizes path" do
      expect(HK::Web::Crawler.normalize_url("http://ex.com/a/./b/../c")).to eq("http://ex.com/a/c")
    end
    it "adds a trailing slash to host-only URLs" do
        expect(HK::Web::Crawler.normalize_url("http://onlyhost.com")).to eq("http://onlyhost.com/")
    end
    it "returns nil for invalid URIs" do
        expect(HK::Web::Crawler.normalize_url("http://[invalid].com")).to be_nil
    end
     it "returns nil for empty or nil URIs" do
        expect(HK::Web::Crawler.normalize_url("")).to be_nil
        expect(HK::Web::Crawler.normalize_url(nil)).to be_nil
    end
  end

  describe "#initialize" do
    it "normalizes the initial URL and stores it as a URI object" do # Updated description
      crawler = HK::Web::Crawler.new("example.com/path")
      # The HK::Web::Crawler from turn 149 stores @initial_url as a URI object
      expect(crawler.initial_url).to be_a(URI)
      expect(crawler.initial_url.to_s).to eq("http://example.com/path")
    end
    it "raises ArgumentError for invalid initial URL" do
      expect { HK::Web::Crawler.new("http://[invalid].com") }.to raise_error(ArgumentError, /Invalid initial URL/)
    end
  end

  describe "#crawl" do
    # --- Test Basic Crawling & Link Extraction ---
    it "crawls a single page and extracts links within scope" do
      stub_request(:get, normalized_base_url) # http://example.com/
        .to_return(status: 200, body: %(
          <html><body>
            <a href="/page1">Page 1</a>
            <a href="http://example.com/page2">Page 2</a>
            <a href="http://otherexample.com/page3">Other Site</a>
            <a href="mailto:test@example.com">Mail Me</a>
          </body></html>
        ), headers: {'Content-Type'=>'text/html'})
      
      # Stub linked pages to prevent further crawling for this simple test (depth 0)
      stub_request(:get, "#{normalized_base_url}page1").to_return(status: 404)
      stub_request(:get, "#{normalized_base_url}page2").to_return(status: 404)

      crawler = HK::Web::Crawler.new(base_url, depth: 0)
      results = crawler.crawl
      
      expect(results[:crawled_count]).to eq(1)
      expect(results[:found_links]).to include("#{normalized_base_url}page1")
      expect(results[:found_links]).to include("#{normalized_base_url}page2")
      expect(results[:found_links]).not_to include("http://otherexample.com/page3")
      expect(results[:found_links]).not_to include("mailto:test@example.com")
      expect(results[:found_links_count]).to eq(2)
    end

    # --- Test Depth Limit ---
    it "respects depth limit 0 (only crawls initial URL)" do
      stub_request(:get, normalized_base_url)
        .to_return(status: 200, body: '<a href="/page1">Page 1</a>', headers: {'Content-Type'=>'text/html'})
      # No need to stub /page1 as it shouldn't be crawled at depth 0 for links
      
      crawler = HK::Web::Crawler.new(base_url, depth: 0)
      results = crawler.crawl
      
      expect(results[:crawled_count]).to eq(1) # Only initial URL
      expect(results[:found_links]).to include("#{normalized_base_url}page1")
    end

    it "respects depth limit 1" do
      stub_request(:get, normalized_base_url)
        .to_return(status: 200, body: '<a href="/page1">Page 1</a>', headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{normalized_base_url}page1")
        .to_return(status: 200, body: '<a href="/page2">Page 2</a>', headers: {'Content-Type'=>'text/html'})
      # No need to stub /page2 as it shouldn't be crawled for links at depth 1 from /page1

      crawler = HK::Web::Crawler.new(base_url, depth: 1)
      results = crawler.crawl

      expect(results[:crawled_count]).to eq(2) # initial_url + /page1
      expect(results[:found_links]).to include("#{normalized_base_url}page1")
      expect(results[:found_links]).to include("#{normalized_base_url}page2") # Found, but not crawled for its links
    end

    # --- Test Scope Control (Same Host) ---
    it "only crawls links on the same host as the initial URL" do
      stub_request(:get, normalized_base_url)
        .to_return(status: 200, body: '<a href="http://external.com/ext">External</a> <a href="/internal">Internal</a>', headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{normalized_base_url}internal") # Should be crawled
        .to_return(status: 200, body: "Internal Page", headers: {'Content-Type'=>'text/html'})
      # external.com should not be stubbed as it shouldn't be requested

      crawler = HK::Web::Crawler.new(base_url, depth: 1)
      results = crawler.crawl
      
      expect(results[:crawled_count]).to eq(2) # initial_url + /internal
      expect(results[:found_links]).to include("#{normalized_base_url}internal")
      expect(results[:found_links]).not_to include("http://external.com/ext")
    end

    # --- Test Error Handling ---
    it "handles errors when fetching a page and continues" do
      stub_request(:get, normalized_base_url)
        .to_return(status: 200, body: '<a href="/good_page">Good</a> <a href="/bad_page">Bad</a>', headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{normalized_base_url}good_page")
        .to_return(status: 200, body: "Good Content", headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{normalized_base_url}bad_page")
        .to_return(status: 500, body: "Server Error") # HK::Web::Client returns error:nil for this

      crawler = HK::Web::Crawler.new(base_url, depth: 1)
      results = crawler.crawl
      
      expect(results[:crawled_count]).to eq(3) # initial, good_page, bad_page (attempted)
      expect(results[:found_links]).to include("#{normalized_base_url}good_page")
      expect(results[:found_links]).to include("#{normalized_base_url}bad_page") # bad_page is found, but fetch results in error
      expect(results[:errors].size).to eq(1)
      expect(results[:errors].first[:url]).to eq("#{normalized_base_url}bad_page")
      # The HK::Web::Client's probe method returns status_code 500, error: nil
      # The crawler's logic: unless page_data[:status_code] && (200..299) ... error: "Non-HTML or no body (Status: 500)"
      expect(results[:errors].first[:error]).to include("Non-HTML or no body (Status: 500)")
    end

    # --- Test Visited URL Tracking ---
    it "does not crawl already visited URLs (even if linked again)" do
      stub_request(:get, normalized_base_url)
        .to_return(status: 200, body: '<a href="/page1">Page 1</a> <a href="/page1#again">Page 1 Again</a>', headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{normalized_base_url}page1") # Requested only once
        .to_return(status: 200, body: '<a href="/">Home</a>', headers: {'Content-Type'=>'text/html'}).times(1)

      crawler = HK::Web::Crawler.new(base_url, depth: 1)
      results = crawler.crawl
      
      expect(results[:crawled_count]).to eq(2) # initial_url + /page1
    end
    
    it "handles relative links correctly" do
      # Initial URL for this test: http://example.com/path1/
      start_url = "#{base_url}/path1/" 
      normalized_start_url = HK::Web::Crawler.normalize_url(start_url) # http://example.com/path1/
      
      stub_request(:get, normalized_start_url)
        .to_return(status: 200, body: '<a href="sub_page.html">Sub Page</a> <a href="../another_page.html">Another Page</a>', headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{normalized_base_url}path1/sub_page.html").to_return(status: 200, body: "Sub", headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{normalized_base_url}another_page.html").to_return(status: 200, body: "Another", headers: {'Content-Type'=>'text/html'})

      crawler = HK::Web::Crawler.new(start_url, depth: 1)
      results = crawler.crawl

      expect(results[:crawled_count]).to eq(3) # start_url, sub_page.html, another_page.html
      expect(results[:found_links]).to include("#{normalized_base_url}path1/sub_page.html")
      expect(results[:found_links]).to include("#{normalized_base_url}another_page.html")
    end
  end
end
