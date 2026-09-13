FROM redmine:6.1.4-bookworm

USER root

# Install the external converters used by More Previews plus a few inspection tools.
# The official Redmine image already includes ImageMagick and Ghostscript.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        file \
        libreoffice \
        pandoc \
        poppler-utils \
        unzip \
        zip \
    && rm -rf /var/lib/apt/lists/*

# Resolve plugin Gemfile dependencies at image build time. The working tree is
# mounted read-only over this path at runtime, so local source changes do not
# require rebuilding unless Gemfile dependencies change.
COPY . /usr/src/redmine/plugins/redmine_more_previews
WORKDIR /usr/src/redmine
RUN bundle install --jobs 4 --retry 3 \
    && rm -rf /usr/src/redmine/plugins/redmine_more_previews

# Keep the upstream image entrypoint/CMD. It performs Redmine database setup
# and drops privileges for the Rails process.
