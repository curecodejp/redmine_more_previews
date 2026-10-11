# OSS Scanner build environment

This directory contains the Dockerfile used by Anthropic OSS Scanner.
It is separate from the production Redmine installation.

## Build locally

From the repository root:

```sh
docker build -f .oss-scanner/Dockerfile -t redmine-more-previews-scanner .
```

The build downloads Redmine 6.1.5 and its Ruby gems, installs the plugin,
prepares a disposable SQLite database, and executes its test suite. This
requires network access **during the build**. The scanner operates offline
afterward, with the plugin checkout available at `/src` and Redmine at
`/redmine`.

## Inspect the image

```sh
docker run --rm -it --network none redmine-more-previews-scanner bash
```

In the container, `cd /redmine` and use `bundle exec rails runner ...`
or `bundle exec rake redmine:plugins:test NAME=redmine_more_previews`
for plugin analysis.

## Notes

- This is a test-only environment. It uses no production database, credentials,
  or real customer files.
- Redmine 6.1.5 / Ruby 3.3.8 matches the project's compatibility CI.
- Conversion tools are installed for analysis; do not treat this as a
  production-ready, hardened Redmine image.
- Confirm ImageMagick/Ghostscript versions and policies before running
  malicious document samples. Resource limits and network isolation matter.
- The Dockerfile has not yet been validated on a Docker-enabled host.
