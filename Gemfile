source "https://rubygems.org"

gemspec

gem 'rake'

gem "activerecord", ">= 5.0", "< 9"
gem 'acts_as_list', '>= 0.7.5', '< 2'
gem "faker", "~> 3.8"
gem "friendly_id", "~> 5.4"
# Dev/test only — the gem itself does not depend on railties; the spec suite
# exercises ConcernsOnRails::Railtie directly.
gem "railties", ">= 5.0", "< 9"
gem "rspec", "~> 3.12"
gem "simplecov", "~> 0.22"
gem "sqlite3", "~> 2.9.6"

group :development, :test do
  gem 'rubocop', '~> 1.89', require: false
end
