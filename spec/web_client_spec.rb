require 'spec_helper'
require 'hk/web/client' # Ensure TTY::Color is available or mock it if HK::Web::Client uses it directly

RSpec.describe HK::Web::Client do
  let(:client) { HK::Web::Client.new }
  let(:test_url) { "http://www.example.com" }
  let(:test_url_https) { "https://www.example.com" }

  before(:each) do
    # WebMock is enabled via spec_helper.rb
    # Stub common requests here if needed, or per test.
  end

  after(:each) do
    WebMock.reset! # Clean up stubs after each test
  end

  describe "#probe" do
    it "successfully probes a URL and extracts status code and title" do
      stub_request(:get, test_url)
        .to_return(status: 200, body: "<html><head><title>Test Title</title></head><body>Hello</body></html>", headers: {'Content-Type'=>'text/html'})

      result = client.probe(test_url)
      expect(result[:status_code]).to eq(200)
      expect(result[:title]).to eq("Test Title")
      expect(result[:error]).to be_nil
    end

    it "handles URLs without http:// prefix by defaulting to http" do
       stub_request(:get, test_url) # test_url is "http://www.example.com"
        .to_return(status: 200, body: "<html><title>Prefixed</title></html>")
      
      # The client's probe method itself adds "http://" if no scheme,
      # so webmock just needs to stub the full http URL.
      result = client.probe("www.example.com") 
      expect(result[:status_code]).to eq(200)
      expect(result[:title]).to eq("Prefixed")
    end
    
    it "correctly uses https for https URLs" do
       stub_request(:get, test_url_https)
        .to_return(status: 200, body: "<html><title>Secure Title</title></html>")
      result = client.probe(test_url_https)
      expect(result[:status_code]).to eq(200)
      expect(result[:title]).to eq("Secure Title")
    end

    it "returns the status code even if title is not found" do
      stub_request(:get, test_url).to_return(status: 200, body: "<html><body>No title here</body></html>")
      result = client.probe(test_url)
      expect(result[:status_code]).to eq(200)
      expect(result[:title]).to be_nil
    end

    it "handles HTTP errors (e.g., 404)" do
      stub_request(:get, test_url).to_return(status: 404, body: "Not Found")
      result = client.probe(test_url)
      expect(result[:status_code]).to eq(404)
      expect(result[:title]).to be_nil # Or based on actual 404 page body
      expect(result[:error]).to be_nil # HTTParty doesn't raise for 4xx/5xx by default
    end
    
    it "handles server errors (e.g., 500)" do
      stub_request(:get, test_url).to_return(status: 500, body: "Server Error")
      result = client.probe(test_url)
      expect(result[:status_code]).to eq(500)
      expect(result[:error]).to be_nil 
    end

    it "handles network errors (e.g., SocketError)" do
      stub_request(:get, test_url).to_raise(SocketError.new("Connection failed"))
      result = client.probe(test_url)
      expect(result[:status_code]).to be_nil
      expect(result[:title]).to be_nil
      expect(result[:error]).to include("SocketError: Connection failed")
    end

    it "handles HTTParty::Error" do
      stub_request(:get, test_url).to_raise(HTTParty::Error.new("HTTParty stuff failed"))
      result = client.probe(test_url)
      expect(result[:error]).to include("HTTParty::Error: HTTParty stuff failed")
    end
    
    it "respects the timeout option (conceptual via webmock)" do
      stub_request(:get, test_url).to_timeout # Simulate a timeout
      result = client.probe(test_url, { timeout: 1 }) # HTTParty specific timeout
      # For HTTParty, timeout error might be wrapped, e.g. Net::ReadTimeout or HTTParty::Error
      # Depending on HTTParty version and exact error class, adjust expectation.
      # Often it's Net::OpenTimeout or Net::ReadTimeout which are StandardError
      expect(result[:error]).to match(/Timeout::Error|Net::OpenTimeout|Net::ReadTimeout|HTTParty::Error/)
    end

    it "sends custom headers if provided" do
      custom_headers = {"User-Agent" => "TestAgent/1.0", "X-Custom" => "Value"}
      stub_request(:get, test_url)
        .with(headers: custom_headers) # WebMock verifies headers
        .to_return(status: 200, body: "<title>Headers Test</title>")
      
      result = client.probe(test_url, { headers: custom_headers })
      expect(result[:status_code]).to eq(200)
      expect(result[:title]).to eq("Headers Test")
    end
    
    it "stores raw headers from the response" do
      response_headers = {"Content-Type" => "text/html; charset=utf-8", "X-Powered-By" => "Ruby"}
      stub_request(:get, test_url)
        .to_return(status: 200, body: "<title>Raw Headers</title>", headers: response_headers)
      
      result = client.probe(test_url)
      expect(result[:raw_headers]).to eq(response_headers)
    end
  end
end
