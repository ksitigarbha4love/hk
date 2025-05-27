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
  spec.add_development_dependency "bundler" # Using a common version constraint
  spec.add_development_dependency "rspec", "~> 3.0"
end
