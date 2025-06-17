Gem::Specification.new do |spec|
  spec.name        = "hk"
  spec.version     = "0.1.0"
  spec.authors     = ["Your Name"]
  spec.email       = ["your.email@example.com"]
  spec.summary     = "Hēi Kè (HK) Security Framework"
  spec.description = "A next-generation Ruby security tool library, blending elegance and power."
  spec.homepage    = "https://github.com/yourusername/hk" # Replace later
  spec.license     = "MIT"
  spec.files       = Dir.chdir(File.expand_path(__dir__)) do
                        Dir['{bin,lib}/**/*', 'README.md', 'hk.gemspec']
                      end
  spec.bindir      = "bin"
  spec.executables = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Add dependencies as needed, e.g.:
  spec.add_dependency "thor", "~> 1.0"
  spec.add_dependency "tty-color" # For colorized CLI output
  spec.add_dependency "httparty", "~> 0.20" # For HTTP requests
  spec.add_dependency "nokogiri", "~> 1.15" # For HTML parsing
  spec.add_dependency "tty-progressbar", "~> 0.18" # For progress bars
  spec.add_development_dependency "bundler" # Using a common version constraint
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.0" # For mocking HTTP requests in tests
  spec.add_development_dependency "brakeman", "~> 5.0" # For static security analysis
  spec.add_development_dependency "rake", "~> 13.0" # For running Rake tasks
  spec.add_development_dependency "benchmark-ips", "~> 2.8" # For performance benchmarking
  spec.add_dependency "robots", "~> 0.3.0" # Using 'robots' gem, common for robots.txt parsing
end
