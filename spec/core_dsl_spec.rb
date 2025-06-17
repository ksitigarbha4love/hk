require 'spec_helper'
# core_dsl.rb is loaded via hk.rb, which is loaded by spec_helper

RSpec.describe HK do
  before(:each) do
    HK::TemplateRegistry.clear!
    # Mock HK.logger for tests in this file if its output is asserted
    # Allow by default, specific tests can set expectations.
    allow(HK.logger).to receive(:error)
    allow(HK.logger).to receive(:warn)
    allow(HK.logger).to receive(:info)
    allow(HK.logger).to receive(:debug)
  end

  describe ".template DSL (Basic Definition)" do
    it "defines and registers a RubyTemplateDefinition" do
      HK.template "test-ruby-001" do
        info name: "My Ruby Test", severity: :high, author: "DSL Tester"
        execute do |target, http, reporter, payload| # Updated signature
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
      expect(definition.info_attrs[:id]).to eq(template_id)
      expect(definition.execute_block).to be_a(Proc)

      mock_reporter = instance_double(HK::RubyTemplateDefinition::FindingReporter)
      expect(mock_reporter).to receive(:report).with(description: "Warning: Execute block not defined for #{template_id}. Payload: nil", severity: "debug")
      definition.execute_block.call("http://target.com", nil, mock_reporter, nil) # Pass nil for payload
    end

    it "#info merges new details with existing ones" do
      definition.info name: "Specific Name", custom_tag: "custom"
      expect(definition.info_attrs[:name]).to eq("Specific Name")
      expect(definition.info_attrs[:custom_tag]).to eq("custom")
      expect(definition.info_attrs[:severity]).to eq("info")
    end

    it "#execute sets the execute_block" do
      original_block = definition.execute_block
      new_proc = proc { "new block" }
      definition.execute(&new_proc)
      expect(definition.execute_block).not_to eq(original_block)
      expect(definition.execute_block).to eq(new_proc)
    end

    describe "#get_payloads" do
      let(:definition_with_payloads) do
        # HK::TemplateRegistry.clear! # Already in top-level before_each
        HK.template "payload-getter-test" do
          payloads :users do
            ["user1", "user2"]
          end
          payloads :passwords do
            ["pass1", "pass2"]
          end
          payloads :faulty_set do
            raise StandardError, "Faulty payload generation"
          end
        end
        # HK.template returns the definition, but find is also fine.
        HK::TemplateRegistry.find("payload-getter-test")
      end

      before(:each) do
        # Clear cache for each #get_payloads test example
        definition_with_payloads.instance_variable_set(:@payload_cache, {})
      end

      it "retrieves and executes the correct payload proc" do
        expect(definition_with_payloads.get_payloads(:users)).to eq(["user1", "user2"])
      end

      it "accepts string or symbol for payload set name" do
        expect(definition_with_payloads.get_payloads("users")).to eq(["user1", "user2"])
      end

      it "caches the results of a payload proc call" do
        users_proc = definition_with_payloads.instance_variable_get(:@payload_sets)[:users]
        expect(users_proc).to receive(:call).once.and_return(["user1", "user2"])

        definition_with_payloads.get_payloads(:users)
        expect(definition_with_payloads.get_payloads(:users)).to eq(["user1", "user2"])
      end

      it "returns an empty array and logs error if payload proc raises an exception" do
        expect(HK.logger).to receive(:error).with(/Error generating payloads for set ':faulty_set' in template 'payload-getter-test': StandardError - Faulty payload generation/)
        expect(definition_with_payloads.get_payloads(:faulty_set)).to eq([])
        # Also check that it caches the empty array to prevent re-execution of faulty proc
        expect(definition_with_payloads.get_payloads(:faulty_set)).to eq([])
        # Ensure faulty_proc was not called again for the cached access
        faulty_proc = definition_with_payloads.instance_variable_get(:@payload_sets)[:faulty_set]
        expect(faulty_proc).to receive(:call).once.and_raise(StandardError, "Faulty payload generation") # Called once for initial try
        definition_with_payloads.instance_variable_set(:@payload_cache, {}) # Clear cache to force re-call
        definition_with_payloads.get_payloads(:faulty_set) # This will call it
        definition_with_payloads.get_payloads(:faulty_set) # This should be cached (empty array)
      end

      it "returns an empty array and logs warning if payload set does not exist" do
        # Note: The logger message in SUT is "Payload set ':#{name}' not found or not a Proc..."
        # The test should match this.
        expect(HK.logger).to receive(:warn).with("Payload set ':non_existent_set' not found or not a Proc in template 'payload-getter-test'.")
        expect(definition_with_payloads.get_payloads(:non_existent_set)).to eq([])
      end
    end
  end

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
      reporter.report(description: "SQL Injection found.", matched_at_url: "#{report_target_url}/sqli?id=1", evidence: "Error near 'UNION'")
      expect(reporter.findings.size).to eq(1); finding = reporter.findings.first
      expect(finding[:template_id]).to eq("test-id"); expect(finding[:template_name]).to eq("Test Template"); expect(finding[:severity]).to eq("medium")
      expect(finding[:target_url]).to eq(report_target_url); expect(finding[:matched_at_url]).to eq("#{report_target_url}/sqli?id=1")
      expect(finding[:description]).to eq("SQL Injection found."); expect(finding[:evidence]).to eq("Error near 'UNION'")
    end
  end
end
