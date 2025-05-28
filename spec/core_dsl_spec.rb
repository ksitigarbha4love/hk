require 'spec_helper'
# core_dsl.rb is loaded via hk.rb, which is loaded by spec_helper
# require 'hk/core_dsl' # Not strictly needed if spec_helper requires 'hk'

RSpec.describe HK do # Testing methods on the HK module itself and its registry
  before(:each) do
    HK::TemplateRegistry.clear! # Ensure clean registry for each test
  end

  describe ".template DSL" do
    it "defines and registers a RubyTemplateDefinition" do
      HK.template "test-ruby-001" do
        info name: "My Ruby Test", severity: :high, author: "DSL Tester"
        execute do |target, http, info_block|
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

    it "uses default info attributes if not specified" do
      HK.template "test-ruby-defaults" do
        # No info block
        execute { }
      end
      definition = HK::TemplateRegistry.find("test-ruby-defaults")
      expect(definition.info_attrs[:name]).to eq("Unnamed Ruby Template")
      expect(definition.info_attrs[:severity]).to eq("info")
    end

    it "overwrites existing template with the same ID when re-registering" do
      HK.template "overwrite-test" do
        info name: "Original"
      end
      original_def = HK::TemplateRegistry.find("overwrite-test")
      
      HK.template "overwrite-test" do
        info name: "New Version"
      end
      new_def = HK::TemplateRegistry.find("overwrite-test")

      expect(new_def).not_to be(original_def) # Should be a new instance
      expect(new_def.info_attrs[:name]).to eq("New Version")
      # Ensure registry stores the new one
      expect(HK::TemplateRegistry.all_templates.size).to eq(1)
    end
  end

  describe HK::RubyTemplateDefinition do
    let(:definition) { HK::RubyTemplateDefinition.new("def-id") }

    it "initializes with an ID and default info/execute_block" do
      expect(definition.id).to eq("def-id")
      expect(definition.info_attrs[:name]).to eq("Unnamed Ruby Template")
      expect(definition.execute_block).to be_a(Proc)
    end

    it "#info merges new details with existing ones" do
      definition.info name: "Specific Name"
      expect(definition.info_attrs[:name]).to eq("Specific Name")
      expect(definition.info_attrs[:severity]).to eq("info") # Default preserved

      definition.info severity: :critical, custom_field: "value"
      expect(definition.info_attrs[:severity]).to eq(:critical)
      expect(definition.info_attrs[:custom_field]).to eq("value")
    end

    it "#execute sets the execute_block" do
      original_block = definition.execute_block
      new_proc = proc { "new block" }
      definition.execute(&new_proc)
      expect(definition.execute_block).not_to eq(original_block)
      expect(definition.execute_block).to eq(new_proc)
    end
  end
end
