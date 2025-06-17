require 'spec_helper'
require 'hk/subdomain_finder' # This should also load hk/web/client
require 'json'

RSpec.describe HK::SubdomainFinder do
  let(:valid_domain) { "example.com" }
  let(:crtsh_base_url) { "https://crt.sh/" }

  # Mock HK::Web::Client instance or stub its probe method
  let(:mock_web_client) { instance_double(HK::Web::Client) }

  before(:each) do
    # Allow HK::Web::Client.new to return our mock_web_client
    # This is a common way to inject a mock dependency.
    # The SubdomainFinder creates its own WebClient, so we need to intercept that.
    allow(HK::Web::Client).to receive(:new).and_return(mock_web_client)
  end

  describe ".sanitize_domain" do
    it "extracts domain from simple hostname" do
      expect(HK::SubdomainFinder.sanitize_domain("example.com")).to eq("example.com")
    end
    it "extracts domain from URL with http" do
      expect(HK::SubdomainFinder.sanitize_domain("http://example.com/path")).to eq("example.com")
    end
    it "extracts domain from URL with https and www" do
      expect(HK::SubdomainFinder.sanitize_domain("https://www.example.com")).to eq("example.com")
    end
    it "handles domain with subdomains already, stripping www but keeping other subdomains" do
        # sanitize_domain's role is to get the "effective domain" for the crt.sh query (%.domain).
        # If "www.sub.example.com" is input, it should become "sub.example.com" for the query.
        # If "sub.example.com" is input, it should remain "sub.example.com".
        expect(HK::SubdomainFinder.sanitize_domain("foo.bar.example.com")).to eq("foo.bar.example.com")
        expect(HK::SubdomainFinder.sanitize_domain("www.foo.bar.example.com")).to eq("foo.bar.example.com")
    end
    it "returns nil for invalid domain strings" do
      expect(HK::SubdomainFinder.sanitize_domain("http://[invaliddomain].com")).to be_nil
      expect(HK::SubdomainFinder.sanitize_domain("justdomain")).to be_nil # No TLD
      expect(HK::SubdomainFinder.sanitize_domain("")).to be_nil
      expect(HK::SubdomainFinder.sanitize_domain(nil)).to be_nil
    end
  end

  describe "#initialize" do
    it "initializes with a valid domain" do
      # This test relies on the sanitize_domain method tested above.
      # If sanitize_domain("example.com") returns "example.com", then finder.domain should be "example.com".
      finder = HK::SubdomainFinder.new(valid_domain) # valid_domain is "example.com"
      expect(finder.domain).to eq(valid_domain)
      expect(finder.original_input).to eq(valid_domain)
    end
    it "initializes with a complex URL, extracting the correct domain" do
        finder = HK::SubdomainFinder.new("https://www.sub.example.co.uk/path?q=1")
        expect(finder.domain).to eq("sub.example.co.uk") # www. is stripped
        expect(finder.original_input).to eq("https://www.sub.example.co.uk/path?q=1")
    end
    it "raises ArgumentError for an invalid domain" do
      expect { HK::SubdomainFinder.new("http://[baddomain]") }.to raise_error(ArgumentError, /Invalid domain or URL provided: 'http:\/\/\\[baddomain\\]'/)
    end
  end

  describe "#discover" do
    # finder needs to be re-initialized for each test if its internal state (like @domain) changes
    # or if we want to test initialization with different domains.
    # For these tests, valid_domain ("example.com") is used.
    let(:finder) { HK::SubdomainFinder.new(valid_domain) }
    let(:crtsh_query_url) { "#{crtsh_base_url}?q=%.#{valid_domain}&output=json" }

    it "fetches and processes subdomains from crt.sh" do
      crtsh_response_body = JSON.dump([
        { "name_value"=>"one.example.com\nwww.example.com" }, # Newline separated
        { "name_value"=>"two.example.com" },
        { "name_value"=>"*.wildcard.example.com" }, # Should be filtered
        { "name_value"=>"example.com" } # Should be filtered (base domain)
      ])
      allow(mock_web_client).to receive(:probe)
        .with(crtsh_query_url, instance_of(Hash))
        .and_return({ body: crtsh_response_body, error: nil, status_code: 200 })

      subdomains = finder.discover
      expect(subdomains).to match_array(["one.example.com", "two.example.com", "www.example.com"])
      expect(subdomains).not_to include("*.wildcard.example.com")
      expect(subdomains).not_to include("example.com")
    end

    it "returns an empty array if crt.sh returns empty JSON array" do
      allow(mock_web_client).to receive(:probe).with(crtsh_query_url, instance_of(Hash)).and_return({ body: "[]", error: nil, status_code: 200 })
      expect(finder.discover).to be_empty
    end

    it "returns an empty array and handles JSON parsing errors from crt.sh" do
      allow(mock_web_client).to receive(:probe).with(crtsh_query_url, instance_of(Hash)).and_return({ body: "this is not json", error: nil, status_code: 200 })
      # Expect no error to be raised from discover, and internal error to be handled gracefully.
      expect(finder.discover).to be_empty
    end

    it "returns an empty array if web client probe fails" do
      allow(mock_web_client).to receive(:probe).with(crtsh_query_url, instance_of(Hash)).and_return({ error: "Network timeout", body: nil, status_code: nil })
      expect(finder.discover).to be_empty
    end

    it "handles names with mixed case and ensures unique output" do
        crtsh_response_body = JSON.dump([
            { "name_value"=>"One.example.com\nWWW.example.com" }, # Mixed case and newline
            { "name_value"=>"one.example.com" } # Duplicate after case normalization
        ])
        allow(mock_web_client).to receive(:probe)
            .with(crtsh_query_url, instance_of(Hash))
            .and_return({ body: crtsh_response_body, error: nil, status_code: 200 })
        subdomains = finder.discover
        expect(subdomains).to match_array(["one.example.com", "www.example.com"]) # Sorted and unique
    end
  end
end
