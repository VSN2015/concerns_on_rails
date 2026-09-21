source "https://rubygems.org"

gemspec

gem 'rake'

gem "activerecord", ">= 6.0", "< 9"
gem 'acts_as_list', '>= 0.7.5', '< 2'
gem "faker", "~> 3.8"
gem "friendly_id", "~> 5.4"
# json 3 is incompatible with ActiveSupport across the whole supported range:
# AS 7.1 calls JSON.generate(..., quirks_mode: true) (removed in json 3) and
# AS 8.1 calls JSON.parse(json, options) positionally. Verified 2026-09-19:
# with json 3.0.2 the suite fails in Storable's decode path; with json < 3 it is
# green on Rails 8.1.3.1. Pinned here so Dependabot stops proposing the bump.
gem "json", "< 3"
# Dev/test only — the gem itself does not depend on railties; the spec suite
# exercises ConcernsOnRails::Railtie directly.
gem "railties", ">= 6.0", "< 9"
gem "rspec", "~> 3.12"
gem "simplecov", "~> 1.1"
gem "sqlite3", "~> 2.9.6"

group :development, :test do
  gem 'rubocop', '~> 1.89', require: false
end
