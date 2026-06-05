FROM ruby:3.2

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      libsqlite3-dev \
      libyaml-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

COPY Gemfile Gemfile.lock concerns_on_rails.gemspec ./
COPY lib/concerns_on_rails/version.rb lib/concerns_on_rails/version.rb

RUN bundle install

COPY . .

CMD ["bundle", "exec", "rspec"]
