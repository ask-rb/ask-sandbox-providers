# frozen_string_literal: true

require_relative "lib/ask/sandbox/version"

Gem::Specification.new do |spec|
  spec.name = "ask-sandbox-providers"
  spec.version = Ask::Sandbox::VERSION
  spec.authors = ["Kaka Ruto"]
  spec.email = ["kaka@myrrlabs.com"]

  spec.summary = "Sandbox providers for the ask-rb ecosystem"
  spec.description = "Isolated code execution via Local (subprocess + rlimits), " \
                     "Docker (containers), Daytona (remote sandboxes), and " \
                     "Cloudflare (Workers sandbox). Zero external dependencies " \
                     "for the Local provider."
  spec.homepage = "https://github.com/ask-rb/ask-sandbox-providers"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  # No runtime dependencies — each provider handles its own via require/autoload.
  # Daytona provider requires the `daytona` gem to be installed separately.

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "mocha", "~> 3.1"
  spec.add_development_dependency "rake", "~> 13.0"
end
