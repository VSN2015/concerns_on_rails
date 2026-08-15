require_relative "lib/concerns_on_rails/version"

Gem::Specification.new do |spec|
  spec.name          = "concerns_on_rails"
  spec.version       = ConcernsOnRails::VERSION
  spec.authors       = ["Ethan Nguyen"]
  spec.email         = ["doctorit@gmail.com"]

  spec.summary       = "Reusable Rails concerns like Sortable, Publishable, and Sluggable"
  spec.description   = "A collection of plug-and-play ActiveSupport concerns for Rails models and Rails controllers"
  spec.homepage      = "https://vsn2015.github.io/concerns_on_rails"
  spec.license       = "MIT"
  spec.metadata["license"] = "MIT"


  spec.required_ruby_version = ">= 3.2.0"

  spec.files         = Dir["lib/**/*", "bin/*", "README.md", "LICENSE.txt", "CODE_OF_CONDUCT.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  # Component gems, not the full `rails` meta-gem: the model concerns need
  # Active Record, the controller concerns Action Pack, and everything Active
  # Support — pulling in Action Cable/Mailbox/Text for every host contradicts
  # the lean-deps promise. (railties is NOT required: the Railtie only loads
  # when the host app already has it.)
  spec.add_runtime_dependency 'actionpack', '>= 5.0', '< 9'
  spec.add_runtime_dependency 'activerecord', '>= 5.0', '< 9'
  spec.add_runtime_dependency 'activesupport', '>= 5.0', '< 9'
  # Open-ended (not ~>): a ~> 0.7.5 pin was a hard Bundler conflict for any
  # host app already on acts_as_list 1.x. Both gems load lazily — only when
  # Sortable / Sluggable is actually used (see lib/concerns_on_rails.rb).
  spec.add_runtime_dependency 'acts_as_list', '>= 0.7.5', '< 2'
  spec.add_runtime_dependency 'friendly_id', '~> 5.4'

  # Merge (not reassign) so the "license" key set above is preserved.
  spec.metadata.merge!(
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/VSN2015/concerns_on_rails",
    "changelog_uri" => "https://github.com/VSN2015/concerns_on_rails/blob/master/CHANGELOG.md"
  )
end