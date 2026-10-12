# Threat model: redmine_more_previews

## Trust boundaries

This Redmine plugin renders previews of attachments, repository files, and
documents. Uploaders and repository contributors can supply untrusted file
contents, paths, MIME types, and names. Preview readers may have fewer
permissions than uploaders.

Converters include Pass/Mark (HTML, Pandoc), Cliff (email/MIME), Zippy
(archives), Libre (office documents), Maggie/Peek (images and PDF through
ImageMagick/Ghostscript), and Vince (vCard).

## Security invariants

1. Untrusted preview HTML must not execute scripts or bypass sanitization,
   CSP, sandbox restrictions, or safe response headers.
2. All preview/asset endpoints and cached entries must enforce permissions.
3. Archives and embedded paths must not escape temporary directories or
   overwrite/read arbitrary local files.
4. Preview work must have effective limits on time, CPU, memory, disk,
   archive entries, output size and subprocesses, including concurrent workers.
5. External converters must not interpret untrusted names or contents as
   shell commands or privileged URLs.
6. Reloads, unsafe modes, failed conversions and caches must not bypass limits.
7. Caches and generated assets must be isolated by project, repository,
   revision and content.

## Review areas

- Controllers, helpers and templates: authorization, preview HTML, CSP,
  inline sanitization, active-content downloads.
- Conversion infrastructure: command execution, timeout of process trees,
  global capacity, locking, cache generation and invalidation.
- ZIP/TAR/TGZ and EML parsing: expansion limits, nested entries, duplicate
  filenames and handling of partial failures.
- ImageMagick, Ghostscript, LibreOffice and Pandoc: version-dependent
  protection, sandboxing and resource consumption.

## Reporting

Prioritize demonstrated confidentiality, integrity and availability impact.
Document the entry point, needed privileges, affected versions, isolated
reproducer, root cause, suggested patch and regression test. Distinguish
confirmed issues from theoretical concerns. Use synthetic data only; do not
target production servers, real customers, or external network services.
