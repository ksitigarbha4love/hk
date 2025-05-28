# benchmarks/port_scanning_benchmark.rb
require 'benchmark/ips'
require 'socket' # For SocketError, Addrinfo etc.
begin
  require 'hk'
rescue LoadError
  require_relative '../lib/hk'
  # require 'bundler/setup' if defined?(Bundler) # Usually not needed with bundle exec
end

scanner = HK::Net::Scanner.new
target_host = "localhost_bench" # Mocked, no real connection
ports_to_scan = (1..10).to_a # Scan 10 ports

# Mock Socket.tcp to make the benchmark focus on the scanner's internal logic
# This is crucial for stable and fast benchmarks independent of network.
mock_socket_instance = instance_double(Socket, close: nil)

# Allow Addrinfo to resolve our fake host for all calls in this benchmark suite
# This should ideally be in a before(:suite) or equivalent if benchmark-ips had it,
# or just at the top level like this.
allow(Addrinfo).to receive(:getaddrinfo).with(target_host, nil, :INET, :STREAM)
    .and_return([Addrinfo.tcp(target_host, 0)]) # Return a dummy Addrinfo

puts "Starting Port Scanning Benchmark (mocked TCP Connect for 10 ports)..."
Benchmark.ips do |x|
  x.config(time: 3, warmup: 1) # Shorter time for quicker feedback

  x.report("tcp_scan (all open)") do
    # Setup mocks inside the report block to ensure they are fresh for each measurement loop
    allow(Socket).to receive(:tcp).and_return(mock_socket_instance) 
    # For banner grabbing part, if any, ensure it doesn't hang or error unexpectedly
    allow(mock_socket_instance).to receive(:write_nonblock).and_return(1) # Simulate successful write
    allow(IO).to receive(:select).with([mock_socket_instance], nil, nil, HK::Net::Scanner::BANNER_READ_TIMEOUT).and_return(nil) # Simulate no banner data

    scanner.tcp_scan(target_host, ports_to_scan, { timeout: 0.01 }) 
  end
  
  x.report("tcp_scan (all closed)") do
    allow(Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
    scanner.tcp_scan(target_host, ports_to_scan, { timeout: 0.01 })
  end
  
  x.report("tcp_scan (all filtered)") do
    allow(Socket).to receive(:tcp).and_raise(Timeout::Error) # Simulate timeout for connect
    scanner.tcp_scan(target_host, ports_to_scan, { timeout: 0.01 })
  end
  
  x.compare! # This will compare the ips for all 'x.report' blocks
end
puts "Benchmark finished."
