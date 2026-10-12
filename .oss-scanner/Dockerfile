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

# A root-level .dockerignore keeps local secrets, VCS metadata, and build
# artifacts out of the context. Build from a clean checkout as well.
COPY . /src

# Match the existing Redmine compatibility workflow.
ARG REDMINE_VERSION=6.1.5
RUN git clone --depth 1 --branch "${REDMINE_VERSION}" \
      https://github.com/redmine/redmine.git /redmine \
    && mkdir -p /redmine/plugins/redmine_more_previews \
    && cp -a /src/. /redmine/plugins/redmine_more_previews/ \
    && rm -rf /redmine/plugins/redmine_more_previews/.git

WORKDIR /redmine

# Redmine 6.1.5 already declares minitest (~> 5.27) in its Gemfile.
# Do not write another, incompatible minitest requirement in Gemfile.local.
RUN printf 'production:\n  adapter: sqlite3\n  database: db/redmine.sqlite3\ntest:\n  adapter: sqlite3\n  database: db/redmine_test.sqlite3\n' > config/database.yml \
    && bundle config set --local without development \
    && bundle install --jobs 4 --retry 3

# Run analyses and document converters without root privileges.
RUN useradd --create-home --uid 10001 --shell /bin/bash scanner \
    && chown -R scanner:scanner /src /redmine
ENV HOME=/home/scanner
USER scanner

# Test with a disposable SQLite database. Keep pathological Mail warnings
# out of the Docker build log, and cap the runtime of the complete suite.
RUN bundle exec rake db:migrate \
    && (timeout --signal=TERM --kill-after=10s 240s \
          bundle exec rake redmine:plugins:test NAME=redmine_more_previews \
          > /tmp/rmp-tests.log 2>&1; \
        status=$?; \
        cut -c1-2000 /tmp/rmp-tests.log | tail -n 60; \
        rm -f /tmp/rmp-tests.log; \
        exit "$status")

# Useful tools and checkout stay available when the offline scan starts.
WORKDIR /src
