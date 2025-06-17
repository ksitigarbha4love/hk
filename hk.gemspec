Gem::Specification.new do |spec|
  spec.name          = "hk"
  spec.version       = "0.1.0"
  spec.authors       = ["Your Name"] # Placeholder
  spec.email         = ["your.email@example.com"] # Placeholder

  spec.summary       = %q{Hēi Kè (HK) Security Framework}
  spec.description   = %q{A framework for security testing and automation, including various scanners and a template engine.}
  spec.homepage      = "https://github.com/yourusername/hk" # Placeholder
  spec.license       = "MIT"

  # Ensure files are tracked by git. Update if/when new files are added.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe" # Changed from 'bin' to 'exe' as per typical gem convention
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "robots", "~> 0.3.0" # For parsing robots.txt

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
