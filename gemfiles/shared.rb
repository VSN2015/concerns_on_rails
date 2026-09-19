# Development/test gems that do NOT vary across the CI matrix, eval'd by every
# gemfiles/*.gemfile. Only the Rails component gems, railties and the database
# driver differ per job; everything here is constant.
#
# KEEP IN STEP WITH THE ROOT Gemfile. The root Gemfile is deliberately left
# alone rather than made to eval this file: its Gemfile.lock is committed and
# carries the PATH pin that has to track lib/concerns_on_rails/version.rb (see
# the release process in CLAUDE.md), so restructuring it would churn the lock
# for no benefit. Adding a dev gem means adding it in both places.

# json 3.0 removed JSON.generate's :quirks_mode option, which ActiveSupport's
# JSON encoder still passes — so `render json:` raises
# `ArgumentError: unknown keyword: quirks_mode` on every Rails line this matrix
# covers (verified on 7.0 and 8.0: 31-32 failures, all in the specs that
# dispatch through the real ActionController stack). The root Gemfile.lock
# happens to hold json 2.21.2, which is the only reason the default suite is
# green; nothing actually DECLARED the constraint. This is also why the
# dependabot bump to json 3 must not be merged.
gem "json", "< 3"

gem "rake"
gem "acts_as_list", ">= 0.7.5", "< 2"
gem "faker", "~> 3.8"
gem "friendly_id", "~> 5.4"
gem "rspec", "~> 3.12"
gem "simplecov", "~> 1.1"

group :development, :test do
  gem "rubocop", "~> 1.89", require: false
end
