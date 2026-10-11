# OSS Scanner build context is the redmine_more_previews repository.
# Keep the original checkout at /src as required by the scanner.
FROM ruby:3.3.8-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    RAILS_ENV=test \
    BUNDLE_WITHOUT=development

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git build-essential libsqlite3-dev sqlite3 \
      imagemagick ghostscript pandoc libreoffice fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

COPY . /src

# Match the existing Redmine compatibility workflow.
ARG REDMINE_VERSION=6.1.5
RUN git clone --depth 1 --branch "${REDMINE_VERSION}" \
      https://github.com/redmine/redmine.git /redmine \
    && mkdir -p /redmine/plugins/redmine_more_previews \
    && cp -a /src/. /redmine/plugins/redmine_more_previews/ \
    && rm -rf /redmine/plugins/redmine_more_previews/.git

WORKDIR /redmine

RUN printf 'production:\n  adapter: sqlite3\n  database: db/redmine.sqlite3\ntest:\n  adapter: sqlite3\n  database: db/redmine_test.sqlite3\n' > config/database.yml \
    && if ! grep -q "gem 'minitest'" Gemfile; then \
         printf "gem 'minitest', '< 6.0'\n" > Gemfile.local; \
       fi \
    && bundle config set --local without development \
    && bundle install --jobs 4 --retry 3

# Create a disposable SQLite database; no production data or secrets are used.
RUN bundle exec rake db:migrate \
    && bundle exec rake redmine:plugins:test NAME=redmine_more_previews

# Useful tools and checkout stay available when the offline scan starts.
WORKDIR /src
