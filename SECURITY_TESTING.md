# Security test environment

This directory setup provides a disposable Redmine instance for browser-level and parser-level testing of `redmine_more_previews`.

## Purpose

Use this environment for tests that should never be run against a production Redmine instance, including crafted HTML, Markdown, archives, PDFs, images, and Office documents.

The lab uses the Docker Official Image for Redmine 6.1.4 and installs the external tools used by the plugin, including Pandoc and LibreOffice. The repository's compatibility workflow separately verifies Redmine 6.0.5 and 6.1.4 with Ruby 3.3.8.

## Safety boundaries

- Redmine is published only on `127.0.0.1:3000`.
- The runtime Docker network is internal and has no normal outbound Internet route.
- The plugin source tree is mounted read-only.
- `/tmp` is an isolated tmpfs.
- Redmine files and SQLite data live in disposable Docker volumes.
- Never use production data, credentials, patient information, or confidential attachments in this environment.
- Do not publish proof-of-concept exploit files or confirmed vulnerability details before coordinated disclosure.

These controls reduce risk but are not a formal sandbox. A parser vulnerability that escapes the container must still be treated as a host-security risk.

## Start

```bash
docker compose -f compose.security.yml build
docker compose -f compose.security.yml up -d
```

Then open:

```text
http://127.0.0.1:3000/
```

Follow the normal Redmine first-run setup and enable More Previews for a test project.

## Verify the lab

```bash
docker compose -f compose.security.yml exec redmine ruby -v
docker compose -f compose.security.yml exec redmine bundle exec rails runner \
  'puts "Redmine #{Redmine::VERSION} / plugin #{Redmine::Plugin.registered_plugins[:redmine_more_previews].version}"'
docker compose -f compose.security.yml exec redmine pandoc --version
docker compose -f compose.security.yml exec redmine soffice --version
docker compose -f compose.security.yml exec redmine convert -version
```

## Logs

```bash
docker compose -f compose.security.yml logs -f redmine
```

## Reset everything

The following command destroys all Redmine files and the SQLite database created by the lab:

```bash
docker compose -f compose.security.yml down -v --remove-orphans
```

Rebuild after dependency or Dockerfile changes:

```bash
docker compose -f compose.security.yml build --no-cache
docker compose -f compose.security.yml up -d
```

## Planned security test areas

1. HTML and Markdown active-content handling, including stored XSS.
2. ZIP/TAR/TGZ path traversal, symlinks, oversized entries, and archive bombs.
3. Shell argument handling for crafted filenames and converter inputs.
4. MIME confusion and polyglot files.
5. Authorization of attachment and repository preview endpoints.
6. Resource exhaustion in Pandoc, LibreOffice, ImageMagick, Ghostscript, and archive parsers.
7. Regression tests for every confirmed security issue before disclosure.
