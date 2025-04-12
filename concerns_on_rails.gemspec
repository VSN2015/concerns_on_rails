require_relative "lib/concerns_on_rails/version"

Gem::Specification.new do |spec|
  spec.name          = "concerns_on_rails"
  spec.version       = ConcernsOnRails::VERSION
  spec.authors       = ["Ethan Nguyen"]
  spec.email         = ["doctorit@gmail.com"]

  spec.summary       = "Reusable Rails concerns like Sortable, Publishable, and Sluggable"
  spec.description   = "A collection of plug-and-play ActiveSupport concerns for Rails models and Rails controllers"
  spec.homepage      = "https://github.com/VSN2015/concerns_on_rails"
  spec.license       = "MIT"
  spec.metadata["license"] = "MIT"


  spec.required_ruby_version = ">= 2.7.0"

  spec.files         = Dir["lib/**/*", "bin/*", "README.md", "LICENSE.txt", "CODE_OF_CONDUCT.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency 'rails', '~> 5.0'
  spec.add_runtime_dependency 'acts_as_list', '~> 0.7.5'
  spec.add_runtime_dependency 'friendly_id', '~> 5.4'

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/CHANGELOG.md"
  }
end