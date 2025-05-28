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

  describe "#load (YAML)" do
    it "loads a valid YAML template file" do
      yaml_content = {
        'id' => 'test-001',
        'info' => { 'name' => 'Test Template', 'severity' => 'high', 'author' => 'tester' },
        'requests' => [{ 'method' => 'GET', 'path' => '/', 'matchers' => [] }]
      }
      template_path = create_temp_yaml_template(File.join(general_templates_dir,"valid_template.yml"), yaml_content)
      
      loaded_template = engine.load(template_path)
      expect(loaded_template).not_to be_nil
      expect(loaded_template[:type]).to eq(:yaml)
      expect(loaded_template[:id]).to eq('test-001')
      expect(loaded_template[:data]['info']['name']).to eq('Test Template')
    end

    it "generates ID from filename if not present in YAML" do
      yaml_content = {
        'info' => { 'name' => 'No ID Template', 'severity' => 'low' },
        'requests' => [{ 'path' => '/' }]
      }
      template_path = create_temp_yaml_template(File.join(general_templates_dir,"no_id_template.yml"), yaml_content)
      loaded_template = engine.load(template_path)
      expect(loaded_template[:id]).to eq('no_id_template')
    end

    it "returns nil if YAML file does not exist" do
      expect(engine.load("non_existent_template.yml")).to be_nil
    end

    it "returns nil for malformed YAML" do
      template_path = create_temp_yaml_template(File.join(general_templates_dir,"malformed.yml"), "info: name: test\nrequests:\n  - path: /test")
      expect(engine.load(template_path)).to be_nil
    end
    
    it "returns nil if essential keys (info, requests) are missing" do
      yaml_content = { 'id' => 'bad-struct', 'info' => { 'name' => 'Bad Structure' } } 
      template_path = create_temp_yaml_template(File.join(general_templates_dir,"bad_structure.yml"), yaml_content)
      expect(engine.load(template_path)).to be_nil
    end
    
    it "returns nil if info.name or info.severity is missing" do
      yaml_content = { 'id' => 'bad-info', 'info' => { 'author' => 'tester' }, 'requests' => [{'path' => '/'}] }
      template_path = create_temp_yaml_template(File.join(general_templates_dir,"bad_info.yml"), yaml_content)
      expect(engine.load(template_path)).to be_nil
    end
  end

  describe "#execute (YAML)" do
    let(:basic_template_data) do
      {
        'id' => 'vuln-check-01',
        'info' => { 'name' => 'SQL Injection Words', 'severity' => 'critical' },
        'requests' => [
          {
            'method' => 'GET',
            'path' => '/search?query={{BaseURL}}',
            'matchers-condition' => 'and',
            'matchers' => [ { 'type' => 'word', 'words' => ['SQL syntax error', 'MySQL'], 'part' => 'body' } ]
          }
        ]
      }
    end
    let(:parsed_yaml_template) { { type: :yaml, id: 'vuln-check-01', data: basic_template_data } }
    let(:expected_yaml_exec_url) { "http://example.com/search?query=http://example.com" }


    it "executes a YAML template and finds a vulnerability" do
      stub_request(:get, expected_yaml_exec_url)
        .to_return(status: 200, body: "Page content with SQL syntax error and MySQL reference.")
      results = engine.execute(parsed_yaml_template, target_url)
      expect(results[:findings].size).to eq(1)
      expect(results[:findings].first[:template_id]).to eq('vuln-check-01')
    end
  end

  context "when handling Ruby DSL templates (load and execute)" do
    let(:ruby_template_id) { "ruby-exec-test-001" }
    let(:ruby_template_content) do
      <<-RUBY_TEMPLATE
        HK.template "#{ruby_template_id}" do
          info name: "Ruby Execute Test", severity: :medium
          execute do |target, http, info|
            response = http.get("/api/data")
            if response && response[:status] == 200 && response[:body]&.include?("vulnerable_data")
              { findings: [{ id: info[:id]||"#{ruby_template_id}", name: info[:name], severity: info[:severity], description: "Found vulnerable_data via Ruby template at \#{target}/api/data", matched_at_url: "\#{target}/api/data" }] }
            else
              { findings: [], errors: ["Test error: API call failed or pattern not found"] }
            end
          end
        end
      RUBY_TEMPLATE
    end
    let(:ruby_template_path) { create_temp_ruby_template(File.join(general_templates_dir,"#{ruby_template_id}.rb"), ruby_template_content) }
    
    describe "#load (Ruby DSL)" do
      it "loads a valid .rb template file and finds its definition" do
        loaded_template = engine.load(ruby_template_path)
        expect(loaded_template).not_to be_nil
        expect(loaded_template[:type]).to eq(:ruby)
        expect(loaded_template[:id]).to eq(ruby_template_id)
        expect(loaded_template[:definition]).to be_a(HK::RubyTemplateDefinition)
        expect(loaded_template[:definition].info_attrs[:name]).to eq("Ruby Execute Test")
      end

      it "returns nil if .rb file does not call HK.template with matching ID" do
        bad_ruby_content = "puts 'This is not a template'"
        bad_template_path = create_temp_ruby_template(File.join(general_templates_dir,"not_a_template.rb"), bad_ruby_content)
        expect(engine.load(bad_template_path)).to be_nil
      end
      
      it "returns nil if .rb file fails to load (e.g. syntax error)" do
          error_ruby_content = "HK.template 'syntax-error' do info name: 'test" 
          error_template_path = create_temp_ruby_template(File.join(general_templates_dir,"syntax_error_template.rb"), error_ruby_content)
          expect(engine.load(error_template_path)).to be_nil
      end
    end

    describe "#execute (Ruby DSL)" do
      it "executes a Ruby template's execute_block and processes findings" do
        parsed_template = engine.load(ruby_template_path)
        expect(parsed_template).not_to be_nil 

        expected_api_url = "#{normalized_target_url}api/data" 
        stub_request(:get, expected_api_url)
          .to_return(status: 200, body: "Page has vulnerable_data here.", headers: {'Content-Type'=>'text/html'})

        results = engine.execute(parsed_template, target_url)
        
        expect(results[:success]).to be true
        expect(results[:findings].size).to eq(1)
        expect(results[:findings].first[:name]).to eq("Ruby Execute Test")
      end
    end
  end

  # Tests for #load_from_path (from current task prompt)
  describe "#load_from_path" do
    # templates_dir_for_load_path is defined in top-level let block
    let(:valid_yaml_content) { { 'id' => 'yaml-01', 'info' => {'name'=>'YAML Test', 'severity'=>'high'}, 'requests'=>[{'path'=>'/'}]} }
    let(:valid_ruby_content) { "HK.template('ruby-01') { info name: 'Ruby Test', severity: :medium; execute {} }" }
    let(:invalid_yaml_content) { "id: yaml-broken\ninfo:\n  name: Broken" } # Missing severity, requests
    let(:non_template_ruby_content) { "puts 'Just a script'" }

    # before(:all) & after(:all) for templates_dir_for_load_path are handled by top-level hooks.
    # before(:each) for HK::TemplateRegistry.clear! is also handled by top-level hook.

    context "when path is a single file" do
      it "loads a single valid YAML file" do
        path = create_temp_yaml_template(File.join(templates_dir_for_load_path, "single_valid.yml"), valid_yaml_content)
        results = engine.load_from_path(path)
        expect(results[:loaded_templates].size).to eq(1)
        expect(results[:loaded_templates].first[:type]).to eq(:yaml)
        expect(results[:loaded_templates].first[:id]).to eq("yaml-01")
        expect(results[:errors]).to be_empty
      end

      it "loads a single valid Ruby DSL file" do
        path = create_temp_ruby_template(File.join(templates_dir_for_load_path, "single_valid.rb"), valid_ruby_content)
        results = engine.load_from_path(path)
        expect(results[:loaded_templates].size).to eq(1)
        expect(results[:loaded_templates].first[:type]).to eq(:ruby)
        expect(results[:loaded_templates].first[:id]).to eq("ruby-01")
        expect(results[:errors]).to be_empty
      end
      
      it "returns an error if single file fails to load" do
          path = create_temp_yaml_template(File.join(templates_dir_for_load_path, "single_invalid.yml"), invalid_yaml_content)
          results = engine.load_from_path(path)
          expect(results[:loaded_templates]).to be_empty
          expect(results[:errors].size).to eq(1)
          expect(results[:errors].first).to include("Failed to load or parse template file: #{path}")
      end
    end

    context "when path is a directory" do
      before(:each) do 
        FileUtils.rm_rf(templates_dir_for_load_path) 
        FileUtils.mkdir_p(templates_dir_for_load_path)
        create_temp_yaml_template(File.join(templates_dir_for_load_path, "dir_valid.yml"), valid_yaml_content.merge({'id'=>'dir-yaml-01'}))
        create_temp_ruby_template(File.join(templates_dir_for_load_path, "dir_valid.rb"), "HK.template('dir-ruby-01') { info name:'Dir Ruby' }")
        create_temp_yaml_template(File.join(templates_dir_for_load_path, "dir_invalid.yml"), invalid_yaml_content)
        create_temp_ruby_template(File.join(templates_dir_for_load_path, "dir_non_template.rb"), non_template_ruby_content)
        File.write(File.join(templates_dir_for_load_path, "unsupported.txt"), "text file")
      end

      it "loads all valid templates from the directory (non-recursive)" do
        results = engine.load_from_path(templates_dir_for_load_path)
        expect(results[:loaded_templates].size).to eq(2)
        expect(results[:loaded_templates].map { |t| t[:id] }).to match_array(["dir-yaml-01", "dir-ruby-01"])
        expect(results[:errors].size).to eq(2) 
        expect(results[:errors].any? { |e| e.include?("dir_invalid.yml") }).to be true
        expect(results[:errors].any? { |e| e.include?("dir_non_template.rb") && e.include?("no template with ID") }).to be true
      end
      
      it "returns empty results and no errors if directory contains no supported template files" do 
          # Note: My TemplateEngine from turn 158 adds an error here. The prompt's test expects no errors.
          # I will stick to the prompt's expectation for this test.
          empty_dir = File.join(templates_dir_for_load_path, "empty_subdir")
          FileUtils.mkdir_p(empty_dir)
          File.write(File.join(empty_dir, "only_text.txt"), "hello")
          results = engine.load_from_path(empty_dir)
          expect(results[:loaded_templates]).to be_empty
          expect(results[:errors]).to be_empty # Test as per prompt
      end
    end

    context "when path does not exist" do
      it "returns an error" do
        results = engine.load_from_path("non_existent_dir_or_file")
        expect(results[:loaded_templates]).to be_empty
        expect(results[:errors].size).to eq(1)
        expect(results[:errors].first).to include("Path does not exist")
      end
    end
  end
end
