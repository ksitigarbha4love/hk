require 'spec_helper'
require 'hk/template_engine' 
require 'hk/web/crawler'   
require 'yaml'             
require 'fileutils'        

RSpec.describe HK::TemplateEngine do
  let(:engine) { HK::TemplateEngine.new }
  let(:target_url) { "http://example.com" } 
  let(:normalized_target_url) { HK::Web::Crawler.normalize_url(target_url) } 

  def create_temp_yaml_template(filename, content)
    dir = File.dirname(filename) 
    FileUtils.mkdir_p(dir) unless File.exist?(dir)
    File.write(filename, content.to_yaml)
    filename 
  end

  def create_temp_ruby_template(filename, content)
    dir = File.dirname(filename)
    FileUtils.mkdir_p(dir) unless File.exist?(dir)
    File.write(filename, content)
    filename
  end
  
  def capture_stdout
    original_stdout = $stdout
    $stdout = fake = StringIO.new
    yield
    fake.string
  ensure
    $stdout = original_stdout
  end

  let(:general_templates_dir) { "tmp/general_templates" }
  let(:templates_dir_for_load_path) { "tmp/templates_for_load_path" }


  before(:all) do
    FileUtils.rm_rf("tmp/general_templates") 
    FileUtils.rm_rf("tmp/templates_for_load_path") 
    FileUtils.mkdir_p("tmp/general_templates")
    FileUtils.mkdir_p("tmp/templates_for_load_path")
  end
  
  after(:all) do
    FileUtils.rm_rf("tmp/general_templates")
    FileUtils.rm_rf("tmp/templates_for_load_path") 
  end
  
  before(:each) do
    HK::TemplateRegistry.clear!
  end

  # --- YAML Template Tests (condensed) ---
  describe "#load (YAML)" do
    it "loads a valid YAML template file" do
      yaml_content = { 'id' => 'test-001', 'info' => { 'name' => 'Test Template', 'severity' => 'high' }, 'requests' => [{'path'=>'/'}] }
      template_path = create_temp_yaml_template(File.join(general_templates_dir,"valid_template.yml"), yaml_content)
      loaded = engine.load(template_path)
      expect(loaded).not_to be_nil
      expect(loaded[:id]).to eq('test-001')
    end
  end
  describe "#execute (YAML)" do
    it "executes a basic YAML template" do
      yaml_content = { 'id' => 'exec-yaml', 'info' => { 'name' => 'Exec YAML', 'severity' => 'high' }, 'requests' => [{'path'=>'/', 'matchers'=>[{'type'=>'word', 'words'=>['Example']}]}] }
      template_path = create_temp_yaml_template(File.join(general_templates_dir,"exec_template.yml"), yaml_content)
      parsed_template = engine.load(template_path)
      stub_request(:get, normalized_target_url).to_return(status: 200, body: "Welcome to Example Domain")
      results = engine.execute(parsed_template, target_url)
      expect(results[:findings].size).to eq(1)
      expect(results[:findings].first[:template_id]).to eq('exec-yaml')
    end
  end

  # --- Ruby DSL Template Tests ---
  context "when handling Ruby DSL templates (load and execute)" do
    let(:ruby_template_id) { "ruby-dsl-test" }
    
    describe "#load (Ruby DSL)" do
      it "loads a valid .rb template file" do
        content = "HK.template('#{ruby_template_id}') { info name: 'R' }"
        path = create_temp_ruby_template(File.join(general_templates_dir,"#{ruby_template_id}.rb"), content)
        loaded = engine.load(path)
        expect(loaded).not_to be_nil
        expect(loaded[:id]).to eq(ruby_template_id)
        expect(loaded[:definition]).to be_a(HK::RubyTemplateDefinition)
      end
    end

    describe "#execute (Ruby DSL with new features)" do
      it "respects target condition block (skips if condition false)" do
        content = <<-RUBY
          HK.template "#{ruby_template_id}" do
            info name: "Target Test Skip"
            target { |components| components[:host].include?("specific.com") }
            execute { |_, _, reporter| reporter.report(description: "Should not run") }
          end
        RUBY
        path = create_temp_ruby_template(File.join(general_templates_dir,"#{ruby_template_id}.rb"), content)
        parsed = engine.load(path)
        
        results = engine.execute(parsed, "http://otherdomain.com") # Should not match target
        expect(results[:findings]).to be_empty
        expect(results[:errors].first).to include("Target does not meet conditions for template #{ruby_template_id} (Skipped)")
      end

      it "executes if target condition block returns true" do
        content = <<-RUBY
          HK.template "#{ruby_template_id}" do
            info name: "Target Test Pass"
            target { |components| components[:host] == "example.com" }
            execute { |_, _, reporter| reporter.report(description: "Target condition passed") }
          end
        RUBY
        path = create_temp_ruby_template(File.join(general_templates_dir,"#{ruby_template_id}.rb"), content)
        parsed = engine.load(path)
        
        results = engine.execute(parsed, "http://example.com") # Matches target
        expect(results[:findings].size).to eq(1)
        expect(results[:findings].first[:description]).to eq("Target condition passed")
      end

      it "allows execute_block to use payload_sets defined in the template" do
        content = <<-RUBY
          HK.template "#{ruby_template_id}" do
            info name: "Payload Test"
            payloads :sqli_payloads do
              ["' OR 1=1 --", " UNION SELECT null--"]
            end
            execute do |target, http, reporter|
              payload_sets[:sqli_payloads].call.each_with_index do |payload, index|
                # In a real template, you'd make a request with the payload
                # For this test, just report a finding for each payload to show iteration.
                # stub_request(:get, "\#{target}/search?q=\#{payload}").to_return(status: 200, body: "found")
                reporter.report(description: "Tested with payload: \#{payload}", matched_at_url: "\#{target}/search?id=\#{index}")
              end
              { findings: reporter.findings } # Return what reporter collected
            end
          end
        RUBY
        path = create_temp_ruby_template(File.join(general_templates_dir,"#{ruby_template_id}.rb"), content)
        parsed = engine.load(path)
        
        # No HTTP stubs needed as the test template doesn't make calls with http client wrapper
        results = engine.execute(parsed, "http://example.com")
        
        expect(results[:findings].size).to eq(2)
        expect(results[:findings][0][:description]).to eq("Tested with payload: ' OR 1=1 --")
        expect(results[:findings][1][:description]).to eq("Tested with payload:  UNION SELECT null--")
      end

      it "FindingReporter correctly populates finding details" do
        content = <<-RUBY
          HK.template "#{ruby_template_id}" do
            info name: "Reporter Test", severity: :high, author: "Test Author", id: "#{ruby_template_id}"
            execute do |target_url, http, reporter|
              reporter.report(
                description: "Specific XSS found",
                matched_at_url: "\#{target_url}/xss_path",
                severity: :critical, # Override template severity for this specific finding
                evidence: "<script>alert(1)</script>"
              )
              { findings: reporter.findings }
            end
          end
        RUBY
        path = create_temp_ruby_template(File.join(general_templates_dir,"#{ruby_template_id}.rb"), content)
        parsed = engine.load(path)
        results = engine.execute(parsed, "http://example.com")
        
        expect(results[:findings].size).to eq(1)
        finding = results[:findings].first
        expect(finding[:template_id]).to eq(ruby_template_id)
        expect(finding[:template_name]).to eq("Reporter Test") # From template's info
        expect(finding[:severity]).to eq(:critical) # Overridden by report
        expect(finding[:target_url]).to eq("http://example.com")
        expect(finding[:matched_at_url]).to eq("http://example.com/xss_path")
        expect(finding[:description]).to eq("Specific XSS found")
        expect(finding[:evidence]).to eq("<script>alert(1)</script>")
      end
    end
  end

  # --- Tests for #load_from_path (condensed) ---
  describe "#load_from_path" do
    context "when path is a directory" do
      it "loads all valid YAML and Ruby templates from the directory" do
        valid_yaml_content = { 'id' => 'yaml-01', 'info' => {'name'=>'YAML Test', 'severity'=>'high'}, 'requests'=>[{'path'=>'/'}]}
        valid_ruby_content = "HK.template('ruby-01') { info name: 'Ruby Test', severity: :medium; execute {} }"
        create_temp_yaml_template(File.join(templates_dir_for_load_path, "dir_valid.yml"), valid_yaml_content)
        create_temp_ruby_template(File.join(templates_dir_for_load_path, "dir_valid.rb"), valid_ruby_content)

        results = engine.load_from_path(templates_dir_for_load_path)
        expect(results[:loaded_templates].size).to eq(2)
        expect(results[:loaded_templates].map { |t| t[:id] }).to match_array(["yaml-01", "ruby-01"])
        expect(results[:errors]).to be_empty
      end
    end
  end
end
