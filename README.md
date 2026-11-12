# Redmine More Previews

Preview files directly from **Redmine issue attachments, documents, files, and repository entries**. This plugin adds optional converters for office documents, email, archives, Markdown, images, PDFs, and vCards, so users can inspect content without manually downloading every file.

**Current release:** [v6.1.9](https://github.com/curecodejp/redmine_more_previews/releases/tag/v6.1.9) · [Release notes](#change-log) · [Security advisories](https://github.com/curecodejp/redmine_more_previews/security/advisories)

> [!NOTE]
> This is a **Cure Code Corp.-maintained fork**, based on [JVsup's fork](https://github.com/JVsup/redmine_more_previews) of the [original project by HugoHasenbein](https://github.com/HugoHasenbein/redmine_more_previews). It is not an official upstream release. The inherited license is **GNU GPL v2.0 or later**. General-purpose fixes can be proposed upstream separately.

## Features at a glance

| Converter | Preview content | Requirements / notes |
| --- | --- | --- |
| **Libre** | Office documents, spreadsheets, presentations, CSV | LibreOffice with a Linux `bubblewrap` sandbox; see [the requirements](#libre-converter-sandbox) |
| **Cliff** | Email (`.eml`, `.mime`) and attachments | Mail headers, body, and attachments. Time and memory bounds require process isolation; without Ruby `fork`, these bounds do not apply. See [Converter details](#converter-details) |
| **Mark** | Markdown, Textile, HTML | [Pandoc](https://pandoc.org/) |
| **Zippy** | ZIP, TAR, TGZ archives | Browse archive listings and download individual entries |
| **Maggie / Peek** | Images and PDF previews | ImageMagick; Ghostscript for PDF rendering; libheif for HEIC/HEIF (see [Maggie](#converter-details)) |
| **Vince** | vCard (`.vcf`) | Requires Ruby `fork`. Child-process timeout; 512 MiB additional-memory budget is enforced only on supported Linux hosts |
| **Pass** | HTML passthrough | Optional converter |
| **Teddie** | Plain text (`.txt`) | Text preview |
| **NilText** | Diagnostic output | **Development only. Do not enable in production.** |

Select which converters, file types, and output formats to enable in the plugin settings. Some converters support multiple formats such as HTML, inline HTML, text, PDF, and images. [Converter details](#converter-details) explain dependencies and limitations.

## Compatibility

| Component | Supported / verified |
| --- | --- |
| **Redmine** | 6.0.x and 6.1.x; CI verified on **6.0.11 and 6.1.5**. For PDF previews with Maggie / Peek, use **6.0.10 / 6.1.3 or later**; see [Converter details](#converter-details) |
| **Ruby** | 3.3.x verified (CI: **3.3.8**); other Ruby versions have not been verified |
| **Plugin release** | **6.1.9** |
| **Operating system** | Converter-specific; **Libre needs Linux and working `bubblewrap`**; Vince requires `fork`, and its memory monitoring needs Linux `/proc` support |

Redmine 7 is **not yet verified** by this fork. Support for a Redmine release does not imply that every optional converter is available on every operating system.

## Getting started

### Install

From the Redmine installation directory, install the maintained release into `plugins/`:

```bash
cd /path/to/redmine
git clone --branch v6.1.9 https://github.com/curecodejp/redmine_more_previews.git plugins/redmine_more_previews
bundle install
```

Install the external programs needed by the **converters you intend to enable** (for example, Pandoc for Mark or supported LibreOffice and `bubblewrap` for Libre). Restart the Redmine application using the method appropriate to your deployment. For Passenger, from the Redmine root, `touch tmp/restart.txt` requests an application restart.

### Upgrade an existing installation

Back up your Redmine configuration and check for local plugin changes before updating. The [installation command above](#install) selects the `v6.1.9` tag, so its checkout has a **detached HEAD**, not a `main` branch.

**Before fetching**, check which repository `origin` points to:

```bash
cd /path/to/redmine
git -C plugins/redmine_more_previews status -sb
git -C plugins/redmine_more_previews remote -v
```

If migrating from the original upstream or JVsup fork, change `origin` **before** fetching:

```bash
git -C plugins/redmine_more_previews remote set-url origin https://github.com/curecodejp/redmine_more_previews.git
```

Once `origin` points to `https://github.com/curecodejp/redmine_more_previews.git`, upgrade a *tag-pinned* installation from an earlier release (for example, v6.1.8):

```bash
git -C plugins/redmine_more_previews fetch --tags origin
git -C plugins/redmine_more_previews switch --detach v6.1.9
bundle install
```

Do not run `git pull origin main` from a tag checkout: that moves the detached checkout to the development branch's tip.

**If your installation intentionally tracks `main`:** With `main` checked out, run `git -C plugins/redmine_more_previews pull --ff-only origin main` in place of the fetch/switch commands, then run `bundle install`.

**Before restarting**, check the version you are upgrading **from**:

- **6.1.3 or later:** Cached previews are versioned and regenerated as needed; no full cache purge is normally needed.
- **6.1.8 or earlier:** 6.1.9 changes the preview cache format, so every preview is converted again when it is first viewed after the upgrade. This also renews Zippy listings cached by 6.1.7 or earlier, whose links showed the login page inside the frame. The older cache files stay on disk until the cache cleanup removes them.
- **6.1.2 or earlier, including older upstream/JVsup builds:** Read the **6.1.3 Upgrade precaution** in the [Change-Log](#change-log). If converter debug mode was ever enabled, stop Redmine and preview workers and carefully clear the *plugin's actual preview cache directory* before restarting, because old diagnostic files may still contain sensitive data. The routine age-based cache task does not immediately remove all such files. Verify the directory path before deletion.
- **Libre enabled:** Review the [Linux `bubblewrap` sandbox requirements](#libre-converter-sandbox); conversion fails closed without a working sandbox.

Restart Redmine using your deployment's standard method. For Passenger, run `touch tmp/restart.txt` from the Redmine root. Then confirm **Redmine More Previews 6.1.9** under *Administration → Plugins*.

### Configure and enable

1. Open **Administration → Plugins → Redmine More Previews → Configure**.
2. Enable only the converters and file extensions needed. Enable each file extension in **one converter only**: if the same extension is enabled in multiple converters (for example, PDF in both Maggie and Peek), the settings page warns and only one converter handles it. Choose the preview format for each file type, and review the conversion time, concurrency, cache, and output-size limits.
3. Enable the **Redmine More Previews** module in **Project → Settings → Modules** for existing projects. For new projects, select it under **Administration → Settings → Projects → Default enabled modules for new projects**.

For Vince, `html` is a reasonable initial preview format. The `inline` option embeds converter HTML in Redmine pages and is sanitized before display. On large or untrusted input, prefer the isolated HTML preview while reviewing [resource limits](#a-note-on-conversion-limits).

Project-module screenshots: [defaults for new projects](https://github.com/user-attachments/assets/91832e0c-e5ba-4780-a99d-ca36f218ac72) · [settings for existing projects](https://github.com/user-attachments/assets/1d4b2299-34ab-413d-8f58-1ae368eaf94b)

### Uninstall

Remove the `plugins/redmine_more_previews` directory during a maintenance window and restart the Redmine application. Remove any scheduled `redmine_more_previews:cache:clean` jobs, then review and delete the plugin's cache storage (default: `<Redmine root>/tmp/more_previews`, or your customized location). Verify the path before removing any files.

## Security and operational notes

Security advisories and their fixed versions are published under [Security](https://github.com/curecodejp/redmine_more_previews/security/advisories). In **v6.1.5**, Vince vCard parsing and rendering run in an isolated child process with a timeout; the **512 MiB additional-memory limit is enforced only on supported Linux hosts** with the required `/proc` facilities. Inputs larger than 20 MiB are rejected, and previews fail closed on platforms without `fork`. On fork-capable non-Linux platforms, a child process and timeout are available but this memory limit is not enforced. See [GHSA-hm82-jvvw-hmg4](https://github.com/curecodejp/redmine_more_previews/security/advisories/GHSA-hm82-jvvw-hmg4).

> [!IMPORTANT]
> The **Libre** converter requires an operational **Linux `bubblewrap` sandbox** and a supported system LibreOffice installation. It does not fall back to unsandboxed conversion. Test sandbox availability as the Redmine service user before enabling Libre. **Never enable NilText in production.**

Read [the Libre sandbox setup](#libre-converter-sandbox), [cache management](#a-note-on-caching), and [conversion limits](#a-note-on-conversion-limits) before enabling previews of files from untrusted users.

## Compatibility testing

Pull requests run automated smoke tests against Redmine 6.0.11 and 6.1.5 with Ruby 3.3.8. The workflow installs the plugin into a clean Redmine checkout, resolves the Redmine bundle with SQLite, migrates the database, boots Rails, verifies that the Mark and Zippy converters are registered, checks `marcel`, `rubyzip`, and `zlib`, asserts each Redmine release's `rubyzip` requirement, and performs a basic Pandoc Markdown conversion.

---

## Libre converter sandbox

> **Upgrade warning:** The hardened Libre converter is **Linux-only** and requires a
> working `bubblewrap` (`/usr/bin/bwrap`) with unprivileged user, mount, PID,
> network, IPC and UTS namespaces. It **does not fall back** to an unsandboxed
> LibreOffice when isolation is unavailable. Windows Libre conversions are
> unavailable until an equivalent OS-level sandbox is implemented.
>
> Install a distribution-packaged LibreOffice exposing `/usr/bin/soffice` and
> `/usr/bin/env`, plus the `bwrap` package. This version does **not** support the
> [historical JVsup fork notes](#historical-jvsup-fork-notes-605) installation of TDF `.deb` files in `/opt/libreoffice25.8` via
> PATH alone. Migrate to a supported system package before enabling Libre.
>
> The sandbox mounts only the input file, a per-conversion writable output and
> Libre profile, plus known read-only system paths: `/usr/bin`, `/usr/lib`,
> `/usr/lib64` when present, selected `/usr/share` resources, `/etc/fonts`,
> `/etc/ld.so.cache`, optional `/etc/libreoffice` and `/etc/alternatives`, and
> `/bin`, `/sbin`, `/lib`, `/lib64` according to the host's merged-usr layout.
> It does not mount `/` or `/etc` as a whole. Installations with different
> filesystem layouts or extra LibreOffice dependencies must be tested and may
> fail closed. User namespaces can be unavailable in Docker despite `bwrap`
> being installed (for example, due to container seccomp restrictions).

Check sandbox support as the actual Redmine service user before enabling the
Libre converter. Run a benign conversion in a disposable staging environment;
the status check runs a bounded namespace probe, but is not a substitute for
end-to-end conversion testing. Verify with at least ODT/DOCX to PDF/HTML and
check that external file references are not embedded in the output.

The cache identity is deliberately changed because old PDFs may contain data
loaded from the host. Old caches are no longer served, but their on-disk files
remain until they are encountered or a cache-clean task removes them. For a
planned maintenance-window purge of all preview caches, use the deliberately
opt-in command below, which skips previews locked by active requests:

```bash
cd /path/to/redmine
bundle exec rake redmine_more_previews:cache:clean RAILS_ENV=production DAYS=0 CONFIRM_PURGE_ALL=1
```

**Warning:** This purges all eligible preview caches, not only old Libre PDFs.
Subsequent previews must be regenerated. The normal `DAYS=30` cleanup remains
unchanged.

## Converter details

Depending on the converter and input type, output can be configured as PDF, PNG/JPG/GIF, HTML, inline HTML, text, or XML.
 
The appropriate conversion type(s) is/are up to the plugin developer. The available conversion option can be chosen on the plugin configuration page. 
The plugin was developed with thread safety in mind. With caching enabled, it should stand even higher loads.

The following converter descriptions include details of their supported file types:

---

![Libre](doc/libre/logo.png "Libre")

The hardened Libre 1.1.4 converter requires Linux, `/usr/bin/soffice`, `/usr/bin/bwrap` and permission to create unprivileged namespaces as the Redmine service user. See [Libre converter sandbox](#libre-converter-sandbox).

Libre uses LibreOffice to do the conversion. Libre converts almost everything LibreOffice can convert:

.csv , .doc , .docm , .docx , .dotm , .dotx , .fodg , .fodp , .fods , .fodt , .odb , .odc , .odf , .odg , .odi , .odm , .odp , .ods , .odt , .otg , .oth , .otp , .ots , .ott , .oxt , .potm , .potx , .ppt , .pptm , .pptx , .rtf , .sda , .sdc , .sdd , .sdp , .sds , .sdw , .sgl , .smf , .stc , .std , .sti , .stw , .sxc , .sxd , .sxg , .sxi , .sxm , .sxw , .vor , .xls , .xlsm , .xlsx , .xltm , .xltx 

The hardened Libre converter supports `pdf`, `html`, `txt`, `png` and `jpg` conversion outputs (subject to each input format).

Not all LibreOffice input/output format combinations have been tested for this release. Test the document formats and output types used by your installation before enabling Libre. Conversion fidelity depends on the LibreOffice build, available import/export filters, and installed fonts.

Historically reported as tested in the upstream project (not independently re-verified for this release): .csv, .doc, .docx, .ppt, .pptx, .xls, .xlsx, .odt, .rtf.

---

![Cliff](doc/cliff/logo.png "Cliff")

This plugin requires no additional software to be installed on your system. 

Cliff converts

.mime, .eml 

to html.

You can view the .eml file almost like in a professional email viewer, see mail headers and download attachments. Cliff filters scripts, event-handler attributes, CSS `url()` references, and external images from email previews. Only administrators can request an unsafe preview, and they should do so only for trusted `.eml` or `.mime` files.

An email larger than 50 MiB, with more than 1,000 MIME parts, or with multipart parts nested more than 100 levels deep or adding up to more than five times the size limit is not previewed, and at most 1,000 attachments are extracted (the others are counted in the list). The size, parts and attachments limits can be changed in Cliff's settings. On platforms with Ruby `fork` support, Cliff parses an email in a child process within the conversion time limit and with a 1 GiB additional-memory budget (monitored on supported Linux hosts). On Windows or without `fork`, parsing runs in the Redmine worker **without those process time and memory limits**; do not enable untrusted email previews there without an equivalent isolation mechanism. The Mail library can take many times the size of an email to parse some of its lines.

---

![Mark](doc/mark/logo.png "Mark")

Mark uses Pandoc to do the conversion. Currently supported is:

.md, .textile, .html

---

![Peek](doc/peek/logo.png "Peek")

Peek lets you preview pdf-Files in the browser. Peek uses imagemagick to do the conversion. Imagemagick uses Ghostscript as a delegate to handle pdf files. Pdf previews can be the full pdf or a png, jpg or gif of the first page. Please note, that the conversion resolution strongly depends on your ImageMagick's configuration in the delegates file. Please consult ImageMagick's configuration help to edit the delegates file.

---

![Zippy](doc/zippy/logo.png "Zippy")

Zippy lets you preview zip, tgz or tar-Files in the browser. Click on an entry to download one individual file from within the compressed file.

A zip with more than 10,000 entries is not opened, and the list of a tar or tgz ends after 10,000 entries or 1 GiB unpacked. A file larger than 100 MiB is not extracted, and at most 1 GiB of files is stored per archive; larger requests are answered with `413`. The limits can be changed in Zippy's settings.

---

![Maggie](doc/maggie/logo.png "Maggie")

Maggie converts images from one format to another and downscales images.

Maggie hands uploaded files and repository files to ImageMagick, and PDF files to Ghostscript through ImageMagick. It reads each file with the coder of its type, passes a PDF only when the file starts as a PDF, and limits ImageMagick's pixel cache (width and height 16K pixels, disk 1 GiB): an image wider or higher than 16K pixels, f.i. a large panorama, is not previewed. The limits do not bound Ghostscript's rendering of a PDF page: the time limit of the conversion stops it (see [a note on conversion limits](#a-note-on-conversion-limits)). Peek converts the first page of a PDF to an image with the same limits, after the same check of the start of the file. Since both programs parse untrusted files:

 - use Ghostscript 10.03.1 or later: earlier versions have known -dSAFER bypasses
 - use Redmine 6.0.10 / 6.1.3 or later: the PDF thumbnails of earlier versions can pass PostScript to Ghostscript ([Redmine issue 44145](https://www.redmine.org/issues/44145))
 - disable the coders that no preview needs in ImageMagick's `policy.xml`, f.i. `<policy domain="coder" rights="none" pattern="{PS,PS2,PS3,EPS,EPI,EPSI,EPSF,MVG,MSL,TEXT,URL,HTTP,HTTPS,FTP}" />`. Keep `PDF` enabled if PDF previews are wanted. This does not stop PostScript that reaches Ghostscript through the PDF coder; the check of the start of the file does.

**HEIC/HEIF and TIFF.** Maggie previews HEIC/HEIF images (f.i. iPhone photos) and TIFF images (f.i. scans), which browsers other than Safari do not show. It converts the first image only: the primary image of a HEIC file, the first page of a TIFF file. There is no list of the other images or pages. The image is shown upright: libheif applies the rotation of a HEIC image, Maggie applies the orientation of a TIFF image, and the EXIF orientation is removed from the preview so that the browser does not rotate it again. AVIF and WebP images are not converted: browsers show them themselves.

 - **What ImageMagick needs.** For HEIC/HEIF, ImageMagick's HEIC coder with libheif and a HEVC decoder plugin (f.i. on Ubuntu 24.04 `libheif1 libheif-plugin-libde265`; other distributions may package the HEIC coder of ImageMagick separately). For TIFF, the TIFF coder (libtiff), which most ImageMagick packages include.
 - **HEIC on Enterprise Linux.** Fedora ships libheif without a HEVC decoder. On EL9, a HEVC decoder for libheif comes with `libheif-freeworld` from RPM Fusion (libheif 1.23, libde265 1.0.15 at the time of writing). On EL8, neither the distribution, EPEL nor Remi provides libheif, which Remi's `ImageMagick-heic` needs, and RPM Fusion has only libheif 1.7.0 (2020). Previews parse files that anyone who can attach files supplies, so do not enable HEIC with that version: leave HEIC disabled on EL8.
 - **Patents and licenses.** libheif and libde265 are licensed under the LGPL. HEVC is covered by patents, which is why some distributions do not ship a HEVC decoder. This plugin contains no decoder: whoever installs one checks whether it may be used for their purpose.
 - **How to check.** `convert -list format | grep -E 'HEIC|TIFF'` (ImageMagick 7: `magick -list format | grep -E 'HEIC|TIFF'`) must list the format with an `r` in the mode column, f.i. `HEIC* HEIC rw+`. The `heic` in the delegates line of `convert -version` does not tell whether ImageMagick reads HEIC.
 - **Which program runs.** The program Redmine's `imagemagick_convert_command` names in `config/configuration.yml`, `convert` (ImageMagick 6) unless it is set; set it to `magick` to use ImageMagick 7. The Maggie settings show the program and whether it reads each format. The check runs once per Redmine process: restart Redmine after installing a coder.
 - **Where ImageMagick cannot read them.** While Maggie is enabled, the settings cannot be saved with HEIC/HEIF or TIFF enabled for it, and a preview is never converted: the preview fails as for a broken image, and the other formats are converted as before. If ImageMagick loses the coder later (f.i. after an upgrade), uncheck the format to save the settings again. A `policy.xml` that denies the coder fails the conversion in the same way; do not open the policy for previews. `-list format` may list HEIC where libheif has no HEVC decoder plugin: the settings are then saved, and the conversions fail.
 - **What is checked.** Maggie converts a file only when the format is enabled, the file starts as that format and ImageMagick reads it: a HEIC/HEIF file must name HEVC brands and no AVIF brand, a TIFF file must start with a TIFF header. The codec of the image inside a HEIC file is not checked: a file with HEVC brands that holds an AV1 (or other) image is decoded if libheif has a decoder for it.
 - **Limits.** libheif and libtiff allocate memory of their own for the whole image while decoding it, outside the ImageMagick limits: some bytes per pixel, about 6 for a 10-bit HEIC image, so 64 megapixels take about 400 MB, times the number of conversions that run at the same time. Maggie therefore reads the size the file declares before it converts it: the coded size of the primary image of a HEIC file (its `ispe` property), the width and height of the first page of a TIFF file. An image larger than **Largest HEIC or TIFF image** in the Maggie settings (default 64 megapixels, which 48 and 50 megapixel phone photos and A4 scans at 600 dpi pass) is answered with `413`; raise the limit for larger scans (A3 at 600 dpi is 70 megapixels) where the server has the memory. A value that is not a whole positive number uses the default. The limit is checked when an image is converted: a preview converted before the limit was lowered is still served from the cache. A refusal is remembered like any failed conversion (10 minutes by default), so after the limit is raised the image is shown when that time has passed, or at once when an administrator uses *Update*. A file whose size cannot be read is not converted, f.i. a HEIC sequence without a primary image, a HEIC file whose `meta` box is larger than 1 MiB, that has more than one `meta` box, or that has more than 16 top-level boxes, or a TIFF file that gives its width or height as more or fewer than one value. The size is the one the file declares, so this is not a hard memory limit: a crafted file may code a larger image, and only the time limit of the conversion stops it. What bounds the memory is the number of conversions at the same time (`max_conversions`, see below) and the memory of the server. The ImageMagick limits apply as for the other images (an image over 16K pixels wide or high is not previewed).

---

![Pass](doc/pass/logo.png "Pass")

Pass lets you pass through html.

---

![Vince](doc/vince/logo.png "Vince")

Vince lets you preview .vcf (vCard) files.

A vCard larger than 20 MiB is not previewed (`413`). On platforms with Ruby `fork`, Vince parses and renders a vCard in a child process under the conversion timeout. On supported Linux hosts, the additional-memory budget is 512 MiB (using `/proc` monitoring and an address-space limit); on other fork-capable platforms, that memory budget is not enforced. On platforms without `fork`, Vince previews are unavailable.

---

![NilText](doc/nil_text/logo.png "NilText") *DO NOT USE IN PRODUCTION* 

NilText is a development and diagnostics converter for understanding the plugin's conversion interface; **do not enable it in production**. Current debug previews expose only the allowlisted metadata fields `converter`, `converter_version`, `plugin_version`, `source_type` and `preview_format`, rather than arbitrary internal objects or repository credentials. Even limited diagnostic metadata should not be exposed to end users. NilText is **disabled by default**. If diagnostic previews were enabled on older versions, legacy cache files can remain on disk: follow the cache-removal upgrade precaution in the [6.1.3 Change-Log](#change-log).

---

## Localization

* English
* German
* Spanish
* French
* Japanese
* Portugese (Brazil)
* Portugese
* Russian
* Chinese

Native speakers: please help to improve localizations

## Change-Log

**6.1.10** (unreleased)

- A preview is requested in the output format configured for the file's converter only. A request for another format (f.i. `/attachments/more_preview/ID.pdf` for a file previewed as HTML) is answered with `404` before anything is converted: before, each such format ran the whole conversion, left a cache directory that was never served and remembered a failure.
- The converter, the output format, the cache directory and the URL of a preview are decided once, on the content of the file. A file whose content and extension disagree (HTML, an email or a zip archive saved as `.txt`, with a converter of both types enabled) is now previewed in the format of its converter; it was answered with `404`. On the page of a repository file, the entry is now read once for this, also when the preview is not HTML.
- A request for the preview of a repository file asks the repository for the file once (git starts `git ls-tree` each time); it asked six times for a preview, and more than twenty times for the page of an email. The page of a file asks once more, for the directory it is in (the links to the next and previous files). A stored preview is served without writing the file to a temporary file first, and the file a conversion is given is no longer left open.
- Deleting an attachment removes its previews also when its file stays because another attachment shares it; they were left in the cache. Redmine removes the file and its thumbnails itself again: the plugin replaced that with a copy of an older version.
- Every page had an empty `<style>` element, and the plugin replaced `Redmine::MimeType.css_class_of`, for icon styles of Redmine before 6.0, which the plugin does not support. Both are removed.
- For the authors of converters: the file of a repository entry (`source`) is written just before `convert`, and does not exist yet when `valid` is called; `preview` is given the path of the file (a String) instead of a `File`; `unique_id` is a method, found when it is called (the instance variable is not set beforehand).
- The page of a file takes over only `reload` and `unsafe` from its query, into the URL of its preview. Other parameters of the query were taken over into that URL, and into the options of a preview converted inline.
- **Zippy:** an archive is listed as what its content is (a zip archive named `.tar`, a tar archive named `.tgz`), where that kind of archive is enabled.
- **Zippy:** the links of a listing shown inline on the page of an attachment give the entries; they gave the page, saved under the name of the entry. Listings cached before are listed again when they are first viewed (the previews of the other converters are kept).
- **Zippy:** the walk through a tar or tgz archive stops at the time limit of the conversion, as a command does; it was bounded by the number and the size of the entries only.
- **Zippy:** names of entries written in CP932 (as Windows in Japan writes them in zip archives) are shown in Japanese where they read as Japanese names; they were garbled. Other names are shown as before. An entry is still saved under its name as it was guessed before.
- **Maggie:** an animated GIF previewed as PNG or JPEG is its first frame; the conversion failed. Previewed as GIF, it keeps its frames.
- **Mark:** converts to the configured format, as the other converters do, not to the format of the request.
- **Cliff:** the header boxes and the *unsafe* link are shown for the file Cliff converts, also under another extension.
- **Vince:** parts of a contact were missing or broken: a line longer than 1000 bytes was cut (a long photo or note), a grouped property (`item1.EMAIL`, as Apple's contacts write it) was not shown, a line folded with a tab or within a parameter was not joined, and a quoted parameter value with `:` or `;` broke its line, as did an empty parameter (`TEL;TYPE=cell;:`). A telephone number written as text (`+81 3 1234 5678`) was shown empty.
- **Vince:** the organization and its units (`ORG:Company;Department`) are shown apart, the preferred values (`PREF=1`, `TYPE=pref`) first, and addresses, numbers and emails under their type (work, home, preferred; `TYPE=` in any case, or the types of vCard 2.1 such as `TEL;WORK;VOICE`); all were shown under *Other*.
- **Vince:** a large photo (a data URI or base64, up to the size limit of a vCard) is shown in the HTML preview; one of a few MiB took more memory than the conversion may take, and the contact was not previewed. Another value longer than 64 KiB is not parsed as a URI, and not shown.
- **Vince:** contacts previewed before are converted again when they are first viewed (the previews of the other converters are kept).
- The preview cache format is not changed. A cache directory left by an earlier request for another format is never served; the cache cleanup task removes it with the other previews of its age.
- **Libre:** the check of its sandbox (on the administration pages, and before each conversion) is stopped after 5 seconds, with what it started. A check that hung was not stopped: it held the conversion of the file and a conversion slot while it hung.
- Zippy 1.1.7, Mark 1.1.2, Cliff 1.1.8, Maggie 1.0.6, Vince 1.1.4, Libre 1.1.6.

**6.1.9**

- **Maggie:** preview HEIC/HEIF and TIFF images: the primary image of a HEIC file, the first page of a TIFF file, upright. They are converted only where ImageMagick reads them (HEIC needs libheif), and the settings refuse to enable them elsewhere. Check with `convert -list format` (`magick -list format` for ImageMagick 7); see [Maggie](#converter-details).
- **Maggie:** a HEIC or TIFF image larger than the size set in the Maggie settings (default 64 megapixels) is not converted (`413`), because libheif and libtiff allocate memory for it outside the ImageMagick limits. Maggie reads the size from the header of the file first, and does not convert a file whose size cannot be read.
- A file is still matched by its content first; of the extensions of its type (f.i. `tif` and `tiff`), and of `heic` and `heif` (a HEIC file may be detected as HEIF and the other way round), the output format and the switch of the file's own extension apply.
- HEIC/HEIF and TIFF are off after the upgrade: enable them in the Maggie settings where ImageMagick reads them.
- **Cliff, Libre:** the images of HTML previews of emails and office documents are shown in projects that are not public. The preview frame is sandboxed, so the browser sends no session with the requests it makes, and linked images were refused. PNG, JPEG, GIF, WebP and BMP images, judged by their content, are now embedded in the page while it stays within the largest preview size (Cliff embeds no more than twice the size of the email). Other images are linked as before.
- Repository previews: the images an HTML preview links to are served again; their names were refused as absolute paths.
- The preview cache format changes: previews cached by earlier releases are converted again when they are next shown.
- Maggie 1.0.5, Cliff 1.1.7, Libre 1.1.5.

**6.1.8**

- Preview frames: when the plugin is set to use `<iframe>`, text longer than the frame can be scrolled. Non-HTML frames no longer have `scrolling="no"`.
- Preview frames: text and PDF frames now fit the window rather than being sized by their width, in both `<iframe>` and `<object>` modes. On a wide screen the page no longer has to scroll as well as the frame.
- Inline previews: no longer fail with `NoMethodError` when the Vince converter directory has been removed.
- Image previews: show a message instead of a broken image when the preview fails to load, for example for an image beyond the conversion's size limits.
- **Zippy:** the HTML listing is sent as UTF-8 (`Content-Type: text/html; charset=utf-8`). Browsers had to guess its encoding and showed non-ASCII headings garbled, for example in Japanese. Listings already cached are fixed too. Previews of uploaded HTML are sent as before.
- **Zippy:** an archive entry named like the HTML listing (`index.html` at the top of the archive, or anything below a directory of that name) can be downloaded. It used to answer 404 or fail.
- **Zippy:** clicking a file in an archive listing downloads it. The link was followed inside the sandboxed frame, where no session cookie is sent, so the frame showed the login page. The links now open in the top window, and the listing's sandbox allows that after a click. A listing cached before the update keeps the old links until it is converted again; see [Upgrade an existing installation](#upgrade-an-existing-installation).
- The preview cache format is not changed, so previews cached by 6.1.7 are kept.
- Zippy 1.1.6.

**6.1.7**

- **Cliff:** decode email text and HTML bodies to UTF-8 according to their declared charset. This includes ISO-2022-JP, Shift_JIS, Windows-1252 and common transfer encodings.
- **All converters:** bump the preview cache format marker, so cached previews of every converter are converted again when first viewed; older cache files may remain on disk until cache cleanup.
- **Inline HTML safety:** show a localized notice rather than failing the whole page when Nokogiri rejects unusually deep elements or excessive attributes. Cache successfully sanitized inline HTML in a process-local memory store (32 MiB per worker, 1-hour expiry) to avoid repeated sanitization. Preview-cache-disabled requests do not populate this cache; cold-cache parsing work still occurs.
- **PDF display and downloads:** restore full-height PDF iframes, including PDF output from Word/Excel. When saving a PDF preview, suggest the original document's basename with `.pdf` instead of the internal `index.pdf`. Include the suggested PDF name in conditional request ETags so browsers refresh filename metadata.
- **Benchmarks:** separate actual inline HTML sanitization from early 256 KiB limit rejection, and exclude one-time warmup from measured work.
- No changes to the 256 KiB inline HTML limit or the LibreOffice `bubblewrap` sandbox requirements. Known limitation: non-HTML iframe previews use `scrolling="no"`; long plain-text previews may not scroll within the frame in some browsers (not yet visually verified).
- Cliff 1.1.6.

**6.1.6**

- Inline previews: HTML larger than 256 KiB is not sanitized, cached or embedded in the page; the page shows a size notice instead. Previews cached by earlier versions are checked against the same limit when they are read.
- Cliff: the email header, field and attachment fragments embedded in a page are limited to 256 KiB each. An oversized fragment shows the size notice on the page and answers `413` when requested directly, also to a conditional request for a fragment cached by an earlier version.
- Cliff: keep the email headers, fields and attachment list in their boxes when an email is converted without the cache (cache disabled or full, an administrator's reload, another language), and show the size notice instead of replacing the attachment or repository page with `413` when an email is beyond Cliff's limits.
- Clarify the welcome text and the Teddie converter description, improve the README for Redmine 6.0/6.1 users, and add an opt-in benchmark script for the inline sanitizer (`scripts/benchmark_inline_preview.rb`).
- Cliff 1.1.5.

**6.1.5**

- Vince: parse and render vCards in a child process with the conversion time limit and a **Linux-enforced** memory budget, and refuse vCards larger than 20 MiB (`413`) (GHSA-hm82-jvvw-hmg4). Remove a stray `%>` shown after the logo.
- Cliff: preview emails attached without a file extension, and reuse the cached email headers on attachment and repository pages instead of converting the email again.
- Preview asset routes of attachments and repositories accept asset extensions with characters other than ASCII letters and digits.
- Cliff: remove the unused legacy hook loader, hook classes and duplicate templates; namespace the top hook to match its Zeitwerk path.
- Bump the preview cache format marker so existing cached previews are regenerated; older cache files may remain on disk until cache cleanup.
- Cliff 1.1.4 and Vince 1.1.3.

**6.1.4**

- Vince: fix text humanizer callback arguments and normalize legacy PHOTO/LOGO inline image MIME types with an exact allowlist.
- Maggie: avoid caching raw PDF data under image extensions when Ghostscript is unavailable.
- Libre: fix HTML preview image links for Unicode filenames containing dots, hyphens and spaces; encode spaces as `%20`.
- Add regression tests for nested repository preview asset paths.
- Remove obsolete `jp.yml` locale files; Japanese translations continue to use `ja.yml`.
- Bump the preview cache format marker so existing cached previews are regenerated with these fixes; older cache files may remain on disk until cache cleanup.
- The LibreOffice bubblewrap sandbox requirements from 6.1.3 remain unchanged. Existing mislabelled raster caches created by earlier versions are no longer reused; review the cache-purge instructions above before purging shared or customized cache locations.

**6.1.3**

- Libre 1.1.4: run document conversions in a bubblewrap sandbox on supported Linux systems, fail closed when isolation is unavailable, validate generated files before caching, and invalidate pre-update preview caches.
- Converter debug previews now expose only safe diagnostic metadata. Cache markers and response ETags are versioned so older, potentially sensitive debug previews cannot be served after the update.
- **Upgrade precaution:** If converter debug mode has ever been enabled, old diagnostic files may still exist on disk even though this version refuses to serve them. Before putting the upgraded Redmine instance back into service, stop Redmine and its preview-conversion workers, identify the plugin's actual cache storage path (default: `<Redmine root>/tmp/more_previews`), and **clear that plugin cache directory's contents**. Verify the directory path before deleting anything, especially on installations with a customized storage location or shared storage. Preview files are regenerated on demand. The normal age-based cache-cleaning task does not promptly remove all legacy debug files.

**6.1.2**
 - Bound the time, number and size of preview conversions (GHSA-mq93-c4mm-98v3): a time limit for every conversion, at most `max_conversions` at the same time (`503` beyond), size limits for repository files, archives, emails, previews and the cache (`413` beyond), failed conversions remembered for a while, `reload` and `unsafe` for administrators only, and a rake task that cleans the cache. See [a note on conversion limits](#a-note-on-conversion-limits).
 - Vince: HTML-escape names, link only known URI schemes and build GEO map links from validated coordinates.
 - Cliff: keep Mail's warnings of unparsable header fields out of the server's stderr.
 - Cliff 1.1.3, Zippy 1.1.5, Libre 1.1.3, Peek 1.1.3, Maggie 1.0.4 and Vince 1.1.2.

**6.1.1**
 - Fix repository preview authorization to require `browse_repository` (GHSA-858f-2pxg-c64q).
 - Scope repository preview caches by repository ID, revision and content, and remove the old shared cache (GHSA-gw4x-rrqx-3v8x).
 - Validate PDF headers in Maggie and Peek; restrict ImageMagick input/output formats and resource limits (GHSA-rxp7-cw7g-6xfv).
 - Maggie 1.0.3 and Peek 1.1.2.
 - The resource-exhaustion fixes tracked for 6.1.2 are not included in this release.

**6.1.0**
 - Redmine 6.1 compatibility verified while retaining Redmine 6.0 support
 - compatibility, security hardening, and preview regression fixes
 - Plugin version set to 6.1.0 for the Cure Code maintained release

**6.0.5**
 - Forked version
 - added/fixed - most pull requests from upstream and outside fixes have been integrated.
 - added bulk actions in libre to enable/disable all mime types and group conversion selector.
 - The plugin is confirmed to work in Redmine 6.0.5 container (based on https://github.com/sameersbn/docker-redmine ). Probably will work elsewhere too. YMMV.
 - Plugin version set to 6.0.5 to match corresponding redmine release

 ---

**5.0.8**  
  - fixed File.exists? to File.exist?
  - fixed URI.esacape to URI.encode\_www\_form\_component for zippy
  - fixed long standing issue with links in zippy's inline zip file content tables
        
**5.0.7**  
  - yet another patch to please Zeitwerk
        
**5.0.6**  
  - yet another patch to please Zeitwerk
        
**5.0.5**  
  - yet another patch to please Zeitwerk
        
**5.0.4**  
  - added more include statements to please Zeitwerk
        
**5.0.3**
  - removed legacy code to please Zeitwerk
        
**5.0.2**
  - altered sequence of file loading to please Zeitwerk
        
**5.0.1**
  - fixed some new locale files
        
**5.0.0**
  - running under Redmine 5
        
**4.1.3**
  - fixed repositories controller patch not finding project
  - added support for development mode
        
**4.1.2**
  - added conditional loading of mimemgaic/overlay
  - added capability of activating on a per project base
         
**4.1.1**
  - added pagination links to attachments preview page and 
    entry (repository) preview page
  - fixed japanese localization
         
**4.0.1a**
  - added method to prevent plugin from registering, if mimemagic is not installed.
    In this case. a permanent error message is displayed.
         
**4.0.0a**
  - switched to patching existing redmine classes with 'prepend' instead of an 
    alias chain, therefore loosing compatibility with redmine versions less 
    than 4.0. Due to many redmine plugins now using the prepend method, introduced 
    with Rails 5, the coexistence of 'prepend' and an alias chain methodology,
    whereby 'prepend' and the alias chain methodology is incompatible with 
    each other, the coexistence cannot be further maintained.
         
---
         
**3.2.0**
  - added new previewer "vince" to preview vcf virtual business cards
         
**3.1.2**
  - minor code additions
         
**3.1.1**
  - added fix to zippy's Gemfile
         
**3.1.0**
  - improved rendering of conversions to images
  - added new converter Maggie, which converts images to one another
  - updated nil text comments
         
**3.0.3**
  - fixed handling filenames with whitespace for converter 'mark'
         
**3.0.2**
  - added converter named 'pass'
         
**3.0.1**
  - fixed 'File' bug for converter 'mark'
         
**3.0.0b**
  - rearranged code and files to better match zeitwerk
  - made compatible with development mode
  - beta quality
         
**2.0.11**
  - amended autoload paths
         
**2.0.10**
  - fixed broken api calls for attachment
         
**2.0.9**
  - simplified hooks views for cliff
         
**2.0.8**
  - fixed tmpfile scheme (internals)
         
**2.0.7**
  - added support for non-ascii email headers in cliff
         
**2.0.6**
  - added timezone support for mail dates in cliff
         
**2.0.5**
  - fixed dependency on mimemagick after license change
**2.0.4**
         
  - fixed mimemagick dependency after license change
         
**2.0.3**
  - fixed windows glitch for File.read
         
**2.0.2**
  - fixed virgin startup bug. On some events plugin crashes on first time use
  - removed UserInstallation parameter in libre for windows platforms
  - fixed missing assets bug
         
**2.0.1** 
  - fixed last minute issues
         
**2.0.0** 
  - Recoded and published, supports redmine 3+, redmine 4+
         
**1.0.0** 
  - Running on Redmine 3.4.6, never published

## Historical JVsup fork notes (6.0.5)

These notes describe an older fork and are **not current installation instructions**.

- Most pull requests from upstream and outside fixes have been integrated.
- Bulk actions in libre to enable/disable all mime types and group conversion selector.
- The plugin is confirmed to work in Redmine 6.0.5 container (based on https://github.com/sameersbn/docker-redmine ).
- Historical setup note, **not supported by the hardened Libre 1.1.4 converter**: LibreOffice was installed from the TDF `.deb` archive at https://ftp.bme.hu/pub/mirrors/tdf/libreoffice/stable/25.8.5/deb/x86_64/LibreOffice_25.8.5_Linux_x86-64_deb.tar.gz.
- The following critical libraries and binaries must also be added to the image: `imagemagick pandoc libxinerama1 libnss3 libfontconfig1 libxrender1 libxext6 libcairo2 libcups2 libdbus-1-3 libsm6 libice6 libx11-xcb1 libssl3`
- Historical setup note, **not supported by the hardened Libre 1.1.4 converter**: Edit `/home/redmine/redmine/config/environment.rb` to include the LibreOffice path so Redmine can find the soffice binary (adjust the path to match your specific version): `ENV['PATH'] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/libreoffice25.8/program"`
- Plugin version set to 6.0.5 to match corresponding redmine release

---

## Replaces
This plugin replaces 
 - redmine_preview_office, 
 - redmine_preview_docx and 
 - redmine_preview_pdf

## Works well with
This plugin ideally works together with
 - redmine_preview_inline
 - redmine_all_thumbnails

> [!NOTE]
> These companion plugins are recommended by the original upstream. They have not been verified with this maintained fork on Redmine 6.0 / 6.1.
 
## A note on caching
This plugin caches converted previews in the Rails temporary directory (`<Redmine root>/tmp/more_previews`). For large repositories, cached previews can use substantial disk space. Run the cache cleanup rake task documented below regularly, or place `tmp/more_previews` on storage with sufficient capacity (for example, a mount point or symlink). The cache location is **not** configurable through the plugin settings. Avoid manually deleting live preview files while Redmine is serving or converting them.

Repository previews are cached per repository, revision and file content (`tmp/more_previews/repository_previews/<repository id>/<path>/<digest>/`), so that a preview is never served for another project or another version of the file. A new directory is added for each revision and content that is previewed, and older ones are not removed by the plugin itself: remove them with the task below. To find its cache directory, a preview or asset request reads the whole file from the repository and computes its SHA-256 digest, also when the preview is already cached. A repository file larger than 50 MiB (a setting) is not read: its preview is answered with `413`, and its page is shown as Redmine shows it. So is a file whose size the repository does not report (Bazaar, CVS): it could only be checked after it has been read whole. The previews cached by 6.1.0 and earlier (`tmp/more_previews/repository/`) are removed on start.

If two users choose to reload (do a new conversion) concurrently, then thread safety is honored.

The previews cached more than 30 days ago (or `DAYS`) are removed by a rake task; using a preview does not renew it, a preview cached again starts anew. Run it regularly, f.i. daily from cron:

```
cd /path/to/redmine && bundle exec rake redmine_more_previews:cache:clean RAILS_ENV=production DAYS=30
```

A preview being converted or served is skipped and removed on the next run. The task also removes the failures remembered longer than their time.

## A note on conversion limits
The external programs a converter runs (ImageMagick, Ghostscript, LibreOffice, Pandoc, ...) are stopped when a conversion runs longer than the time limit (default 60 seconds, at least 120 seconds for Libre, which starts slowly). The programs run in a process group of their own, and the whole group is stopped, including the programs they started in turn (f.i. Ghostscript started by ImageMagick). The preview is not shown then (404). A large office document may take Libre longer than 120 seconds (f.i. a text document of several hundred pages); raise the time limit if such documents are to be previewed.

At most the configured number of conversions (default 2) run at the same time, counted over all Redmine processes (lock files in `tmp/more_previews/slots/`). A request that needs a conversion while all of them are taken, or that waits longer than the wait limit (default 5 seconds) for a preview another request is converting, is answered with `503 Service Unavailable` and `Retry-After`; reloading the page later shows the preview. A preview that is already cached is served without waiting for conversions of other files.

The number of conversions is counted with `flock` on the lock files. With many users, 503 answers get more frequent: raise the number if the server has the CPU and memory for more conversions at the same time. When several Redmine servers share `tmp/more_previews` over a network file system such as NFS, `flock` may not hold across the servers, and the number then applies to each server rather than to all of them together.

A reverse proxy in front of Redmine often gives up after 60 seconds. A first conversion that takes longer, f.i. a large office document converted by Libre, then shows an error in the browser while the conversion finishes and is cached; the next view shows it. Raise the proxy's timeout to the time limit to avoid this.

A preview is served from memory: one larger than 100 MiB is answered with `413`. A request holds the preview it serves, converted or cached, until it is sent, and the number of conversions does not bound requests for cached previews: a server may need this limit times the number of requests it serves at the same time (processes times threads, f.i. of Passenger or Puma). Where memory is short, lower the limit or the number of processes and threads. When the whole cache has grown beyond 10 GiB, new previews are converted for each request and not stored; the size of the cache is added up again at most every 10 minutes. Both limits are settings.

A preview shown inline in the page (the `inline` format, and the email headers, fields and attachment list Cliff adds above an email) is limited to 256 KiB, because Rails sanitizes it in the Redmine process, outside the limits of a conversion: a larger one shows a size notice in the page instead, and a Cliff fragment requested directly is answered with `413`. This 256 KiB limit is not a setting. While the preview cache is enabled, each Redmine process also keeps sanitized results in memory, up to 32 MiB and for one hour, so viewing the same preview again does not repeat the work. Nothing from this is written to disk, and a restart empties it. Disabling the preview cache stops storing and reading these results; those already stored expire within the hour.

A conversion that failed, timed out or was too large is remembered for 10 minutes (a setting) and not tried again meanwhile: the same request is answered at once. An asset that the cached preview does not offer (a name not in the list of an archive, or a file not among the assets stored with a preview) is answered with `404` without converting, and its failure is not remembered: only the failures of assets known to exist are. Reloading a preview, which converts it again and forgets a failure, and the unsafe preview of emails are for administrators only; for anyone else the parameters are ignored and the links not shown. A preview shown inline in the page of a file ignores the unsafe parameter for administrators as well.

On Windows, only the program started directly is stopped at the time limit, not the programs it started in turn, and Cliff parses an email within the Redmine process, with neither the time limit nor the memory limit.

## Benchmarking inline preview sanitization (test/staging only)

The opt-in `scripts/benchmark_inline_preview.rb` separates two different paths: `balanced` and `dense` exercise the sanitizer with input at or below 256 KiB, while `reject` measures the size-limit rejection without parsing the HTML. I18n and the sanitizer are initialized before timing and memory sampling, so a fresh process does not count their one-time loading as part of the measured operation. The script aborts if the chosen input unexpectedly crosses the limit. Run each case in a separate Rails process to avoid carrying allocations between measurements:

```bash
cd /path/to/redmine
RMP_BENCH_PROFILE=balanced RMP_BENCH_REPETITIONS=4000 RAILS_ENV=test bundle exec rails runner plugins/redmine_more_previews/scripts/benchmark_inline_preview.rb
RMP_BENCH_PROFILE=dense RMP_BENCH_REPETITIONS=20000 RAILS_ENV=test bundle exec rails runner plugins/redmine_more_previews/scripts/benchmark_inline_preview.rb
RMP_BENCH_PROFILE=reject RMP_BENCH_REPETITIONS=5000 RAILS_ENV=test bundle exec rails runner plugins/redmine_more_previews/scripts/benchmark_inline_preview.rb
```

The reported node counts describe the generated **source markup**, not nodes actually parsed in the rejection case. Run each case at least three times in separate Rails processes and compare the median `seconds` value, noting the range; a single measurement is susceptible to system and GC noise. Times are reported in seconds to seven decimal places so sub-millisecond rejection measurements are not rounded to zero. `VmHWM` is the process-wide high-water RSS and includes Rails startup; its change is not an exact per-sanitization memory peak. The script rejects production environments, uses only synthetic HTML, and does not run automatically in normal plugin operation. Set `RMP_BENCH_DRY_RUN=1` to validate generated input sizes without loading Rails or measuring the sanitizer.
