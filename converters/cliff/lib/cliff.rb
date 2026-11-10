# encoding: utf-8
#
# RedmineMorePreviews converter to text files
#
# Copyright © 2020 Stephan Wenzel <stephan.wenzel@drwpatent.de>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#

require "nokogiri"
require 'active_support/core_ext/hash/conversions'

class Cliff < RedmineMorePreviews::Conversion

  #---------------------------------------------------------------------------------------
  # libraries
  #---------------------------------------------------------------------------------------
  include RedmineMorePreviews::Lib
  
  #---------------------------------------------------------------------------------------
  # delegates
  #---------------------------------------------------------------------------------------
  delegate :number_to_human_size, :link_to, :to => "ApplicationController.helpers"
  delegate :url_for, :to => "Rails.application.routes.url_helpers"
  
  #---------------------------------------------------------------------------------------
  # limits
  #---------------------------------------------------------------------------------------
  # Mail parses the whole message into objects, part by part, and every attachment
  # is written out: an email of many small parts takes memory and time far beyond
  # its size. The size (MiB) and the number of MIME parts are checked on the raw
  # text before it is parsed, the attachments beyond the limit are listed only.
  # A converter setting overrides each default.
  LIMITS         = {'max_size' => 50, 'max_parts' => 1000, 'max_attachments' => 1000}.freeze
  
  # nested multipart parts: Mail's helpers (attachments, html_part, ...) walk
  # the whole tree again and again, in more than linear time in its depth,
  # and Mail keeps the body of every level, so the bodies parsed add up to
  # the size of the email times the depth. Both are bounded, the bodies by a
  # multiple of the size limit
  MAX_DEPTH      = 100
  MAX_PARSED     = 5
  
  # Mail's patterns keep state for every byte of some header lines, some 50
  # times the email in memory, and nothing short of parsing tells which: the
  # email is parsed in a child process with this much memory (see
  # Conversion#isolated)
  MAX_MEMORY     = 1024 * 1024 * 1024
  LOCALE_MARKER  = '.cliff_locale'.freeze

  # Cached headers contain translated labels and localized date strings.
  # A fragment generated for another viewer's locale must not be reused.
  def self.cache_locale_matches?(preview_path, locale)
    # The locale belongs to cached conversion metadata, not to extracted
    # mail attachments. Store it beside the converter marker.
    marker = "#{File.dirname(preview_path)}#{LOCALE_MARKER}"
    File.file?(marker) && !File.symlink?(marker) && File.read(marker).strip == locale.to_s
  rescue SystemCallError
    false
  end
  
  ########################################################################################
  #
  # convert
  #
  ########################################################################################
  def convert
    case preview_format
    when 'html'
      # what the child needs from the database is read here, before the fork,
      # and the translations loaded, which takes seconds the first time
      LIMITS.each_key {|key| limit( key ) }
      max_output
      object.to_h["object"].try( :project )
      I18n.translate( :"redmine_more_previews.cliff.text_more_attachments", :count => 0 )
      # Mail warns of a field it cannot parse with the whole field, twice: a
      # header line of the size of the email would go to the server's stderr
      isolated( :memory => max_memory ) { silence_warnings { eml } }
    end
  end #def

  # Called in the parent process with the cache lock held. The metadata
  # lives outside the converted output directory and cannot collide with an
  # attachment, count toward the attachment limit, or be served as an asset.
  def write_marker
    File.write("#{dir}#{LOCALE_MARKER}", I18n.locale.to_s) if dir
    super
  end
  private :write_marker

  ########################################################################################
  #
  # helpers
  #
  ########################################################################################
  
  #---------------------------------------------------------------------------------------
  # eml
  #---------------------------------------------------------------------------------------
  def eml
  
    # read eml file
    if File.size(source) > limit('max_size') * 1024 * 1024
      raise ConverterTooLarge, "the email is larger than #{limit('max_size')} MiB"
    end
    raw   = File.binread(source)
    # an email that is not UTF-8 is read as ISO-8859-1, which maps every byte
    # to one character: decoded_body takes the bytes of an 8bit body back
    @latin1_source = !raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    text  = RmpText.to_utf8(raw.force_encoding(Encoding::UTF_8), @latin1_source ? 'ISO-8859-1' : nil)
    check_parts( text )
    mail  = Mail.new(text)
    check_depth( mail )
    
    # get html
    html, charset = html( mail )
    
    # sweep bad stuff from html
    unless unsafe
    html = sweep( html )
    end
    
    # save headers, users usually want to see
    save_headers( mail ) 
    
    # save headers, users may want to see
    save_fields( mail )
    
    if mail.attachments.any?
    
      # create an empty index.html file, which causes, that no extracted attachment is named likewise
      File.open(tmptarget, "w") {}
      
      # create an empty attachments.html file, which causes, that no extracted attachment is named likewise
      File.open(File.join(tmpdir, "attachments.html"), "wb") {}
    
      # save attachments( which will not collide with index.html and attachments.html)
      attachments = save_attachments( mail ) 
      omitted     = mail.attachments.size - attachments.size
      
      # modify cid:links in html and save: the images are embedded, as the
      # frame of the preview cannot request them (see RmpDataUri). If the page
      # would be larger than a preview may be, they link to the files instead
      embedded = link( Nokogiri::HTML( html ), Array(attachments), max_output - html.bytesize ).to_html
      html     = embedded.bytesize <= max_output ? embedded : link( Nokogiri::HTML( html ), Array(attachments) ).to_html
      
      # create list of attachments and save
      att_html = list( attachments, omitted )
      attachments_path = File.join( File.dirname(tmptarget), "attachments.html")
      File.open(attachments_path, "wb") {|f| f.write att_html }
      
    end
    
    
    File.open(tmptarget, "wb") {|f| f.write html }
    
  rescue ConverterTooLarge => e
    # Keep the precise, configured limit in the server log for operators. The
    # error message here contains only limit constants and numerical settings,
    # never user-supplied email text or server paths.
    Rails.logger.warn "Email #{File.basename(source)} not previewed: #{e.message}"
    # The exception must escape the isolated child and become HTTP 413.
    raise
  rescue StandardError => e
    # running out of memory or a signal is no error of the email: the child
    # fails (see Conversion#isolated), no error page is stored.
    # The message can quote the mail being parsed, so it is attacker controlled.
    # The page tells why a limit refused the email; any other message can name
    # the paths of the server (f.i. a system call's), which go to the log only
    Rails.logger.error "Email #{File.basename(source)} not previewed: #{e.class}: #{e.message}\n#{Array(e.backtrace).join("\n")}"
    reason = e.is_a?( ConverterBadArgument ) ? e.message : I18n.translate( :"redmine_more_previews.cliff.text_not_previewed" )
    File.open(tmptarget, "wb") {|f| f.write ERB::Util.html_escape(reason) }
  end #def
  
  #---------------------------------------------------------------------------------------
  # html
  #---------------------------------------------------------------------------------------
  def html( mail )
  
    if mail.content_type && mail.content_type.downcase =~ /multipart/
    
        ###########################################################
        #  multipart:                                             #
        ###########################################################
        
      if mail.html_part
        ###########################################################
        #  multipart: try to fetch html                           #
        ###########################################################
        html          = decoded_body( mail.html_part )
        charset       = 'UTF-8'
      
      elsif mail.text_part 
        ###########################################################
        #  multipart: no html -> try to fetch text                #
        ###########################################################
        @text         = decoded_body( mail.text_part )
        erb           = ERB.new(File.read(File.join(views, 'cliff', 'pre.html.erb')))
        html          = erb.result(binding).html_safe
        charset       = "UTF-8"
        
      else
        ###########################################################
        #  multipart: no html, no text -> empty message part      #
        ###########################################################
        @text         = ""
        erb           = ERB.new(File.read(File.join(views, 'cliff', 'pre.html.erb')))
        html          = erb.result(binding).html_safe
        charset       = 'UTF-8'
      end
    else
    
        ###########################################################
        #  single part:                                           #
        ###########################################################
      
      if mail.content_type && mail.content_type.downcase =~ /text\/html/
        ###########################################################
        #  single part: try to identify html by content_type      #
        ###########################################################
        html          = decoded_body( mail )
        charset       = 'UTF-8'
        
      elsif mail.content_type && mail.content_type.downcase =~ /text\/plain/
        ###########################################################
        #  single part: text                                      #
        ###########################################################
        @text         = decoded_body( mail )
        erb           = ERB.new(File.read(File.join(views, 'cliff', 'pre.html.erb')))
        html          = erb.result(binding).html_safe
        charset       = "UTF-8"
        
      else
        ###########################################################
        #  single part: no html no text                           #
        ###########################################################
        @text         = ""
        erb           = ERB.new(File.read(File.join(views, 'cliff', 'pre.html.erb')))
        html          = erb.result(binding).html_safe
        charset       = 'UTF-8'
      end
    end 
    [html, charset]
  end #def
  
  #---------------------------------------------------------------------------------------
  # decoded_body, transcoded
  #---------------------------------------------------------------------------------------
  # Japanese mail declared as Shift_JIS or ISO-2022-JP is mostly written in
  # Microsoft's supersets, with characters such as ① or 髙 the strict charsets
  # do not have. Keys are lower case with '-' for '_' (Shift_JIS, shift-jis)
  CHARSET_SUPERSETS = {
    'shift-jis' => 'Windows-31J', 'x-sjis' => 'Windows-31J', 'sjis' => 'Windows-31J',
    'iso-2022-jp' => 'CP50221'
  }.freeze
  # the html is read token by token, as the browser's prescan does: a '<meta'
  # in a comment, a script or an attribute value is not a <meta>
  HTML_TOKEN = %r{
      <!--.*?(?:-->|\z)
    | <(script|style|textarea|title|xmp|iframe|noembed|noframes|noscript)\b(?:[^>"']|"[^"]*"|'[^']*')*>.*?(?:</\1\s*>|\z)
    | <meta\b((?:[^>"']|"[^"]*"|'[^']*')*)>
    | <[!/?a-z](?:[^>"']|"[^"]*"|'[^']*')*>
  }mix
  META_CHARSET = /(charset\s*=\s*["']?)([A-Za-z0-9_.:-]+)/i
  # the <meta> charset is looked for in the head of the html only, as browsers
  # do: the pattern would take quadratic time on a long body of '<meta' alone
  META_PRESCAN  = 4096
  # each candidate converts the whole body: a prescan full of <meta> must not
  # multiply that work
  META_CANDIDATES = 3

  # The text of a text/plain or text/html part in UTF-8: the transfer encoding
  # (base64, quoted-printable, 7bit, 8bit) is undone, then the charset of the
  # part (ISO-2022-JP, Shift_JIS, Windows-1252, ...) converted. Body#decoded
  # undoes only the transfer encoding.
  def decoded_body( part )
    html  = part.mime_type.to_s.casecmp?( 'text/html' )
    bytes = part.body.decoded
    # an 8bit body is still the text of the email, which was read as ISO-8859-1
    # when it is not UTF-8 (see eml): take its bytes back
    if @latin1_source && part.content_transfer_encoding.to_s !~ /\A(base64|quoted-printable)\z/i
      bytes = bytes.dup.force_encoding( Encoding::UTF_8 ).encode( Encoding::ISO_8859_1 )
    end
    bytes = bytes.b
    # an html part without a charset may declare one in its <meta>: the first
    # charset the body is valid in is taken
    charsets = if part.charset.present? then [part.charset]
               elsif html
                 meta_charsets( bytes[0, META_PRESCAN] ).
                   uniq { |charset| source_encoding( charset ) }.first( META_CANDIDATES )
               else []
               end
    text = charsets.lazy.filter_map { |charset| transcoded( bytes, charset ) }.first || RmpText.to_utf8( bytes )
    text    = text.scrub( '?' )
    # the page is written in UTF-8, with or without the sweep (unsafe): so must
    # the html declare it
    return text unless html
    text[0, META_PRESCAN].gsub( HTML_TOKEN ) { $2 ? $&.sub( META_CHARSET, '\\1UTF-8' ) : $& } + text[META_PRESCAN..].to_s
  end #def
  private :decoded_body
  
  # the charsets the <meta> tags in html declare
  def meta_charsets( html )
    html.scan( HTML_TOKEN ).filter_map { |_raw, meta| meta[META_CHARSET, 2] if meta }
  end #def
  private :meta_charsets

  # bytes in charset converted to UTF-8; nil for a charset Ruby does not know
  # or bytes the charset does not fit (a UTF-8 body declared US-ASCII, a broken
  # ISO-2022-JP escape), which are guessed instead. Mail::Encodings.transcode_charset
  # would replace those bytes, and take an unknown charset for binary.
  def transcoded( bytes, charset )
    encoding = source_encoding( charset )
    return nil if encoding == Encoding::BINARY
    # encode does not check a UTF-8 source, which it leaves as it is
    text = bytes.dup.force_encoding( encoding ).encode( Encoding::UTF_8 )
    text if text.valid_encoding?
  rescue EncodingError, ArgumentError
    nil
  end #def
  private :transcoded

  # the encoding of a charset label, by Mail's names for charsets (utf8,
  # ks_c_5601-1987, ...); BINARY for a label it does not know
  def source_encoding( charset )
    Mail::Utilities.pick_encoding( CHARSET_SUPERSETS.fetch( charset.downcase.tr( '_', '-' ), charset ) )
  end #def
  private :source_encoding
  
  #---------------------------------------------------------------------------------------
  # save_attachments
  #---------------------------------------------------------------------------------------
  def save_attachments( message )
    attachments      = {}
    # the names in use and the next index of each name, kept across attachments
    names, counters  = Set.new( Dir.children(tmpdir) ), {}
    message.attachments.each_with_index do | attachment, i |
      break if i >= limit('max_attachments')
      filename       = RmpFile.sanitize(attachment.filename)
      filename       = RmpFile.unique_filename( names, filename, :counters => counters )
      names         << filename
      content_id     = attachment.content_id.to_s.match(/^\<(.*?)\>$/)
      content_id   ||= [0, attachment.content_id.to_s]
      content_id     = content_id && content_id[1]
      attachments[i] = {:filename     => filename,
                        :content_id   => content_id,
                        :content_type => attachment.content_type
                        }
      File.open(File.join(tmpdir, filename), "w+b", 0644) {|f| f.write attachment.decoded}
    end 
    attachments 
  end #def
  
  #---------------------------------------------------------------------------------------
  # limits
  #---------------------------------------------------------------------------------------
  def max_memory
    MAX_MEMORY
  end #def
  
  # the largest preview, read before the fork (it is a setting)
  def max_output
    @max_output ||= RedmineMorePreviews::Converter.max_output
  end #def
  
  def limit( key )
    @limits ||= {}
    @limits[key] ||= begin
      value = converter_settings[key].to_i
      value > 0 ? value : LIMITS[key]
    end
  end #def
  
  # a line starting with "--": Mail splits a part at a line of "--" and its
  # boundary, which it reads in forms no simple pattern follows (quoted, with
  # comments, RFC 2231, empty ...), after making every CR, LF or CRLF a line
  # break. Every such line is counted
  DELIMITER = /(?:\A|[\r\n])--/
  
  # the text Mail's pattern for an mbox "From " line runs over: "From", white
  # space (line breaks included), a character and the ASCII text after it, of
  # which the rest of the line is an upper bound. The pattern keeps
  # state for every byte it runs over, some 50 times the text in memory, so the
  # run is bounded by the longest line of a message (RFC 5322) first, on no
  # more of the text than that
  ENVELOPE      = /\AFrom\s*[^\r\n]*/n
  MAX_LINE      = 998
  
  # counts the delimiter lines of the raw message, an upper bound of the parts
  # Mail would parse, and stops at the first one beyond the limit
  def check_parts( text )
    if text.start_with?( "From" ) && text.byteslice( 0, MAX_LINE + 1 ).b[ENVELOPE].bytesize > MAX_LINE
      raise ConverterTooLarge, "the email starts with a \"From\" line longer than #{MAX_LINE} characters"
    end
    count = 0
    text.scan( DELIMITER ) do
      count += 1
      raise ConverterTooLarge, "the email has more than #{limit('max_parts')} parts" if count > limit('max_parts')
    end
  end #def
  
  # walks the parts as Mail reads them, before anything walks the whole tree:
  # Mail splits the body of a part only when its parts are asked for, so
  # nothing beyond the limits is parsed. Whether a part is multipart is Mail's
  # decision, not a guess from the raw text
  def check_depth( mail )
    budget = MAX_PARSED * limit('max_size') * 1024 * 1024
    parsed = 0
    stack  = [[mail, 1]]
    until stack.empty?
      part, depth = stack.pop
      next unless part.multipart?
      raise ConverterTooLarge, "the email has more than #{MAX_DEPTH} nested multipart parts" if depth > MAX_DEPTH
      parsed += part.body.raw_source.to_s.bytesize
      if parsed > budget
        raise ConverterTooLarge, "the nested multipart parts of the email add up to more than #{MAX_PARSED * limit('max_size')} MiB"
      end
      part.parts.each {|child| stack.push( [child, depth + 1] ) }
    end
  end #def
  
  #---------------------------------------------------------------------------------------
  # save_headers
  #---------------------------------------------------------------------------------------
  def save_headers( message )
    @mail      = message
    erb        = ERB.new(File.read(File.join(views, 'cliff', 'headers.html.erb')))
    headers    = erb.result(binding).html_safe
    File.open(File.join(tmpdir, "headers.html"), "w+b", 0644) {|f| f.write headers }
  end #def
  
  #---------------------------------------------------------------------------------------
  # save_headers
  #---------------------------------------------------------------------------------------
  def save_fields( message )
    @mail      = message
    erb        = ERB.new(File.read(File.join(views, 'cliff', 'fields.html.erb')))
    fields     = erb.result(binding).html_safe
    File.open(File.join(tmpdir, "fields.html"), "w+b", 0644) {|f| f.write fields }
  end #def
  
  #---------------------------------------------------------------------------------------
  # sweep
  #---------------------------------------------------------------------------------------
  UNSAFETAGS   = %w(script)
  
  def sweep( html )
  
    doc = Nokogiri::HTML(html)
    
    #
    # remove unsafe tags
    #
    UNSAFETAGS.each do |ust|
      doc.xpath("//*[self::#{ust}]").each do |node|
        node.remove
      end
    end
    
    #
    # remove link= attribute of style tags
    #
    doc.xpath("//style").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /link/i
          node.delete attribute
        end
      end
    end
    
    #
    # remove url(.*) attribute within css style tags
    #
    doc.xpath("//style/text()").each do |node|
      node.replace(node.content.gsub(/url\(.*?\)/, ""))
    end
    
    #
    # remove url(.*) attribute within css style attributes
    #
    doc.xpath("//*").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /style/i
          node[attribute] = node[attribute].to_s.gsub(/url\(.*?\)/, "")
        end
      end
    end
    
    #
    # remove src= attribute of external images
    #
    doc.xpath("//img").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /src/i && node[attribute] !~ /\Acid:/i
          node.delete attribute
        end
      end
    end
    
    #
    # remove href= attribute of external links
    #
    doc.xpath("//a").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /href/i
          node.delete attribute
        end
      end
    end
    
    #
    # remove unsafe event attributes beginning with "on…"
    #
    patterns = [
                 "//*[@*[starts-with(name(), 'on')]]",
                "//@*[@*[starts-with(name(), 'on')]]",
      "//namespace::*[@*[starts-with(name(), 'on')]]"
    ].join(" | ")
    doc.xpath(patterns).each do |node|
      node.keys.each do |attribute|
        node.delete attribute if attribute =~ /\Aon/i
      end
    end
    
    # to_html will automatically correct 
    # <meta http-equiv="Content-Type" content="text/html; charset=<CHARSET>"
    # took me a day to find that out
    doc.to_html
  end #def
  
  #---------------------------------------------------------------------------------------
  # link
  #---------------------------------------------------------------------------------------
  # an image is embedded while its data: URI fits into budget (bytes), else
  # it is linked to the extracted file
  def link( xml, attachments, budget = 0 )
    #
    # link src= attribute of images
    #
    xml.xpath("//img").each do |node|
      node.keys.each do |attribute|
        if attribute =~ /src/i && node[attribute] =~ /\Acid:/i
          cidmatch = node[attribute].match(/^cid:(.*)/i); cid = cidmatch && cidmatch[1]
          if att = attachments.find{|key,value| value && value[:content_id] == cid}
            filename = att[1][:filename]
            uri      = budget > 0 && RmpDataUri.image( tmpdir, File.join( tmpdir, filename ), budget )
            budget  -= uri.bytesize if uri
            node[attribute] = uri || filename
          end
        end
      end
    end
    xml
  end #def
  
  #---------------------------------------------------------------------------------------
  # list 
  #---------------------------------------------------------------------------------------
  def list( attachments, omitted = 0 )
    b = binding
    b.local_variable_set(:attachments, attachments)
    b.local_variable_set(:omitted, omitted)
    b.local_variable_set(:object, object)
    erb = ERB.new(File.read(File.join(views, 'cliff', 'attachments.html.erb')))
    erb.result(b).squish.html_safe
  end #def
  
  #---------------------------------------------------------------------------------------
  # obj_to_xml( label, obj, xml=nil )
  # creates xml from an arbitrary nested mixture of arrays and hashes
  #
  def obj_to_xml( label, obj, xml=nil )
  
    if xml
      if obj.is_a?(Array)
        obj.each do |value|
          obj_to_xml(label,value,xml)     # Recurse
        end
      elsif obj.is_a?(Hash)
        if obj.any?
          xml.send(label) do
            obj.each do |key, value|
              obj_to_xml(key,value,xml)   # Recurse
            end
          end
        end
      else
        xml.send(label,obj)               # Create <label>obj(value)</label>
      end #if 
    else
      _xml = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.root do                       # Wrap everything in one element.
         obj_to_xml(label, obj ,xml)      # Start the recursion with a custom name.
        end #_xml
      end #Nokogiri
    end #if
    _xml
  end #def 
  
end #class
