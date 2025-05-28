require 'spec_helper'
require 'hk/cli' 
require 'hk/web/crawler' 
require 'fileutils'      
require 'yaml'           
require 'json'           
require 'tty-progressbar' # For mocking

RSpec.describe HK::CLI do
  # --- Top-level Helpers ---
  def capture_stdout_and_stderr(&block)
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = fake_out = StringIO.new
    $stderr = fake_err = StringIO.new
    begin
      yield
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
    { stdout: fake_out.string, stderr: fake_err.string }
  end

  def run_cli(*args)
    original_argv = ARGV.dup
    ARGV.replace(args.map(&:to_s)) 
    output_streams = {}
    begin
        output_streams = capture_stdout_and_stderr { HK::CLI.start(ARGV) }
    rescue SystemExit => e
        # Capture output even if SystemExit is raised
        output_streams[:stdout] = $stdout.string if $stdout.is_a?(StringIO) && output_streams[:stdout].nil?
        output_streams[:stderr] = $stderr.string if $stderr.is_a?(StringIO) && output_streams[:stderr].nil?
    end
    # Return both stdout and stderr for assertions
    # Ensure keys exist even if capture block wasn't fully entered due to early error
    { stdout: output_streams[:stdout] || "", stderr: output_streams[:stderr] || "" }
  ensure
    ARGV.replace(original_argv)
  end

  def create_temp_file(base_dir, filename, content) 
    path = File.join(base_dir, filename)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end
  
  def create_temp_yaml_template(base_dir, filename, content_hash)
    create_temp_file(base_dir, filename, content_hash.to_yaml)
  end

  def create_temp_ruby_template(base_dir, filename, content_string)
    create_temp_file(base_dir, filename, content_string)
  end

  let(:general_templates_dir) { "tmp/general_cli_tests" } # More specific name
  let(:scan_templates_dir) { File.join(general_templates_dir, "scan_cmd_templates") }


  before(:all) do
    FileUtils.rm_rf("tmp/general_cli_tests") 
    FileUtils.mkdir_p("tmp/general_cli_tests")
  end
  
  after(:all) do
    FileUtils.rm_rf("tmp/general_cli_tests")
  end
  
  before(:each) do
    HK::TemplateRegistry.clear!
    # Ensure the specific test subdirectories are clean for each relevant test context
    FileUtils.rm_rf(scan_templates_dir) if Dir.exist?(scan_templates_dir)
    FileUtils.mkdir_p(scan_templates_dir)
  end

  # --- Basic CLI Command Tests (condensed) ---
  describe "hk version" do
    it "prints the version" do
      outputs = run_cli("version")
      expect(outputs[:stdout]).to include(HK::VERSION)
    end
  end
  
  # --- Tests for 'hk scan' with JSON output and Progress Bar (conceptual) ---
  context "when running 'hk scan' with advanced features" do
    let(:scan_target) { "http://scannable.example.com" }
    let(:normalized_scan_target) { HK::Web::Crawler.normalize_url(scan_target) } 
    
    let(:finding_yaml_content) do
      { 'id' => 'scan-yaml-001',
        'info' => {'name'=>'Scan YAML Finding', 'severity'=>'high'},
        'requests'=>[{'path'=>'/vuln', 'matchers'=>[{'type'=>'word', 'words'=>['vulnerable_pattern']}]}]
      }
    end
    let(:error_ruby_content) do # Ruby template that reports an error
      <<-RUBY
        HK.template('scan-ruby-err') do
          info name: 'Scan Ruby Error', severity: :medium
          execute {|t,h,r| { errors: ["Ruby execution error example"] } }
        end
      RUBY
    end
    let(:json_output_file) { File.join(scan_templates_dir, "results.json") }

    before(:each) do
      # Create some templates in the scan_templates_dir
      create_temp_yaml_template(scan_templates_dir, "finding.yml", finding_yaml_content)
      create_temp_ruby_template(scan_templates_dir, "error_maker.rb", error_ruby_content)
      
      # Stub HTTP requests
      stub_request(:get, "#{normalized_scan_target}vuln").to_return(status: 200, body: "Found vulnerable_pattern here.")
      # No specific stubs for error_maker.rb as its execute block doesn't make HTTP calls
      
      # Ensure json_output_file does not exist before tests that create it
      FileUtils.rm_f(json_output_file)
    end
    
    after(:each) do
      FileUtils.rm_f(json_output_file) # Clean up JSON file after each test
    end

    describe "--json FILEPATH output" do
      it "saves results to a JSON file and suppresses detailed STDOUT" do
        outputs = run_cli("scan", scan_target, "-t", scan_templates_dir, "--json", json_output_file)
        
        expect(File.exist?(json_output_file)).to be true
        json_data = JSON.parse(File.read(json_output_file))
        
        expect(json_data['target_info']['normalized_target_url']).to eq(normalized_scan_target)
        expect(json_data['summary']['templates_loaded']).to eq(2)
        expect(json_data['summary']['findings_count']).to eq(1)
        expect(json_data['summary']['execution_errors_count']).to eq(1)
        
        expect(json_data['findings'].first['template_id']).to eq('scan-yaml-001')
        expect(json_data['errors'].first).to include("Ruby execution error example")
        
        # Check that normal verbose STDOUT is suppressed
        expect(outputs[:stdout]).to include("Scan results saved to JSON: #{json_output_file}")
        expect(outputs[:stdout]).not_to include("Vulnerability Findings") # Main table header
        expect(outputs[:stdout]).not_to include("Template Name: Scan YAML Finding")
        # Loading errors should go to stderr if JSON is on
        expect(outputs[:stderr]).to eq("") # Assuming no loading errors for these valid templates
      end
      
      it "prints an error if JSON file cannot be written" do
        # Make the output path non-writable (e.g. by creating a directory there)
        FileUtils.mkdir_p(json_output_file) # Create a dir where file should be
        outputs = run_cli("scan", scan_target, "-t", scan_templates_dir, "--json", json_output_file)
        expect(outputs[:stdout]).to include("Error: Could not write JSON output to #{json_output_file}")
        FileUtils.rm_rf(json_output_file) # Cleanup
      end
    end

    describe "Progress Bar integration (conceptual)" do
      let(:mock_progress_bar) { instance_double(TTY::ProgressBar, advance: nil, finish: nil) }

      it "initializes and advances progress bar for template execution in 'scan'" do
        # Stub requests for the templates
        stub_request(:get, "#{normalized_scan_target}vuln").to_return(status: 200, body: "vulnerable_pattern")
        
        # Expect ProgressBar.new to be called with total: number of loaded templates (2 here)
        expect(TTY::ProgressBar).to receive(:new).with(
            "Executing templates [:bar] :current/:total :percent :etas",
            total: 2, # finding.yml, error_maker.rb
            clear: true
        ).and_return(mock_progress_bar)
        
        # Expect advance to be called for each template
        expect(mock_progress_bar).to receive(:advance).twice
        
        run_cli("scan", scan_target, "-t", scan_templates_dir)
      end
      
      it "initializes and advances progress bar for port scanning in 'ports'" do
        # Test for 'hk ports' command (ensure it's also covered if not done elsewhere)
        # This test is a bit out of place in "hk scan" context, but demonstrates the idea
        target_ports = [80, 443]
        # Mock HK::Net::Scanner instance and its tcp_scan to verify bar passing
        mock_net_scanner = instance_double(HK::Net::Scanner)
        allow(HK::Net::Scanner).to receive(:new).and_return(mock_net_scanner)
        
        # Expect tcp_scan to be called with the bar
        expect(mock_net_scanner).to receive(:tcp_scan)
          .with(target_host, target_ports, instance_of(Hash), mock_progress_bar) 
          # We expect the bar to be passed to tcp_scan, which will advance it.
          # The actual advance calls on the bar would be tested in net_scanner_spec.rb for tcp_scan.
          .and_return({open_ports:[], filtered_ports:[], closed_ports:[], error:nil})


        expect(TTY::ProgressBar).to receive(:new).with(
            "Scanning #{target_host} [:bar] :current/:total (:percent) :etas", # Match format in CLI
            total: target_ports.size,
            clear: true
        ).and_return(mock_progress_bar)
        
        run_cli("ports", target_host, "-p", target_ports.join(','))
        # Note: If tcp_scan itself advances the bar, we don't need to mock :advance here again,
        # just that it received the bar. This test focuses on CLI creating and passing the bar.
      end
    end
  end
  # ... (other CLI command tests like ports, http, crawl, templates if they were here)
end
