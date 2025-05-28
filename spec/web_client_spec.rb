require 'spec_helper'
require 'hk/web/client' 
require 'httparty' # For HTTParty::CookieHash

RSpec.describe HK::Web::Client do
  let(:client) { HK::Web::Client.new }
  let(:base_url_str) { "http://example.com" } # String for probe method
  let(:target_url_obj) { URI.parse(base_url_str) } # URI object for comparison

  before(:each) do
    # WebMock is enabled via spec_helper.rb and reset after each test
  end

  # --- Tests for #probe (Updated for POST, Redirects, Cookies) ---
  describe "#probe" do
    # Existing GET tests (can be kept or refined)
    it "successfully probes a GET request and extracts status, title, body" do
      stub_request(:get, base_url_str)
        .to_return(status: 200, body: "<html><head><title>GET Test</title></head><body>Hello GET</body></html>", headers: {'Content-Type'=>'text/html'})
      result = client.probe(base_url_str) # Default method is GET
      expect(result[:status_code]).to eq(200)
      expect(result[:title]).to eq("GET Test")
      expect(result[:body]).to include("Hello GET")
      expect(result[:final_url]).to eq(base_url_str) # No redirect
      expect(result[:error]).to be_nil
    end

    # New tests for POST
    context "with POST requests" do
      let(:post_url) { "#{base_url_str}/submit" }
      let(:post_data) { { name: "HK Tester", message: "Hello POST" } }
      let(:custom_headers) { { "Content-Type" => "application/x-www-form-urlencoded"} }

      it "sends a POST request with specified data and headers" do
        stub_request(:post, post_url)
          .with(body: post_data, headers: { 'User-Agent'=> HK::Web::Client::DEFAULT_USER_AGENT }.merge(custom_headers) )
          .to_return(status: 201, body: "Success", headers: { 'Location' => '/new_resource' })
        
        result = client.probe(post_url, method: 'POST', body_data: post_data, headers: custom_headers)
        
        expect(result[:status_code]).to eq(201)
        expect(result[:body]).to eq("Success")
        expect(result[:raw_headers]['location']).to eq('/new_resource') # Check specific header
      end
    end

    # New tests for Redirects
    context "with redirects" do
      let(:redirect_url_1) { "#{base_url_str}/redirect1" }
      let(:redirect_url_2) { "#{base_url_str}/redirect2" }
      let(:final_destination_url) { "#{base_url_str}/final" }

      it "follows redirects and captures the final URL" do
        stub_request(:get, redirect_url_1).to_return(status: 301, headers: { 'Location' => redirect_url_2 })
        stub_request(:get, redirect_url_2).to_return(status: 302, headers: { 'Location' => final_destination_url })
        stub_request(:get, final_destination_url).to_return(status: 200, body: "<title>Final Page</title>")

        result = client.probe(redirect_url_1)
        
        expect(result[:status_code]).to eq(200)
        expect(result[:title]).to eq("Final Page")
        expect(result[:final_url]).to eq(final_destination_url)
        expect(result[:url]).to eq(redirect_url_1) # Original URL
      end
    end
    
    # New tests for Cookies
    context "with cookie handling" do
      let(:set_cookie_url) { "#{base_url_str}/setcookie" }
      let(:use_cookie_url) { "#{base_url_str}/usecookie" }
      let(:cookie_hash) { HTTParty::CookieHash.new } # Create a new cookie jar for tests

      it "receives and stores cookies from server" do
        stub_request(:get, set_cookie_url)
          .to_return(status: 200, body: "Cookie set page", headers: { 'Set-Cookie' => 'session_id=12345; path=/' })
        
        result = client.probe(set_cookie_url, cookie_jar: cookie_hash) # Pass jar
        
        expect(result[:cookies]).to include("session_id" => "12345")
        # Also check if the passed-in cookie_hash was updated (if HTTParty modifies it directly)
        # HTTParty's behavior with passed :cookies option might update the hash or return new one via response.cookies
        # The client saves response.cookies.to_h, so we check that.
        # To test if the jar itself is updated for subsequent requests, we'd make another request.
      end

      it "sends cookies from the provided cookie_jar on subsequent requests" do
        # First request to set the cookie in our jar
        cookie_hash.add_cookies("session_id=abcdef; path=/; domain=example.com")

        # Stub the second request to expect the cookie
        stub_request(:get, use_cookie_url)
          .with(headers: { 'Cookie' => 'session_id=abcdef' }) # Webmock checks for this header
          .to_return(status: 200, body: "Welcome back!")

        result = client.probe(use_cookie_url, cookie_jar: cookie_hash)
        expect(result[:status_code]).to eq(200)
        expect(result[:body]).to eq("Welcome back!")
      end
    end
  end

  # Tests for #probe_multiple (from previous subtask, turn 155)
  describe "#probe_multiple" do
    let(:urls_to_probe) { [test_url, "#{base_url_str}/another", "http://nonexistent123.com"] }
    let(:another_page_url) { "#{base_url_str}/another" }

    it "probes multiple URLs and correctly manages cookies across them if a jar is used" do
      # Setup: first URL sets a cookie, second URL should receive it
      stub_request(:get, test_url)
        .to_return(status: 200, body: "<title>Example</title>", headers: { 'Set-Cookie' => 'batch_session=batch123; path=/' })
      stub_request(:get, another_page_url)
        .with(headers: { 'Cookie' => 'batch_session=batch123' })
        .to_return(status: 200, body: "<title>Another with Batch Cookie</title>")
      stub_request(:get, "http://nonexistent123.com").to_raise(SocketError.new("Failed to connect"))

      # probe_multiple now internally creates and uses a shared cookie_jar for the batch
      results = client.probe_multiple(urls_to_probe) 
      
      expect(results).to be_an(Array)
      expect(results.size).to eq(3)

      expect(results[0][:url]).to eq(test_url)
      expect(results[0][:status_code]).to eq(200)
      expect(results[0][:cookies]).to include("batch_session" => "batch123")

      expect(results[1][:url]).to eq(another_page_url)
      expect(results[1][:status_code]).to eq(200)
      expect(results[1][:title]).to eq("Another with Batch Cookie") # Verifies cookie was sent

      expect(results[2][:url]).to eq("http://nonexistent123.com")
      expect(results[2][:error]).to include("SocketError: Failed to connect")
    end
  end
end
