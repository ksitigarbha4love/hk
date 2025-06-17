HK.template "multi_payload_example" do
  info(
    name: "Multiple Payload Sets Example",
    author: "Test Author",
    severity: "info",
    description: "Demonstrates accessing different payload sets within a Ruby DSL template. The engine iterates 'paths', and we manually fetch 'params'."
  )

  # This payload set will be iterated by the TemplateEngine
  payloads :paths do
    ["/home", "/admin", "/test"]
  end

  # This payload set will be accessed manually using get_payloads
  payloads :params do
    ["debug=true", "user=guest", "id=1"]
  end

  # A payload set that might produce an error during generation
  payloads :error_prone_set do
    raise "Simulated error during payload generation for error_prone_set!"
    ["/shoud_not_be_reached"]
  end

  # An empty payload set
  payloads :empty_set do
    []
  end

  execute do |target_url, client, reporter, path_payload|
    # path_payload is from the 'paths' set, iterated by the engine

    reporter.report(
      description: "Executing with path: #{path_payload || 'N/A (default run)'}",
      details: "Path payload received: #{path_payload.inspect}"
    )

    # Accessing the 'params' payload set manually
    manual_params = self.get_payloads(:params) # 'self' is the RubyTemplateDefinition instance

    if manual_params.any?
      manual_params.each do |param_payload|
        # Example: make a request for each path_payload combined with each param_payload
        # For demonstration, we'll just report it
        full_target = "#{target_url}#{path_payload}?#{param_payload}"
        reporter.report(
          description: "Manually fetched param for path '#{path_payload}': #{param_payload}",
          details: "Constructed URL: #{full_target}",
          custom_field: "param_used: #{param_payload}"
        )
        # In a real template, you might do: client.get("#{path_payload}?#{param_payload}")
      end
    else
      reporter.report(
        description: "No params found via get_payloads(:params) for path: #{path_payload}",
        severity: "warn" # Potentially a warning if params were expected
      )
    end

    # Attempt to access the error-prone payload set
    error_payloads = self.get_payloads(:error_prone_set)
    reporter.report(
      description: "Attempted to get :error_prone_set. Count: #{error_payloads.size}",
      details: "Content: #{error_payloads.inspect}" # Should be empty due to error and caching
    )
    # Try getting it again to see if the cached empty result is returned (logged by core_dsl)
    error_payloads_again = self.get_payloads(:error_prone_set)
    reporter.report(
      description: "Attempted to get :error_prone_set again. Count: #{error_payloads_again.size}",
      details: "Content: #{error_payloads_again.inspect}" # Should also be empty
    )


    # Attempt to access a non-existent payload set
    non_existent_payloads = self.get_payloads(:non_existent_set)
    reporter.report(
      description: "Attempted to get :non_existent_set. Count: #{non_existent_payloads.size}",
      details: "Content: #{non_existent_payloads.inspect}" # Should be empty
    )

    # Attempt to access an empty payload set
    empty_payloads = self.get_payloads(:empty_set)
    reporter.report(
      description: "Attempted to get :empty_set. Count: #{empty_payloads.size}",
      details: "Content: #{empty_payloads.inspect}" # Should be empty
    )

  end
end
