# redmine_more_previews

> [!IMPORTANT]
> This repository is a Cure Code Corp. maintained fork focused on compatibility with current Redmine releases.
>
> - Maintained fork: https://github.com/curecodejp/redmine_more_previews
> - Based on: https://github.com/JVsup/redmine_more_previews
> - Original upstream: https://github.com/HugoHasenbein/redmine_more_previews
> - License: GNU GPL v2.0 or later, inherited from the upstream project
> - Current compatibility work: Redmine 6.0.x and 6.1.x with Ruby 3.3.x
>
> The plugin version is `6.1.0`: Redmine 6.1 compatibility has been verified, and Redmine 6.0 remains supported. Generic fixes should be contributed back upstream when practical.

## Compatibility testing

Pull requests run automated smoke tests against Redmine 6.0.5 and 6.1.4 with Ruby 3.3.8. The workflow installs the plugin into a clean Redmine checkout, resolves the Redmine bundle with SQLite, migrates the database, boots Rails, verifies that the Mark and Zippy converters are registered, checks `marcel`, `rubyzip`, and `zlib`, asserts each Redmine release's `rubyzip` requirement, and performs a basic Pandoc Markdown conversion.

---

## FORK NOTES (JVsup fork, 6.0.5)

- Most pull requests from upstream and outside fixes have been integrated.
- Bulk actions in libre to enable/disable all mime types and group conversion selector.
- The plugin is confirmed to work in Redmine 6.0.5 container (based on https://github.com/sameersbn/docker-redmine ).
- LibreOffice must be installed in the container (I am using oficial deb packages https://ftp.bme.hu/pub/mirrors/tdf/libreoffice/stable/25.8.5/deb/x86_64/LibreOffice_25.8.5_Linux_x86-64_deb.tar.gz ).
- The following critical libraries and binaries must also be added to the image: `imagemagick pandoc libxinerama1 libnss3 libfontconfig1 libxrender1 libxext6 libcairo2 libcups2 libdbus-1-3 libsm6 libice6 libx11-xcb1 libssl3`
- Edit `/home/redmine/redmine/config/environment.rb` to include the LibreOffice path so Redmine can find the soffice binary (adjust the path to match your specific version): `ENV['PATH'] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/libreoffice25.8/program"`
- Plugin version set to 6.0.5 to match corresponding redmine release

---

Redmine plugin to preview various file types in redmine's preview pane. Works for issue attachments, documents module, files module and repositories. This plugin is designed to work with own plugins. That is plugins for plugins.
To preview files this plugin converts the previewed file content to either
 - pdf
 - png, jpg or gif
 - html or inline html
 - text, or
 - xml
 
The appropriate conversion type(s) is/are up to the plugin developer. The available conversion option can be chosen on the plugin configuration page. 
The plugin was developed with thread safety in mind. With caching enabled, it should stand even higher loads.

Currently, there exist the following plugins:

---

![Libre](doc/libre/logo.png "Libre")

This plugin requires LibreOffice to be installed on your system. LibreOffice must be reachable with "soffice" to the user, the redmine service is executed by.

Libre uses LibreOffice to do the conversion. Libre converts almost everything LibreOffice can convert:

.csv , .doc , .docm , .docx , .dotm , .dotx , .fodg , .fodp , .fods , .fodt , .odb , .odc , .odf , .odg , .odi , .odm , .odp , .ods , .odt , .otg , .oth , .otp , .ots , .ott , .oxt , .potm , .potx , .ppt , .pptm , .pptx , .rtf , .sda , .sdc , .sdd , .sdp , .sds , .sdw , .sgl , .smf , .stc , .std , .sti , .stw , .sxc , .sxd , .sxg , .sxi , .sxm , .sxw , .vor , .xls , .xlsm , .xlsx , .xltm , .xltx 

to either pdf, html, inline, png, jpg or gif.

Please note, that not all conversions have been thoroughly tested yet. Please send files for a conversion test to me, if you are uncertain if your files get converted an can be viewed in a browser. Further, please note that the conversion accuracy strongly depends on the availability of installed fonts. Please consult the LibreOffice portals to see how to install fonts.

Currently, thoroughly tested are: .csv, .doc, .docx, .ppt, .pptx, .xls, .xlsx, .oddt, .rtf

---

![Cliff](doc/cliff/logo.png "Cliff")

This plugin requires no additional software to be installed on your system. 

Cliff converts

.mime, .eml 

to html.

You can view the .eml file almost like in a professional email viewer, see mail headers and download attachments. Cliff will sweep the .eml files from scripts, event attributes beginning with "on…", url() in css styles and external images. To do an unsafe preview, you can press a button do so and if you trust the .eml or .mime file

An email larger than 50 MiB or with more than 1,000 MIME parts is not previewed, and at most 1,000 attachments are extracted (the others are counted in the list). The limits can be changed in Cliff's settings.

---

![Mark](doc/mark/logo.png "##mark##")

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

---

![Pass](doc/pass/logo.png "Pass")

Pass lets you pass through html.

---

![Vince](doc/vince/logo.png "Vince")

Vince lets you preview .vcf (vCard) files.

---

![NilText](doc/nil_text/logo.png "NilText") *DO NOT USE IN PRODUCTION* 

NilText lets you see, which data are available for a file conversion. NilText not suited for production use. You can peruse this plugin to learn about the plugin functionality. Please note, that this plugin may reveal a password of a repository. Like all other plugins, **this plugin is deactivated by default**.

---

### Install

1. download plugin and copy plugin folder redmine_more_previews go to Redmine's plugins folder

2. go to redmine root folder

`bundle install`

to install necessary gems. Install LibreOffice (for Libre) and/or Pandoc for (for Mark)

3. restart server f.i.  

`sudo /etc/init.d/apache2 restart`

### Uninstall

1. go to plugins folder, delete plugin folder redmine_attachment_categories

`rm -r redmine_more_previews`

3. restart server f.i.  

`sudo /etc/init.d/apache2 restart`

### Use

* Go to Administration -> Plugins -> Redmine More Previews Configuration 

Choose the following options

 - use embed-tag or iframe-tag
 - cache previews (speeds views, may bloat your rails root's tmp folder a bit)
 - conversion limits: time limit, wait limit and number of conversions at the same time (see [a note on conversion limits](#a-note-on-conversion-limits))
 - activate sub plugins above
 - for each sub plugin activate the file extension for files you want to preview (if you choose two sub plugins converting the same file type, then a warning will be issued and the last activated sub plugin will do the conversion).

#### Enable module in any project 

Module is active but not enable in each project. To use it you need to enable to each project.

##### Global and futur project

You can enable it to all **new** project from /settings?tab=projects

![Redmine_More_Preview_Configuration_Global](https://github.com/user-attachments/assets/91832e0c-e5ba-4780-a99d-ca36f218ac72)


##### Existing project

You can enable to any **existing** project from /projects/[any-project]/settings

![Redmine_More_Preview_Configuration_Project](https://github.com/user-attachments/assets/1d4b2299-34ab-413d-8f58-1ae368eaf94b)


**Have fun!**

### Localisations

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

### Change-Log

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

# replaces
This plugin replaces 
 - redmine_preview_office, 
 - redmine_preview_docx and 
 - redmine_preview_pdf

# best with
This plugin ideally works together with
 - redmine_preview_inline
 - redmine_all_thumbnails

> [!NOTE]
> These companion plugins are recommended by the original upstream. They have not been verified with this maintained fork on Redmine 6.0 / 6.1.
 
# a note on caching
This plugin caches conversions in the Rail tmp-directory. For large repositories (f.i. firm file servers) each conversion will store a copy of the conversion file in the Rails tmp directory and thus the tmp directory may become as large or even larger as the original repository. There are two ways to handle such a situation: 1. swipe Rails tmp/more_previews directory frequently, 2. change the storage path in the plugin's init.rb file to choose a mass storage, which can handle the amount of data.

Repository previews are cached per repository, revision and file content (`tmp/more_previews/repository_previews/<repository id>/<path>/<digest>/`), so that a preview is never served for another project or another version of the file. A new directory is added for each revision and content that is previewed, and older ones are not removed by the plugin itself: remove them with the task below. To find its cache directory, a preview or asset request reads the whole file from the repository and computes its SHA-256 digest, also when the preview is already cached. A repository file larger than 50 MiB (a setting) is not read: its preview is answered with `413`, and its page is shown as Redmine shows it. So is a file whose size the repository does not report (Bazaar, CVS): it could only be checked after it has been read whole. The previews cached by 6.1.0 and earlier (`tmp/more_previews/repository/`) are removed on start.

If two users choose to reload (do a new conversion) concurrently, then thread safety is honored.

The previews cached more than 30 days ago (or `DAYS`) are removed by a rake task; using a preview does not renew it, a preview cached again starts anew. Run it regularly, f.i. daily from cron:

```
cd /path/to/redmine && bundle exec rake redmine_more_previews:cache:clean RAILS_ENV=production DAYS=30
```

A preview being converted or served is skipped and removed on the next run. The task also removes the failures remembered longer than their time.

# a note on conversion limits
The external programs a converter runs (ImageMagick, Ghostscript, LibreOffice, Pandoc, ...) are stopped when a conversion runs longer than the time limit (default 60 seconds, at least 120 seconds for Libre, which starts slowly). The programs run in a process group of their own, and the whole group is stopped, including the programs they started in turn (f.i. Ghostscript started by ImageMagick). The preview is not shown then (404).

At most the configured number of conversions (default 2) run at the same time, counted over all Redmine processes (lock files in `tmp/more_previews/slots/`). A request that needs a conversion while all of them are taken, or that waits longer than the wait limit (default 5 seconds) for a preview another request is converting, is answered with `503 Service Unavailable` and `Retry-After`; reloading the page later shows the preview. A preview that is already cached is served without waiting for conversions of other files.

A reverse proxy in front of Redmine often gives up after 60 seconds. A first conversion that takes longer, f.i. a large office document converted by Libre, then shows an error in the browser while the conversion finishes and is cached; the next view shows it. Raise the proxy's timeout to the time limit to avoid this.

A preview is served from memory: one larger than 100 MiB is answered with `413`. When the whole cache has grown beyond 10 GiB, new previews are converted for each request and not stored; the size of the cache is added up again at most every 10 minutes. Both limits are settings.

A conversion that failed, timed out or was too large is remembered for 10 minutes (a setting) and not tried again meanwhile: the same request is answered at once. Reloading a preview, which converts it again and forgets a failure, and the unsafe preview of emails are for administrators only; for anyone else the parameters are ignored and the links not shown.

On Windows, only the program started directly is stopped at the time limit, not the programs it started in turn.
 
