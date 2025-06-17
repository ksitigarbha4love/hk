require 'spec_helper'
require 'hk/cli'
require 'hk/web/crawler'
require 'fileutils'
require 'yaml'
require 'json'
require 'tty-progressbar'

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
        output_streams[:stdout] = $stdout.string if $stdout.is_a?(StringIO) && output_streams[:stdout].nil?
        output_streams[:stderr] = $stderr.string if $stderr.is_a?(StringIO) && output_streams[:stderr].nil?
    end
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

  let(:cli_test_tmp_root) { "tmp/cli_tests" }
  let(:home_hk_templates) { File.join(cli_test_tmp_root, "home_user", ".hk", "templates") }
  let(:project_templates) { File.join(cli_test_tmp_root, "project", "templates") }
  let(:custom_path1)      { File.join(cli_test_tmp_root, "custom_one") }
  let(:custom_path2)      { File.join(cli_test_tmp_root, "custom_two") }

  around(:each) do |example| # Use around to manage home dir for these specific tests
    original_home = ENV['HOME']
    ENV['HOME'] = File.join(cli_test_tmp_root, "home_user") # Set fake home for ~ expansion

    FileUtils.rm_rf(cli_test_tmp_root)
    FileUtils.mkdir_p(home_hk_templates)
    FileUtils.mkdir_p(project_templates)
    FileUtils.mkdir_p(custom_path1)
    FileUtils.mkdir_p(custom_path2)

    # Clear HK::TemplateRegistry before each CLI test that might load Ruby templates
    HK::TemplateRegistry.clear! if defined?(HK::TemplateRegistry)

    example.run

    ENV['HOME'] = original_home
    FileUtils.rm_rf(cli_test_tmp_root)
  end

  # --- Basic CLI Command Tests (condensed) ---
  describe "hk version" do
    it "prints the version" do
      outputs = run_cli("version")
      expect(outputs[:stdout]).to include(HK::VERSION)
    end
  end

  # --- Tests for 'hk templates list' and 'hk templates search' (from current task) ---
  describe "hk templates" do
    # Content for test templates
    let(:yaml_t1_content) { {'id'=>'yaml-001', 'info'=>{'name'=>'YAML One', 'severity'=>'high', 'author'=>'Y Tester', 'description'=>'Desc Y1'}} }
    let(:ruby_t1_content) { "HK.template('ruby-001'){info name:'Ruby One', severity: :medium, author:'R Tester', description:'Desc R1'}" }
    let(:yaml_t2_content) { {'id'=>'yaml-002', 'info'=>{'name'=>'YAML Two (common)', 'severity'=>'low', 'author'=>'Y Tester', 'description'=>'Desc Y2 common'}} }
    # Duplicate ID to test prioritization (first loaded wins)
    let(:yaml_t1_dup_content) { {'id'=>'yaml-001', 'info'=>{'name'=>'YAML One Duplicate', 'severity'=>'critical', 'author'=>'Dup Tester'}} }

    # Helper to create files and run list/search
    def setup_and_run_templates_command(*cli_args)
      # Create templates in various locations
      create_temp_yaml_template(home_hk_templates, "home_yaml_1.yml", yaml_t1_content)
      create_temp_ruby_template(project_templates, "project_ruby_1.rb", ruby_t1_content)
      create_temp_yaml_template(custom_path1, "custom_yaml_2.yml", yaml_t2_content)
      create_temp_yaml_template(custom_path2, "custom_yaml_1_dup.yml", yaml_t1_dup_content) # Duplicate ID

      # Mock Dir.exist? for default paths to ensure they are "found" by the CLI command
      # The command uses File.expand_path, so we need to match that.
      allow(Dir).to receive(:exist?).and_call_original # Allow other Dir.exist? calls
      allow(Dir).to receive(:exist?).with(File.expand_path(HK::TemplatesCLI::HOME_TEMPLATES_DIR.gsub("~", ENV['HOME']))).and_return(true)
      allow(Dir).to receive(:exist?).with(File.expand_path(HK::TemplatesCLI::PROJECT_TEMPLATES_DIR)).and_return(true)
      allow(Dir).to receive(:exist?).with(File.expand_path(custom_path1)).and_return(true)
      allow(Dir).to receive(:exist?).with(File.expand_path(custom_path2)).and_return(true)

      run_cli("templates", *cli_args)
    end

    describe "list" do
      it "lists templates from default and specified paths, handling duplicates" do
        outputs = setup_and_run_templates_command("list", "-P", custom_path1, custom_path2)

        expect(outputs[:stdout]).to include("Listing templates from paths:")
        # Check if all paths are listed (order might vary due to Set conversion or Dir.new.children order)
        # Default paths are ~/.hk/templates and ./templates
        expect(outputs[:stdout]).to include(File.expand_path(home_hk_templates))
        expect(outputs[:stdout]).to include(File.expand_path(project_templates))
        expect(outputs[:stdout]).to include(File.expand_path(custom_path1))
        expect(outputs[:stdout]).to include(File.expand_path(custom_path2))

        expect(outputs[:stdout]).to include("Available Templates (3):") # yaml-001, ruby-001, yaml-002
        expect(outputs[:stdout]).to include("yaml-001")
        expect(outputs[:stdout]).to include("YAML One") # Original, not duplicate
        expect(outputs[:stdout]).to include("ruby-001")
        expect(outputs[:stdout]).to include("Ruby One")
        expect(outputs[:stdout]).to include("yaml-002")
        expect(outputs[:stdout]).to include("YAML Two (common)")
        expect(outputs[:stdout]).not_to include("YAML One Duplicate") # Duplicate ID was ignored
      end

      it "shows verbose output with -v" do
        outputs = setup_and_run_templates_command("list", "-P", custom_path1, "-v")
        expect(outputs[:stdout]).to include("Author")
        expect(outputs[:stdout]).to include("Description")
        expect(outputs[:stdout]).to include("Y Tester")
        expect(outputs[:stdout]).to include("Desc Y1") # From yaml-001 in home_hk_templates
        expect(outputs[:stdout]).to include("Desc Y2 common") # From yaml-002 in custom_path1
      end
    end

    describe "search KEYWORD" do
      it "finds templates by keyword in name (case-sensitive by default)" do
        outputs = setup_and_run_templates_command("search", "YAML", "-P", custom_path1)
        expect(outputs[:stdout]).to include("Found 2 template(s):") # yaml-001, yaml-002
        expect(outputs[:stdout]).to include("yaml-001")
        expect(outputs[:stdout]).to include("yaml-002")
        expect(outputs[:stdout]).not_to include("ruby-001")
      end

      it "finds templates by keyword case-insensitively with -i" do
        outputs = setup_and_run_templates_command("search", "yaml", "-i", "-P", custom_path1)
        expect(outputs[:stdout]).to include("Found 2 template(s):")
        expect(outputs[:stdout]).to include("yaml-001")
        expect(outputs[:stdout]).to include("yaml-002")
      end

      it "finds templates by keyword in description" do
        outputs = setup_and_run_templates_command("search", "Desc Y1", "-P", custom_path1)
        expect(outputs[:stdout]).to include("Found 1 template(s):")
        expect(outputs[:stdout]).to include("yaml-001") # From home_hk_templates
      end

      it "shows verbose output for search results with -v" do
        outputs = setup_and_run_templates_command("search", "common", "-i", "-P", custom_path1, "-v")
        expect(outputs[:stdout]).to include("Found 1 template(s):") # yaml-002 has "common" in name and desc
        expect(outputs[:stdout]).to include("yaml-002")
        expect(outputs[:stdout]).to include("Author")
        expect(outputs[:stdout]).to include("Desc Y2 common")
      end

      it "reports 'No matching templates found' if keyword does not match" do
        outputs = setup_and_run_templates_command("search", "NonExistentKeyword123", "-P", custom_path1)
        expect(outputs[:stdout]).to include("No matching templates found.")
      end
    end
  end
  # ... (other CLI command tests like scan, ports, http, crawl - should be preserved)
end
