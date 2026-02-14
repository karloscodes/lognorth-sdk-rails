# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "lognorth"
  spec.version = "0.1.0"
  spec.authors = ["LogNorth"]
  spec.email = ["hello@lognorth.com"]

  spec.summary = "LogNorth SDK for Rails"
  spec.description = "Send errors and logs from Rails to LogNorth for monitoring and alerting"
  spec.homepage = "https://lognorth.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/lognorth/lognorth-sdk-rails"
end
