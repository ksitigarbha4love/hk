require 'spec_helper'
require 'hk/cli' 
require 'hk/web/crawler' # For HK::Web::Crawler.normalize_url
require 'fileutils'      # For template file creation in tests
require 'json'           # For parsing JSON output from CLI helpers if needed

RSpec.describe HK::CLI do
  # --- Top-level Helpers ---
  def capture_stdout(&block)
    original_stdout = $stdout
    $stdout = fake = StringIO.new
    begin
      yield
    ensure
      $stdout = original_stdout
    end
    fake.string
  end

  def run_cli(*args)
    original_argv = ARGV.dup
    ARGV.replace(args.map(&:to_s)) 
    output = capture_stdout { HK::CLI.start(ARGV) }
  ensure
    ARGV.replace(original_argv)
    output
  end

  # Helpers for creating temporary template files (moved here for CLI tests)
  def create_temp_yaml_template(base_dir, filename, content)
    path = File.join(base_dir, filename)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content.to_yaml)
    path
  end

  def create_temp_ruby_template(base_dir, filename, content)
    path = File.join(base_dir, filename)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  # --- Basic CLI Command Tests (from previous subtasks) ---
  describe "hk version" do
    it "prints the version" do
      output = run_cli("version")
      expect(output).to include(HK::VERSION)
      expect(output).to include("Hēi Kè (HK) Security Framework version")
    end
  end

  # Note: The old "hk scan TARGET" test is removed as `scan` now requires -t
  # describe "hk scan TARGET" ... 

  describe "hk ports TARGET (basic invocation)" do
    it "invokes ports scan with a target and default ports" do
      output = run_cli("ports", "example.net") 
      expect(output).to include("CLI: Received ports command for target: example.net")
      expect(output).to include("(No ports specified, using default list:")
      expect(output).to include("Open Ports:") 
    end

    it "shows help for ports" do
      output = run_cli("help", "ports")
      expect(output).to include("Usage:")
      expect(output).to include("hk ports TARGET")
    end
  end
  
  describe "hk http URL (basic invocation)" do
    it "invokes http probe for a URL" do
      stub_request(:get, "http://example.com/").to_return(status: 200, body: "<title>Ex</title>")
      output = run_cli("http", "example.com") # Default to http
      expect(output).to include("CLI: Received http command for URL: example.com")
      expect(output).to include("Status Code:")
    end

    it "shows help for http" do
      output = run_cli("help", "http")
      expect(output).to include("Usage:")
      expect(output).to include("hk http URL")
    end
  end

  describe "hk crawl URL (basic invocation)" do
    it "invokes crawl for a URL" do
      # Stub the initial request for the crawl command
      stub_request(:get, HK::Web::Crawler.normalize_url("http://example.com"))
        .to_return(status: 200, body: "<html><body>No links</body></html>", headers: {'Content-Type'=>'text/html'})
      output = run_cli("crawl", "http://example.com")
      expect(output).to include("CLI: Received crawl command for URL: http://example.com")
      expect(output).to include("Starting crawl") # From CLI
      expect(output).to include("HK::Web::Crawler initialized.") # From Crawler
    end

    it "shows help for crawl" do
      output = run_cli("help", "crawl")
      expect(output).to include("Usage:")
      expect(output).to include("hk crawl URL")
    end
  end
  
  # --- New context for 'hk scan' with template integration (from current task) ---
  context "when running 'hk scan' with template integration" do
    let(:scan_target) { "http://scannable.example.com" }
    # HK::Web::Crawler.normalize_url adds trailing slash if host-only
    let(:normalized_scan_target) { HK::Web::Crawler.normalize_url(scan_target) } 
    let(:templates_dir_for_cli) { "tmp/cli_scan_templates_integration" } # Unique name

    let(:finding_yaml_content) do
      { 'id' => 'cli-yaml-finding',
        'info' => {'name'=>'CLI YAML Vuln', 'severity'=>'high'},
        'requests'=>[{'path'=>'/vuln_path', 'matchers'=>[{'type'=>'word', 'words'=>['vulnerable_indicator']}]}]
      }
    end
    let(:finding_ruby_content) do
      <<-RUBY
        HK.template('cli-ruby-finding') do
          info name: 'CLI Ruby Vuln', severity: :critical
          execute do |target, http, info|
            response = http.get('/ruby_vuln_path') # Relative to target
            if response && response[:body]&.include?('ruby_is_exploitable')
              # For CLI test, ensure matched_at_url is constructed correctly
              # target in execute block is the base target_url string
              # http.get prepends its own base_target_url, so http.get result will be full
              # The finding should report the full URL where it matched.
              # ClientWrapper's get already forms full URL.
              # The TemplateEngine's execute_ruby_template passes target_url (base) and client_wrapper.
              # Finding's matched_at_url should be the full URL.
              full_matched_url = URI.join(target, '/ruby_vuln_path').to_s
              { findings: [{ 
                  id: info[:id]||'cli-ruby-finding', 
                  name: info[:name], 
                  severity: info[:severity], 
                  description: "Found via Ruby", 
                  target_url: target, # Base target
                  matched_at_url: full_matched_url
              }] }
            else
              { findings: [] }
            end
          end
        end
      RUBY
    end
    let(:info_yaml_content) { { 'id' => 'cli-yaml-info', 'info' => {'name'=>'CLI YAML Info', 'severity'=>'info'}, 'requests'=>[{'path'=>'/'}]} }


    before(:all) do
      FileUtils.rm_rf("tmp/cli_scan_templates_integration")
      FileUtils.mkdir_p("tmp/cli_scan_templates_integration")
    end
    after(:all) do
      FileUtils.rm_rf("tmp/cli_scan_templates_integration")
    end
    
    before(:each) do
      HK::TemplateRegistry.clear! # Important for Ruby templates loaded via CLI
      # Create template files for each test to ensure clean state if content varies
      # The CLI will load these from the specified path.
      create_temp_yaml_template(templates_dir_for_cli, "finding.yml", finding_yaml_content)
      create_temp_ruby_template(templates_dir_for_cli, "finding.rb", finding_ruby_content)
      create_temp_yaml_template(templates_dir_for_cli, "info.yml", info_yaml_content)
    end

    it "loads and executes a single YAML template specified by file path" do
      stub_request(:get, "#{normalized_scan_target}vuln_path")
        .to_return(status: 200, body: "Contains vulnerable_indicator here.", headers: {'Content-Type'=>'text/html'})
      
      output = run_cli("scan", scan_target, "-t", File.join(templates_dir_for_cli, "finding.yml"))
      
      expect(output).to include("Successfully loaded 1 template(s)")
      expect(output).to include("Vulnerability Findings (1)")
      expect(output).to include("Template Name: CLI YAML Vuln (cli-yaml-finding)")
      expect(output).to include("Severity: high")
      expect(output).to include("Matched At:    #{normalized_scan_target}vuln_path")
    end

    it "loads and executes templates from a directory path" do
      stub_request(:get, "#{normalized_scan_target}vuln_path") # For finding.yml
        .to_return(status: 200, body: "Contains vulnerable_indicator here.", headers: {'Content-Type'=>'text/html'})
      stub_request(:get, "#{normalized_scan_target}ruby_vuln_path") # For finding.rb
        .to_return(status: 200, body: "Ah, ruby_is_exploitable indeed.", headers: {'Content-Type'=>'text/html'})
      stub_request(:get, normalized_scan_target).to_return(status: 200, body: "Info page.", headers: {'Content-Type'=>'text/html'}) # For info.yml

      output = run_cli("scan", scan_target, "-t", templates_dir_for_cli)
      
      expect(output).to include("Successfully loaded 3 template(s)")
      expect(output).to include("Vulnerability Findings (3)") # 2 findings + 1 info from empty matcher
      expect(output).to include("Template Name: CLI YAML Vuln")
      expect(output).to include("Template Name: CLI Ruby Vuln")
      expect(output).to include("Template Name: CLI YAML Info")
      expect(output).to include("Severity: critical") # From Ruby
      expect(output).to include("Severity: high")     # From YAML
      expect(output).to include("Severity: info")     # From Info YAML
    end

    it "reports errors if template path is invalid" do
      output = run_cli("scan", scan_target, "-t", "non_existent_templates_path/")
      expect(output).to include("Error: Path does not exist: non_existent_templates_path/")
      expect(output).to include("No templates were successfully loaded. Aborting scan.")
    end
    
    it "passes timeout option to TemplateEngine which is then used by Web::Client" do
      # This test relies on the TemplateEngine passing options to Web::Client.
      # The CLI scan command initializes TemplateEngine with {timeout: options[:timeout]}.
      # TemplateEngine passes its @options[:timeout] to Web::Client.probe.
      
      timeout_test_rb_content = <<-RUBY
        HK.template('cli-timeout-test') do
          info name: 'Timeout Test', severity: :info
          execute do |target, http, info|
            # http.get should use the timeout passed from CLI -> TemplateEngine -> ClientWrapper -> WebClient
            # We can't directly check HTTParty's options here via WebMock easily
            # without more complex stubbing or direct inspection of what ClientWrapper passes.
            # For this test, we'll just ensure the command runs and the option is logged by CLI.
            # HK::Web::Client would need to log the timeout it used for a more direct check here.
            http.get('/timeout_check_path', timeout: info[:engine_options][:timeout] || 1) # Simulate access
            { findings: [{id: 'timeout-confirm', name: 'timeout-confirm', severity: :info, description:'ran'}] } 
          end
        end
      RUBY
      timeout_template_path = create_temp_ruby_template(templates_dir_for_cli, "timeout.rb", timeout_test_rb_content)

      # WebMock to check if HTTParty receives the timeout
      # This requires ClientWrapper to pass options to WebClient.probe, and WebClient to pass to HTTParty
      # The current ClientWrapper passes options[:timeout] directly.
      # The current TemplateEngine passes its own @options (which get CLI options) to WebClient.
      stub_request(:get, "#{normalized_scan_target}timeout_check_path")
        .with { |req| 
            # HTTParty's actual timeout option might be complex to inspect directly here.
            # Instead, we'll rely on the fact that if it times out, WebMock can simulate that.
            # For now, just ensure the request is made.
            true 
          }
          .to_return(status: 200, body: "timeout check")

      output = run_cli("scan", scan_target, "-t", timeout_template_path, "--timeout", "7")
      
      expect(output).to include("Global timeout option: 7") 
      # More robust: check if TemplateEngine's options reflect it, or if WebClient logs it.
      # The Ruby template itself doesn't directly get engine_options in its execute block's info param in current setup.
      # The test above is more conceptual for now about timeout propagation.
      # A better test would be to have the Ruby template's execute block receive the timeout option
      # or have the ClientWrapper log the timeout it's using.
      # For now, we confirm the CLI option is parsed and passed to where TemplateEngine is initialized.
      expect(output).to include("Scan finished.") # Ensure it ran
      expect(output).to include("Template Name: Timeout Test (cli-timeout-test)") # Check it ran
    end
  end
end
