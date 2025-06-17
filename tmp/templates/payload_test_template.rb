# Example: tmp/templates/payload_test_template.rb
HK.template "ruby-payload-test-01" do
  info name: "Ruby Payload Iteration Test",
       severity: :medium,
       author: "Payload Tester"

  # Define a named payload set
  payloads :sql_errors do
    [
      "' OR '1'='1",
      "admin'--",
      "test' OR 1=1 LIMIT 1 -- "
    ]
  end

  # Define another named payload set
  payloads :xss_scripts do
    [
      "<script>alert(1)</script>",
      "<img src=x onerror=alert(2)>"
    ]
  end

  execute do |target_url, http, reporter|
    # Access payload sets via self (which is the RubyTemplateDefinition instance)
    # puts "Executing Ruby Payload Test on \#{target_url}" # For debugging
    # puts "Available payload sets: \#{self.payload_sets.keys.inspect}" # For debugging

    # Iterate through sql_errors payloads
    sql_error_payloads = self.payload_sets[:sql_errors]&.call
    if sql_error_payloads
      sql_error_payloads.each_with_index do |payload, idx|
        # Simulate making a request with the payload
        # For this test, we'll just report a finding based on the payload
        # In a real template, you'd use: response = http.get("/search?q=\#{URI.encode_www_form_component(payload)}")
        # And then check response.

        reporter.report(
          description: "SQLi attempt with payload: #{payload}",
          matched_at_url: "\#{target_url}/search?q=payload_\#{idx}", # Dummy URL
          evidence: payload
        )
      end
    end

    # Iterate through xss_scripts payloads
    xss_payloads = self.payload_sets[:xss_scripts]&.call
    if xss_payloads
        xss_payloads.each_with_index do |payload, idx|
            reporter.report(
                description: "XSS attempt with payload: #{payload}",
                matched_at_url: "\#{target_url}/comment?text=payload_\#{idx}", # Dummy URL
                evidence: payload,
                severity: :high # Override severity for this specific finding
            )
        end
    end

    # Return collected findings (implicitly done by reporter, but can be explicit)
    # For TemplateEngine to pick them up from block_result if needed:
    # { findings: reporter.findings }
    # However, current TemplateEngine implementation (turn 156) uses reporter.findings directly.
  end
end
