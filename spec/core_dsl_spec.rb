require 'spec_helper'
# core_dsl.rb is loaded via hk.rb, which is loaded by spec_helper

RSpec.describe HK do 
  before(:each) do
    HK::TemplateRegistry.clear! 
  end

  describe ".template DSL (Basic Definition)" do # Renamed for clarity
    it "defines and registers a RubyTemplateDefinition" do
      HK.template "test-ruby-001" do
        info name: "My Ruby Test", severity: :high, author: "DSL Tester"
        execute do |target, http, reporter| # Updated signature
          # test block
        end
      end

      definition = HK::TemplateRegistry.find("test-ruby-001")
      expect(definition).to be_a(HK::RubyTemplateDefinition)
      expect(definition.id).to eq("test-ruby-001")
      expect(definition.info_attrs[:name]).to eq("My Ruby Test")
      expect(definition.info_attrs[:severity]).to eq(:high)
      expect(definition.info_attrs[:author]).to eq("DSL Tester")
      expect(definition.execute_block).to be_a(Proc)
    end
  end

  describe HK::RubyTemplateDefinition do
    let(:template_id) { "my-def-id" }
    let(:definition) { HK::RubyTemplateDefinition.new(template_id) }

    it "initializes with an ID and default info/execute_block" do
      expect(definition.id).to eq(template_id)
      expect(definition.info_attrs[:name]).to eq("Unnamed Ruby Template")
      expect(definition.info_attrs[:id]).to eq(template_id) # Check if ID is in info_attrs
      expect(definition.execute_block).to be_a(Proc)
      # Test default execute block with a reporter
      mock_reporter = instance_double(HK::RubyTemplateDefinition::FindingReporter)
      expect(mock_reporter).to receive(:report).with(description: "Warning: Execute block not defined for #{template_id}", severity: "debug")
      definition.execute_block.call("http://target.com", nil, mock_reporter)
    end

    it "#info merges new details with existing ones" do
      definition.info name: "Specific Name", custom_tag: "custom"
      expect(definition.info_attrs[:name]).to eq("Specific Name")
      expect(definition.info_attrs[:custom_tag]).to eq("custom")
      expect(definition.info_attrs[:severity]).to eq("info") # Default preserved
    end

    it "#execute sets the execute_block" do
      original_block = definition.execute_block
      new_proc = proc { "new block" }
      definition.execute(&new_proc)
      expect(definition.execute_block).not_to eq(original_block)
      expect(definition.execute_block).to eq(new_proc)
    end
    
    # New tests for payloads and target DSL methods (from current task)
    describe "DSL methods for payloads and target conditions" do
      it "#payloads stores a named block that generates payloads" do
        payload_block = proc { ["payload1", "payload2"] }
        definition.payloads(:xss_vectors, &payload_block)
        
        expect(definition.payload_sets[:xss_vectors]).to be_a(Proc)
        expect(definition.payload_sets[:xss_vectors].call).to eq(["payload1", "payload2"])
      end

      it "#target stores a condition block" do
        condition_block = proc { |target_components| target_components[:host].end_with?(".gov") }
        definition.target(&condition_block) # Default type is :url
        
        expect(definition.target_condition_block).to be_a(Proc)
        # Test the block itself (conceptual, actual execution is in TemplateEngine)
        expect(definition.target_condition_block.call({host: "example.gov"})).to be true
        expect(definition.target_condition_block.call({host: "example.com"})).to be false
      end
    end
  end
  
  # New tests for FindingReporter (from current task)
  describe HK::RubyTemplateDefinition::FindingReporter do
    let(:base_info) { { id: "test-id", name: "Test Template", severity: "medium" } }
    let(:report_target_url) { "http://target.com/vulnerable_page" }
    let(:reporter) { HK::RubyTemplateDefinition::FindingReporter.new(base_info, report_target_url) }

    it "initializes with base template info and target URL" do
      expect(reporter.base_template_info).to eq(base_info)
      expect(reporter.base_target_url).to eq(report_target_url)
      expect(reporter.findings).to be_empty
    end

    it "#report creates a finding hash with merged details" do
      reporter.report(
        description: "SQL Injection found.",
        matched_at_url: "#{report_target_url}/sqli?id=1", # Specific URL for this finding
        evidence: "Error near 'UNION'",
        custom_field: "test_value"
      )
      
      expect(reporter.findings.size).to eq(1)
      finding = reporter.findings.first
      
      expect(finding[:template_id]).to eq("test-id")
      expect(finding[:template_name]).to eq("Test Template")
      expect(finding[:severity]).to eq("medium") # Default from base_info
      expect(finding[:target_url]).to eq(report_target_url) # Base target for the run
      expect(finding[:matched_at_url]).to eq("#{report_target_url}/sqli?id=1")
      expect(finding[:description]).to eq("SQL Injection found.")
      expect(finding[:evidence]).to eq("Error near 'UNION'")
      expect(finding[:custom_field]).to eq("test_value")
    end

    it "#report uses base_target_url for matched_at_url if not provided" do
      reporter.report(description: "Default matched_at_url test")
      expect(reporter.findings.first[:matched_at_url]).to eq(report_target_url)
    end
    
    it "#report allows overriding base_info severity and name" do
        reporter.report(description: "Override severity", severity: "high", name: "Specific Finding Name")
        finding = reporter.findings.first
        expect(finding[:severity]).to eq("high")
        expect(finding[:name]).to eq("Specific Finding Name")
    end
  end
end
