require 'hk' # Load your library's main file
require 'webmock/rspec'

# Configure WebMock
WebMock.disable_net_connect!(allow_localhost: true) # Disable real net connections

RSpec.configure do |config|
  # Optional: Any global before-each setup for all specs
  config.before(:each) do
    # Stub any external services that are frequently used and not part of the specific test.
  end

  # Clean up WebMock stubs after each test to prevent interference
  config.after(:each) do
    WebMock.reset!
  end
end
