source "https://rubygems.org"

gemspec

gem 'rake'

gem "activerecord", ">= 6.0", "< 9"
gem 'acts_as_list', '>= 0.7.5', '< 2'
gem "faker", "~> 3.8"
gem "friendly_id", "~> 5.4"
# json 3.x is supported for dev/test (master runs 3.1.0, suite green); the gem passes
# allow_duplicate_key: true wherever it parses stored JSON so duplicate keys read
# last-wins as under json 2. Capped below 4 until that major is verified.
gem "json", "< 4"
# Dev/test only — the gem itself does not depend on railties; the spec suite
# exercises ConcernsOnRails::Railtie directly.
gem "railties", ">= 6.0", "< 9"
gem "rspec", "~> 3.12"
gem "simplecov", "~> 1.2"
gem "sqlite3", "~> 2.10.2"

group :development, :test do
  gem 'rubocop', '~> 1.92', require: false
end
