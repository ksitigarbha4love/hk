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
    let(:ruby_template_id) { "ruby-dsl-test" } # Generic ID for some tests

    # ... (existing Ruby DSL load/execute tests from turn 156 can be kept or refined) ...
    describe "#load (Ruby DSL)" do
        let(:simple_ruby_content) { "HK.template('#{ruby_template_id}') { info name: 'R' }" }
        let(:simple_ruby_path) { create_temp_ruby_template(File.join(general_templates_dir,"#{ruby_template_id}.rb"), simple_ruby_content) }

        it "loads a valid .rb template file" do
            loaded = engine.load(simple_ruby_path)
            expect(loaded).not_to be_nil
            expect(loaded[:id]).to eq(ruby_template_id)
            expect(loaded[:definition]).to be_a(HK::RubyTemplateDefinition)
        end
    end

    describe "#execute (Ruby DSL with new features)" do
      it "respects target condition block (skips if condition false)" do
        content = "HK.template('target-skip') { info name: 'TS'; target { |c| false }; execute { |_,_,r| r.report(d:'R') } }"
        path = create_temp_ruby_template(File.join(general_templates_dir,"target_skip.rb"), content)
        parsed = engine.load(path)
        results = engine.execute(parsed, "http://otherdomain.com")
        expect(results[:findings]).to be_empty
        expect(results[:errors].first).to include("Target does not meet conditions for template target-skip (Skipped)")
      end

      it "executes if target condition block returns true" do
        content = "HK.template('target-pass') { info name: 'TP'; target { |c| true }; execute { |_,_,r| r.report(description:'R') } }"
        path = create_temp_ruby_template(File.join(general_templates_dir,"target_pass.rb"), content)
        parsed = engine.load(path)
        results = engine.execute(parsed, "http://example.com")
        expect(results[:findings].size).to eq(1)
      end

      # New test for payloads functionality (from current task)
      it "allows execute_block to use payload_sets defined in the template" do
        payload_test_id = "ruby-payload-test-01"
        payload_test_content = <<-RUBY
          HK.template "#{payload_test_id}" do
            info name: "Ruby Payload Iteration Test", severity: :medium, author: "Payload Tester"
            payloads(:sql_errors) { ["' OR '1'='1", "admin'--"] }
            payloads(:xss_scripts) { ["<script>alert(1)</script>"] }
            execute do |target, http, reporter|
              self.payload_sets[:sql_errors].call.each_with_index do |payload, idx|
                reporter.report(description: "SQLi: #{payload}", matched_at_url: "\#{target}/sql/\#{idx}")
              end
              self.payload_sets[:xss_scripts].call.each_with_index do |payload, idx|
                reporter.report(description: "XSS: #{payload}", matched_at_url: "\#{target}/xss/\#{idx}", severity: :high)
              end
            end
          end
        RUBY
        payload_template_path = create_temp_ruby_template(File.join(general_templates_dir,"#{payload_test_id}.rb"), payload_test_content)

        parsed_payload_template = engine.load(payload_template_path)
        expect(parsed_payload_template).not_to be_nil

        results = engine.execute(parsed_payload_template, "http://testtarget.com")

        expect(results[:success]).to be true
        expect(results[:errors]).to be_empty
        expect(results[:findings].size).to eq(3) # 2 SQLi + 1 XSS

        sqli_findings = results[:findings].select { |f| f[:description].start_with?("SQLi:") }
        xss_findings = results[:findings].select { |f| f[:description].start_with?("XSS:") }

        expect(sqli_findings.size).to eq(2)
        expect(sqli_findings[0][:description]).to eq("SQLi: ' OR '1'='1")
        expect(sqli_findings[0][:severity]).to eq(:medium) # Inherited from template info
        expect(sqli_findings[0][:matched_at_url]).to eq("http://testtarget.com/sql/0")

        expect(xss_findings.size).to eq(1)
        expect(xss_findings[0][:description]).to eq("XSS: <script>alert(1)</script>")
        expect(xss_findings[0][:severity]).to eq(:high) # Overridden in report
        expect(xss_findings[0][:matched_at_url]).to eq("http://testtarget.com/xss/0")
      end
    end
  end

  # --- Tests for #load_from_path (condensed, from previous subtask) ---
  describe "#load_from_path" do
    it "loads all valid YAML and Ruby templates from a directory" do
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
