require 'spec_helper'
require 'hk/web/crawler'
require 'hk/web/client'
require 'robots' # For Robots.parse in tests

RSpec.describe HK::Web::Crawler do
  let(:base_url_str) { "http://robotstxt.example.com" } # Using a unique host for these tests
  let(:base_url_uri) { URI.parse(HK::Web::Crawler.normalize_url(base_url_str)) }
  let(:robots_txt_url) { "#{base_url_uri}robots.txt" }
  let(:mock_web_client_instance) { instance_double(HK::Web::Client) }

  before(:each) do
    # By default, allow Addrinfo for the test host
    allow(Addrinfo).to receive(:getaddrinfo).with(base_url_uri.host, nil, :INET, :STREAM).and_return([Addrinfo.tcp(base_url_uri.host, 0)])
    allow(Addrinfo).to receive(:getaddrinfo).with(base_url_uri.host, nil, :INET, :DGRAM).and_return([Addrinfo.udp(base_url_uri.host, 0)])

    # Stub HK::Web::Client.new to return our mock instance for all Crawler instances
    allow(HK::Web::Client).to receive(:new).and_return(mock_web_client_instance)

    # Default stub for robots.txt (allow all or not found)
    # Individual tests can override this.
    allow(mock_web_client_instance).to receive(:probe)
      .with(robots_txt_url, instance_of(Hash)) # Match any options hash for robots.txt
      .and_return({ status_code: 404, body: "Not Found", error: nil }) # Default: robots.txt not found
  end

  # --- Previous tests (URL normalization, basic init - condensed) ---
  describe ".normalize_url" do
    it "normalizes URLs correctly" do
      expect(HK::Web::Crawler.normalize_url("example.com/p")).to eq("http://example.com/p")
    end
  end
  describe "#initialize" do
    it "initializes with default respect_robots_txt = true" do
      # Expect _fetch_and_parse_robots_txt to be called
      # We can test this by checking if a probe for robots.txt was made.
      # Since HK::Web::Client.new is stubbed, we can set expectations on mock_web_client_instance.
      expect(mock_web_client_instance).to receive(:probe).with(robots_txt_url, instance_of(Hash)).and_return({status_code: 404})
      crawler = HK::Web::Crawler.new(base_url_str)
      expect(crawler.options[:respect_robots_txt]).to be true
      # expect(crawler.robots_rules).to be_nil # Because it was 404
    end
  end

  # --- New tests for robots.txt handling ---
  context "when handling robots.txt" do
    let(:user_agent) { HK::Web::Client::DEFAULT_USER_AGENT } # The UA used by the crawler

    it "fetches and parses robots.txt if respect_robots_txt is true" do
      robots_content = "User-agent: *\nDisallow: /private/\nAllow: /public/"
      allow(mock_web_client_instance).to receive(:probe)
        .with(robots_txt_url, instance_of(Hash))
        .and_return({ status_code: 200, body: robots_content, error: nil })

      crawler = HK::Web::Crawler.new(base_url_str, respect_robots_txt: true)
      expect(crawler.robots_rules).to be_a(Robots::Rules)
      # Test a specific rule (note: Robots gem API might vary slightly or need specific user agent)
      # The HK::Web::Crawler._is_allowed_by_robots? uses the DEFAULT_USER_AGENT
      expect(crawler.send(:_is_allowed_by_robots?, "#{base_url_uri}private/page")).to be false
      expect(crawler.send(:_is_allowed_by_robots?, "#{base_url_uri}public/page")).to be true
    end

    it "does not fetch robots.txt if respect_robots_txt is false" do
      # Ensure probe for robots.txt is NOT called if respect_robots_txt is false
      expect(mock_web_client_instance).not_to receive(:probe).with(robots_txt_url, any_args)
      crawler = HK::Web::Crawler.new(base_url_str, respect_robots_txt: false)
      expect(crawler.robots_rules).to be_nil
      expect(crawler.send(:_is_allowed_by_robots?, "#{base_url_uri}any/path")).to be true # Should allow all
    end

    it "allows all paths if robots.txt is not found (404)" do
      allow(mock_web_client_instance).to receive(:probe)
        .with(robots_txt_url, instance_of(Hash))
        .and_return({ status_code: 404, body: "Not Found", error: nil })
      crawler = HK::Web::Crawler.new(base_url_str) # respect_robots_txt defaults to true
      expect(crawler.robots_rules).to be_nil
      expect(crawler.send(:_is_allowed_by_robots?, "#{base_url_uri}some/path")).to be true
    end

    it "allows all paths if robots.txt fetch fails (e.g., network error)" do
      allow(mock_web_client_instance).to receive(:probe)
        .with(robots_txt_url, instance_of(Hash))
        .and_return({ error: "Connection timeout", status_code: nil, body: nil })
      crawler = HK::Web::Crawler.new(base_url_str)
      expect(crawler.robots_rules).to be_nil
      expect(crawler.send(:_is_allowed_by_robots?, "#{base_url_uri}some/path")).to be true
    end

    it "allows all paths if robots.txt is unparseable" do
      allow(mock_web_client_instance).to receive(:probe)
        .with(robots_txt_url, instance_of(Hash))
        .and_return({ status_code: 200, body: "This is not valid robots.txt content<<<<", error: nil })
      # The Robots.parse method might raise error or return a default "allow all" object.
      # The SUT's _fetch_and_parse_robots_txt rescues errors and sets @robots_rules to nil.
      crawler = HK::Web::Crawler.new(base_url_str)
      expect(crawler.robots_rules).to be_nil # Due to rescue in SUT
      expect(crawler.send(:_is_allowed_by_robots?, "#{base_url_uri}some/path")).to be true
    end

    context "during crawl operation" do
      let(:allowed_path) { "/allowed_page" }
      let(:disallowed_path) { "/disallowed_page" }
      let(:allowed_url) { "#{base_url_uri.to_s.chomp('/')}#{allowed_path}" }
      let(:disallowed_url) { "#{base_url_uri.to_s.chomp('/')}#{disallowed_path}" }

      before(:each) do
        robots_content = "User-agent: #{HK::Web::Client::DEFAULT_USER_AGENT}\nDisallow: #{disallowed_path}\n"
        allow(mock_web_client_instance).to receive(:probe)
          .with(robots_txt_url, instance_of(Hash))
          .and_return({ status_code: 200, body: robots_content, error: nil, raw_headers: {'Content-Type'=>'text/plain'} })

        # Stub the main page, linking to allowed and disallowed paths
        stub_request(:get, base_url_uri.to_s)
          .to_return(status: 200, body: %(
            <html><body>
              <a href="#{allowed_path}">Allowed Page</a>
              <a href="#{disallowed_path}">Disallowed Page</a>
            </body></html>
          ), headers: {'Content-Type'=>'text/html'})

        # Stub the allowed page (it should be requested)
        stub_request(:get, allowed_url)
          .to_return(status: 200, body: "Allowed content", headers: {'Content-Type'=>'text/html'})

        # The disallowed page should NOT be requested if robots.txt is respected
        # WebMock will raise an error if an unstubbed request is made.
      end

      it "respects robots.txt and does not crawl disallowed paths" do
        crawler = HK::Web::Crawler.new(base_url_str, depth: 1, threads: 1, respect_robots_txt: true)
        results = crawler.crawl

        expect(results[:crawled_count]).to eq(2) # Initial URL + allowed_path
        expect(results[:found_links]).to include(allowed_url)
        expect(results[:found_links]).not_to include(disallowed_url) # Not added to found_links_set for crawling
        # To be very sure, ensure no HTTP request was made to disallowed_url
        expect(WebMock).not_to have_requested(:get, disallowed_url)
      end

      it "ignores robots.txt if respect_robots_txt is false" do
        # Need to stub the disallowed_url for this test as it *will* be requested
        stub_request(:get, disallowed_url)
          .to_return(status: 200, body: "Disallowed content (but accessed)", headers: {'Content-Type'=>'text/html'})

        crawler = HK::Web::Crawler.new(base_url_str, depth: 1, threads: 1, respect_robots_txt: false)
        results = crawler.crawl

        expect(results[:crawled_count]).to eq(3) # Initial URL + allowed_path + disallowed_path
        expect(results[:found_links]).to include(allowed_url)
        expect(results[:found_links]).to include(disallowed_url)
        expect(WebMock).to have_requested(:get, disallowed_url)
      end
    end
  end
end
