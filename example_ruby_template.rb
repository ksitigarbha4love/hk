HK.template "my-ruby-check" do
  info name: "My First Ruby Check",
       severity: :medium, # Note: prompt uses :medium, my RubyTemplateDefinition defaults to string "info"
                          # but merge! should handle this.
       author: "Rubyist"

  execute do |target, http_client_wrapper| # Renamed 'http' to 'http_client_wrapper' for clarity
    puts "Executing My First Ruby Check on #{target}!"
    # Example usage:
    # response = http_client_wrapper.get(target)
    # if response && response.body.include?("vulnerable_pattern")
    #   # Report finding
    # end
  end
end

HK.template "another-check" do
  info name: "Another Simple Check"
  # No execute block, will use default
end
