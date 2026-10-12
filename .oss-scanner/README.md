# OSS Scanner build environment

This directory contains the Dockerfile used by Anthropic OSS Scanner.
It is separate from the production Redmine installation.

## Build locally

Use a **clean checkout** of the repository as the Docker build context.
The root `.dockerignore` excludes common local credentials, private keys,
VCS metadata, databases, and build outputs. It is a safeguard, not a
guarantee: inspect your checkout for any other sensitive files before building.

From the repository root:

```sh
docker build --progress=plain -f .oss-scanner/Dockerfile -t redmine-more-previews-scanner .
```

The build downloads Redmine 6.1.5 and its Ruby gems, installs the plugin,
prepares a disposable SQLite database, and executes its test suite. The
test command has a 240-second deadline plus a 10-second forced-kill grace
period. Its output is kept in a temporary file and only the last 60 lines,
truncated to 2,000 characters per line, are displayed. An unsuccessful test or timeout emits a warning during image build.
The GitHub Actions smoke test runs the suite separately and fails on errors.

The build requires network access; scanning can run offline afterward.
The original plugin checkout is available at `/src`, with Redmine at
`/redmine`.

## Inspect the image

```sh
docker run --rm -it --network none redmine-more-previews-scanner bash
```

The image runs as a non-root user (`scanner`). In the container,
`cd /redmine` and use `bundle exec rails runner ...` or
`bundle exec rake redmine:plugins:test NAME=redmine_more_previews`
for plugin analysis.

## Notes

- This is a test-only environment. Do not copy production databases,
  credentials, or customer files into the build context.
- Redmine 6.1.5 / Ruby 3.3.8 matches the project's compatibility CI.
- Conversion tools are installed for analysis; this is **not** a
  production-ready, hardened Redmine image.
- The non-root runtime and `--network none` reduce risk, but do not make
  arbitrary malicious documents safe. Review ImageMagick/Ghostscript
  policies and use external resource limits and disposable hosts.
- The Dockerfile was built and plugin startup verified by the
`Scanner Docker build test` GitHub Actions job on 2026-10-12.
This is not a substitute for Anthropic's official `tools/check` validation.
