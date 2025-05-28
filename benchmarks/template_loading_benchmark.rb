# benchmarks/template_loading_benchmark.rb
require 'benchmark/ips'
require 'fileutils'
# Ensure 'hk' library is loaded correctly.
# This might need adjustment based on how HK is structured and loaded outside of bundle exec.
# If running with `bundle exec ruby benchmarks/...`, then `require 'hk'` should work if gemspec is correct.
# Otherwise, relative paths or bundler/setup might be needed.
begin
  require 'hk'
rescue LoadError
  # This path assumes the benchmark script is run from the project root (e.g., /app/hk/)
  # If run from /app/, it would be './hk/lib/hk'
  # For `bundle exec ruby benchmarks/template_loading_benchmark.rb` from `/app/hk/`
  # this relative path should be `../lib/hk`
  require_relative '../lib/hk' 
  # require 'bundler/setup' if defined?(Bundler) # Ensure bundled gems are available if needed by HK
  # Bundler.setup is good if gems are not in default paths and script is run directly.
  # If using `bundle exec`, Bundler handles this.
end

# Setup: Create dummy template files and a directory
# Using Process.pid to make it somewhat unique if multiple benchmarks run in parallel, though full path is better
BENCHMARK_TEMPLATES_DIR = File.expand_path("../tmp/benchmark_templates_#{Process.pid}", __dir__) 
VALID_YAML_CONTENT = { 'id' => 'bench-yaml', 'info' => {'name'=>'Benchmark YAML', 'severity'=>'low'}, 'requests'=>[{'path'=>'/'}] }.to_yaml
VALID_RUBY_CONTENT = "HK.template('bench-ruby') { info name: 'Benchmark Ruby'; execute {} }"

FileUtils.mkdir_p(BENCHMARK_TEMPLATES_DIR)
File.write(File.join(BENCHMARK_TEMPLATES_DIR, "bm_yaml1.yml"), VALID_YAML_CONTENT)
File.write(File.join(BENCHMARK_TEMPLATES_DIR, "bm_ruby1.rb"), VALID_RUBY_CONTENT)
File.write(File.join(BENCHMARK_TEMPLATES_DIR, "bm_yaml2.yml"), VALID_YAML_CONTENT.gsub('bench-yaml', 'bench-yaml2'))
File.write(File.join(BENCHMARK_TEMPLATES_DIR, "bm_ruby2.rb"), VALID_RUBY_CONTENT.gsub('bench-ruby', 'bench-ruby2'))

engine = HK::TemplateEngine.new

puts "Starting Template Loading Benchmark (loading 4 templates from directory)..."
Benchmark.ips do |x|
  x.config(time: 3, warmup: 1) # Shorter time for quicker feedback in this context

  x.report("load_from_path (dir)") do
    # Clear Ruby template registry before each load if templates define same IDs or for clean state
    HK::TemplateRegistry.clear! if defined?(HK::TemplateRegistry) # Check if module is loaded
    engine.load_from_path(BENCHMARK_TEMPLATES_DIR)
  end

  # Potentially add a comparison with loading them individually if desired
  # x.report("load (individual x4)") do
  #   HK::TemplateRegistry.clear! if defined?(HK::TemplateRegistry)
  #   engine.load(File.join(BENCHMARK_TEMPLATES_DIR, "bm_yaml1.yml"))
  #   engine.load(File.join(BENCHMARK_TEMPLATES_DIR, "bm_ruby1.rb"))
  #   # ... etc.
  # end
  
  # x.compare! will only run if there are multiple reports.
  # For a single report, this line does nothing.
  x.compare! if defined?(:compare!) && x.instance_variable_get(:@reports)&.size.to_i > 1
end

# Teardown: Clean up dummy files
FileUtils.rm_rf(BENCHMARK_TEMPLATES_DIR)
puts "Benchmark finished."
