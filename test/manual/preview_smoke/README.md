# Manual preview regression fixtures

Synthetic files for visual regression checks of the changes in [PR #14](https://github.com/curecodejp/redmine_more_previews/pull/14), tracked in [Redmine #19143](https://redmine.curecode.jp/issues/19143).

All five test files, **including the PDF**, are checked into this directory. They contain no personal information, executable scripts, credentials, or external service dependencies. Do not run checks against production just for manual verification.

## Setup

1. Open a test-only issue in a test project on `test-lab`; confirm that `redmine_more_previews` v6.1.1 or later is installed.
2. Upload the five files from this directory to that issue as attachments.
3. Choose `inline` for Markdown and both vCards. For EML, use the `html` preview format (Cliff supports `html` only). Use the `pdf` preview format for the PDF.
4. Record results on Redmine #19143. Report the tested Redmine/plugin versions and preview format. A successful automated test suite alone does not complete the manual visual check.

## Manual checks

| File | Expected result |
| --- | --- |
| `01-markdown-links-tasklist.md` | The **Jump to section** link and footnote reference navigate to their targets. If rendered as checkboxes, task-list controls are disabled. Some Pandoc versions show task lists as plain text; record that as *not testable* rather than claiming the checkbox behavior passed. |
| `02-vcard-remote-image.vcf` | vCard text is readable. **No browser request is made** for `rmp-external-image-probe.png` when displayed `inline` (details below). |
| `03-vcard-inline-image.vcf` | The embedded `data:image/png;base64,...` PHOTO is retained and can be inspected in the rendered markup. It is a tiny test PNG, so inspect the image element if the pixel is difficult to see. |
| `04-email-long-headers.eml` | Long To, Cc, and Subject fields wrap instead of escaping the preview pane or obscuring other UI elements. |
| `05-pdf-preview.pdf` | Preview format **`pdf`**. This **repository-tracked** one-page PDF opens normally. The heading `PDF PREVIEW OK` and the three numbered rows (01-03) are visible, without CSP/sandbox blocking the viewer. Optionally repeat with `png` and record it as a separate result. |

## Confirm remote images are *not requested*

The URL in `02-vcard-remote-image.vcf` deliberately uses `https://example.invalid/rmp-external-image-probe.png`. The reserved `.invalid` domain means a successful image load cannot be expected, so **a missing photo or a failed DNS lookup is not evidence that it was blocked**.

1. On a desktop browser, open Developer Tools **before** opening the vCard attachment; select the **Network** tab and the **All** requests filter (not only successful images).
2. Clear previous network entries. Optionally enable **Persist/Preserve Logs** and **Disable Cache** to keep the record when the preview reloads.
3. Open/reload the vCard preview in **inline** mode.
4. Filter/search requests for `rmp-external-image-probe.png` or `example.invalid`. **Pass** only if no request for that resource was initiated, including failed or blocked requests. Any attempted request is a **fail** for this particular inline sanitization check.
5. As an additional check, inspect the preview's DOM in **Elements/Inspector**: the remote PHOTO must not appear with an external URL in an `img src` attribute. A sanitized `img` without `src` is acceptable.
6. Repeat with `03-vcard-inline-image.vcf` and confirm the data-URI PHOTO is preserved. There should be no external image request in that fixture either.

If the browser or Redmine configuration prevents inspecting the network/DOM, mark this test **not verified** instead of marking it passed.

## Record the outcome

On Redmine #19143, record `PASS / FAIL / NOT TESTED` per file and format, the test-lab URL or attachment IDs, browser, Redmine and plugin versions, and any screenshots or console/network evidence for failures.

The files are **manual UI fixtures**. They complement but do not replace automated security and regression tests.
