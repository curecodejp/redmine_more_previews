# encoding: utf-8
#
# RedmineMorePreviews converter to preview zip files
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

require 'rubygems'
require 'zip'
require 'rubygems/package'
require 'zlib'

class Zippy < RedmineMorePreviews::Conversion
  
  ########################################################################################
  #
  # delegates
  #
  ########################################################################################
  delegate :number_to_human_size, :link_to, :to => "ApplicationController.helpers"
  
  ########################################################################################
  #
  # includes
  #
  ########################################################################################
  include RedmineMorePreviews::Lib
  
  ########################################################################################
  #
  # limits
  #
  ########################################################################################
  # An archive expands without bound: a tgz is inflated from the start up to the
  # entry asked for, the entries skipped on the way included, and rubyzip reads the
  # whole central directory when it opens a zip. The entries walked (count) and the
  # bytes inflated (MiB) are bounded for tar and tgz, the entries and the central
  # directory of a zip are checked before it is opened, an asset is extracted only
  # up to max_asset (MiB) and the assets stored for one archive only up to
  # max_stored (MiB). A converter setting overrides each default.
  LIMITS    = {'max_entries' => 10_000, 'max_inflated' => 1024, 'max_asset' => 100, 'max_stored' => 1024}.freeze
  
  # the largest central directory a zip may declare, in bytes. rubyzip reads the
  # directory by the number of entries, which is what bounds it (with the size of
  # the archive); a zip declaring a larger directory than this is refused as well
  MAX_CENTRAL_DIRECTORY = 32 * 1024 * 1024
  
  # directories below this depth are listed as one name
  MAX_DEPTH = 64
  
  def limit( key )
    value = converter_settings[key].to_i
    value > 0 ? value : LIMITS[key]
  end #def
  
  def limit_bytes( key )
    limit( key ) * 1024 * 1024
  end #def
  
  ########################################################################################
  #
  # convert
  #
  ########################################################################################
  # an asset is extracted when it is asked for: the listing gives the names of
  # the entries, so that other names are not looked for in the archive again
  def assets_on_demand?
    true
  end #def
  
  # listings cached before linked the entries of a listing shown inline to the page
  # of the attachment (see entry_link), and showed names in CP932 garbled (see
  # name_to_utf8): they are listed again
  def self.cache_revision
    "zippy-1"
  end #def
  
  def convert
    case archive_type
    when :zip
      asset ? zipasset : ziptable 
    when :tgz
      asset ? tgzasset : tgztable
    when :tar
      asset ? tarasset : tartable
    else
      # nothing
    end #def
  end #def
  
  # the kind of archive, by its content as Zippy is chosen for it (a zip
  # archive named a.tar is a zip archive); by the extension of its name where
  # the content does not tell. The types are those Marcel gives: for it,
  # application/x-gtar is a tar archive in the GNU format (as `tar cf` writes
  # it), not a compressed one
  ARCHIVE_TYPES      = {"application/zip"   => :zip, "application/gzip"   => :tgz,
                        "application/x-tar" => :tar, "application/x-gtar" => :tar}.freeze
  ARCHIVE_EXTENSIONS = {".zip" => :zip, ".tgz" => :tgz, ".tar" => :tar}.freeze
  
  def archive_type
    by_content = ARCHIVE_TYPES[Marcel::MimeType.for( Pathname.new( source ), name: File.basename( source ) )]
    return ARCHIVE_EXTENSIONS[File.extname( source ).downcase] unless by_content
    # a kind of archive that is turned off is not listed, also not as the kind
    # its name gives: a zip archive named a.tar is not read as a tar archive
    by_content if enabled_archive_types.include?( by_content )
  end #def
  
  def enabled_archive_types
    RedmineMorePreviews::Converter.active_mime_types.
      select{|_ext, opts| opts["converter"].to_s == "zippy" }.
      keys.map{|ext| ARCHIVE_EXTENSIONS[".#{ext}"] }.compact
  end #def
  private :enabled_archive_types
  
  ########################################################################################
  #
  # tar/tgz files
  #
  ########################################################################################
  def tartable
    File.open(source) do |tarfile|
      tartoc( Gem::Package::TarReader.new( tarfile ))
    end
  end #def
  
  def tarasset
    File.open(source) do |tarfile|
      tarcontent( Gem::Package::TarReader.new( tarfile ))
    end
  end #def
  
  def tgztable
    unreadable do
      Zlib::GzipReader.open(source) do |tarfile|
        tartoc( Gem::Package::TarReader.new( tarfile ))
      end
    end
  end #def
  
  def tgzasset
    unreadable do
      Zlib::GzipReader.open(source) do |tarfile|
        tarcontent( Gem::Package::TarReader.new( tarfile ))
      end
    end
  end #def
  
  # an archive that cannot be opened offers no asset: an empty list is stored, so
  # that no name opens it again. rubyzip and zlib fail on a broken archive with
  # errors of their own and others (TypeError, ArgumentError, ...), any of which
  # is taken for the archive's; an error of the system may pass, and a limit is
  # not the archive's failure either
  def unreadable
    yield
  rescue SystemCallError, ConverterTooLarge, ConverterTimeout
    raise
  rescue IOError => e
    broken if e.is_a?( EOFError )
    raise
  rescue StandardError
    broken
    raise
  end #def

  def broken
    list_assets( [], true ) unless @listed_assets || File.file?( RmpAssetList.path( dir ) )
  end #def
  
  #---------------------------------------------------------------------------------------
  # tartoc
  #---------------------------------------------------------------------------------------
  def tartoc( tarball )
    list = [[I18n.translate(:label_filepath)]]
    @names = Set.new
    complete = begin
      tarlist( tarball, "", list)
    rescue ConverterTimeout
      # the time limit is not the archive's: the conversion fails as a whole, and
      # the names before it are not stored as a list that stopped at a limit
      raise
    rescue StandardError
      # the listing fails, the names before the break are offered still, as a
      # list that stopped at a limit
      list_assets( @names, false )
      raise
    end
    list_assets( @names, complete )
    list << [CGI.escapeHTML(I18n.translate(:"redmine_more_previews.zippy.text_list_truncated"))] unless complete
    html = list.to_html(
        :table_class => "list",
        :headings    => true,
        :cell        => {:class => "description"},
        :html_safe   => true
      )
    File.open(tmptarget, "wt"){|f| f.write html }
  end #def
  
  #---------------------------------------------------------------------------------------
  # tarlist
  #---------------------------------------------------------------------------------------
  # false if the list stops at a limit
   def tarlist( tarball, path="", arr=[], level=0 )
    each_tar_entry( tarball ) do |entry|
      if entry.file?
        list_name( entry.full_name )
        arr << [("&nbsp;" * 2 * level + tarlink(entry))]
      elsif entry.directory?
        arr << [("&nbsp;" * 2 * level + "<strong>" + CGI.escapeHTML(name_to_utf8(File.basename(entry.full_name.b)))) + "</strong>"]
      end
    end
  end #def
  
  #---------------------------------------------------------------------------------------
  # each_tar_entry: the entries within the limits. Each entry takes a 512 byte
  # header and its data rounded up to 512 bytes, all of which is inflated to get
  # past it; the size is taken from the header before the data is read. Returns
  # false if the walk stops at a limit, true if the archive ends before. The walk
  # runs in Ruby, where the time limit of the conversion stops no command: it is
  # checked at each entry, after the last one (whose data is read past after it is
  # yielded) and while an entry is written out (see take_entry), and the conversion
  # fails when it has passed
  #---------------------------------------------------------------------------------------
  def each_tar_entry( tarball )
    entries, bytes = 0, 0
    tarball.each do |entry|
      ensure_time_left
      entries += 1
      bytes   += 512 + (entry.header.size + 511) / 512 * 512
      return false if entries > limit('max_entries') || bytes > limit_bytes('max_inflated')
      yield entry
    end
    ensure_time_left
    true
  end #def
  
  # an asset is asked for by the name of its entry or by that name normalized
  # (see asset_entry)
  def list_name( name )
    @names << name
    normalized = RmpFile.safe_relative_path( name )
    @names << normalized if normalized
  end #def
  
  #---------------------------------------------------------------------------------------
  # name_to_utf8: the name of an entry, as it is shown. A name in UTF-8 is taken as it
  # is (zip archives flag it, tar archives are mostly written so). A name that is not is
  # read as CP932, as Windows in Japan writes it, where it reads as a Japanese name: in
  # characters of Japanese only, without halfwidth katakana, and with a character of
  # a lead byte 0x81-0x9F (kana and the common kanji), a byte that is a control
  # character in ISO-8859-1, and no letter. A name of Windows-1252 whose punctuation
  # (0x80-0x9F) stands between two letters, as in O’Brien or A–Z, reads as kanji: it
  # is not taken for Japanese. Other names are guessed as before
  # (RmpText.to_utf8, mostly ISO-8859-1). A name of a western zip archive in CP850
  # may read as Japanese too: it is garbled either way
  #---------------------------------------------------------------------------------------
  # the symbols of CP932 that names are written with, as well
  JAPANESE_NAME = /\A[\p{Hiragana}\p{Katakana}\p{Han}ー々〆〇ヶ・「」『』（）［］【】〔〕〈〉《》｛｝〜～＿－＋＆＠！？、。，．：；＝＜＞／＼｜＃＄％＊＾￥‘’“”…‥※〒→←↑↓○●◎△▲▽▼□■◇◆☆★♪×÷±①-⑳Ⅰ-Ⅹⅰ-ⅹ㈱㈲㈹　０-９Ａ-Ｚａ-ｚ\u0020-\u007E]*\z/
  
  # in \p{Katakana}: the single bytes 0xA1-0xDF, which are letters in ISO-8859-1
  HALFWIDTH_KATAKANA = /[\uFF61-\uFF9F]/
  
  def name_to_utf8( name )
    japanese = japanese_name( name.to_s.b )
    japanese || RmpText.to_utf8( name.to_s )
  end #def
  
  def japanese_name( bytes )
    return nil if bytes.dup.force_encoding( "UTF-8" ).valid_encoding?
    name = bytes.dup.force_encoding( "Windows-31J" )
    return nil unless name.valid_encoding?
    name = name.encode( "UTF-8" )
    return nil unless name.match?( JAPANESE_NAME ) && !name.match?( HALFWIDTH_KATAKANA ) && common_lead_byte?( bytes )
    return nil if western_punctuation?( bytes )
    name
  rescue EncodingError
    nil
  end #def
  private :japanese_name
  
  def common_lead_byte?( bytes )
    i = 0
    while i < bytes.bytesize
      byte = bytes.getbyte( i )
      return true if byte.between?( 0x81, 0x9F )
      i += (byte < 0x80 || byte.between?( 0xA1, 0xDF )) ? 1 : 2
    end
    false
  end #def
  private :common_lead_byte?
  
  # each character of two bytes follows a letter (a character of one byte) and has
  # a letter for its second byte: "O\x92Brien" is O’Brien in Windows-1252. A name of
  # kana after a western word ("Excelテスト") is not: its second kana follows a kana
  def western_punctuation?( bytes )
    i, previous, double = 0, nil, false
    while i < bytes.bytesize
      byte = bytes.getbyte( i )
      if byte < 0x80 || byte.between?( 0xA1, 0xDF )
        previous = byte
        i += 1
      else
        return false unless ascii_letter?( previous ) && ascii_letter?( bytes.getbyte( i + 1 ) )
        previous = nil
        double   = true
        i += 2
      end
    end
    double
  end #def
  private :western_punctuation?
  
  def ascii_letter?( byte )
    !byte.nil? && (byte.between?( 0x41, 0x5A ) || byte.between?( 0x61, 0x7A ))
  end #def
  private :ascii_letter?
  
  #---------------------------------------------------------------------------------------
  # tarlink
  #---------------------------------------------------------------------------------------
  def tarlink( entry, asset=nil )
    entry_link( entry.full_name )
  end #def
  
  #---------------------------------------------------------------------------------------
  # entry_link
  #
  # entry names are attacker controlled. Only names that stay inside the archive root
  # get a download link (the asset parameter is validated again server side); other
  # entries are listed by name only.
  # The link is the preview of the attachment plus ?asset=<name>, which the preview
  # action serves. Of a repository entry it is the request itself plus ?asset=<name>:
  # the preview action and the page of the entry both serve the asset (more_preview_path
  # is the attachments route and produced /attachments/... links inside repository
  # previews). The page of an attachment does not: a listing shown inline in it linked
  # to the page, and the page was saved under the name of the entry. The link of an
  # attachment is built from its id and the sub-URI only, so a cached listing does not
  # depend on the page that converted it. Using request.path rather than a url helper
  # with request.params also keeps query parameters such as script_name / host /
  # anchor, which url helpers interpret as options, out of the (cached) listing.
  # The name is passed unencoded (to_query encodes it once); an extra
  # URI.encode_www_form_component produced "dir%252Ffile" and the asset was not found.
  # Only the rev parameter is kept: a revision the route's :rev does not take (a slash,
  # capitals) comes as a parameter, and without it the link leads to the default branch.
  # The link opens in the top window: the listing's frame is sandboxed into an opaque
  # origin, so a request from it carries no SameSite=Lax session cookie and got the login
  # page, and the download attribute is ignored there. The response is an attachment,
  # so the page stays as it is (see ControllerHelper::DOWNLOAD_PREVIEW_CONVERTERS).
  #---------------------------------------------------------------------------------------
  def entry_link( name )
    # the name is decoded by itself: the guess is made on the bytes of each name
    basename = name_to_utf8(File.basename(name.to_s.b))
    safe     = RmpFile.safe_relative_path( name )
    return CGI.escapeHTML(basename) unless safe
    query  = {:asset => safe}
    if object['type'] == :attachment
      path = url_helpers.more_preview_path( object['object'].id, :script_name => request.script_name )
    else
      rev  = request.query_parameters["rev"]
      query[:rev] = rev if rev.is_a?( String ) && rev.present?
      path = request.path
    end
    link_to basename, "#{path}?#{ query.to_query }", :download => basename, :target => "_top"
  end #def
  
  #---------------------------------------------------------------------------------------
  # tarcontent
  #---------------------------------------------------------------------------------------
  def tarcontent( tarball )
    # Only regular files are extracted: symlinks, devices etc. are never materialized
    # in the tmp directory. The requested asset matches an entry by its raw name first
    # and by its normalized name second, so "./dir/file" is still found for "dir/file"
    # but an entry literally named "dir/file" wins. A tar can only be read forward, so
    # the first normalized match is written right away and replaced if an exact match
    # turns up later.
    # The walk goes on to the end, or to a limit, and lists the names of the entries
    # as the listing does: once stored, a name the archive has not is not looked for
    # again, whether the listing was asked for or not
    # An asset too large is refused only after the walk, so that the names are
    # listed all the same. A broken archive ends the walk as a limit does: the
    # names before the break are a list that stopped at a limit, an asset written
    # whole before it is served, a part of one is not.
    @names    = Set.new
    exact     = false
    matched   = false
    written   = false
    too_large = nil
    complete  = begin
      each_tar_entry( tarball ) do |entry|
        next unless entry.file?
        list_name( entry.full_name )
        next if exact
        if entry.full_name == asset || (!matched && RmpFile.safe_relative_path( entry.full_name ) == asset)
          exact     = entry.full_name == asset
          matched   = true
          written   = false
          too_large = take_entry( entry )
          written   = too_large.nil?
        end
      end
    rescue ConverterTimeout
      # the time limit is not the archive's: the conversion fails as a whole, and
      # the names before it are not stored as a list that stopped at a limit
      FileUtils.rm_f( tmpasset ) unless written
      raise
    rescue StandardError => e
      Rails.logger.warn "#{File.basename(source)} could not be read beyond #{@names.size} names: #{e.message}"
      FileUtils.rm_f( tmpasset ) unless written
      false
    end
    list_assets( @names, complete )
    raise too_large if too_large
    # the walk stopped at a limit before the asset was found: it may lie beyond
    if complete == false && !File.exist?( tmpasset )
      raise ConverterTooLarge, "#{asset} lies beyond the limits of #{File.basename(source)}"
    end
  end #def
  
  # writes the entry as the asset; the ConverterTooLarge that refuses it, if any
  def take_entry( entry )
    check_asset_size( entry.header.size )
    write_asset{|f| while( chunk = entry.read(8192)) do ensure_time_left; f.write chunk end }
    nil
  rescue ConverterTooLarge => e
    FileUtils.rm_f( tmpasset )
    e
  end #def
  
  #---------------------------------------------------------------------------------------
  # check_asset_size: raises ConverterTooLarge for an asset larger than max_asset, or
  # one that would take the assets stored for this archive beyond max_stored
  #---------------------------------------------------------------------------------------
  def check_asset_size( size )
    if size > limit_bytes('max_asset')
      raise ConverterTooLarge, "#{asset} is larger than #{limit('max_asset')} MiB"
    end
    if !(transient || unsafe) && stored_bytes + size > limit_bytes('max_stored')
      raise ConverterTooLarge, "the assets stored for #{File.basename(source)} would exceed #{limit('max_stored')} MiB"
    end
  end #def
  
  # bytes of the files cached for this archive (the listing and the assets)
  def stored_bytes
    return 0 unless dir && File.directory?( dir )
    Dir.glob( File.join( dir, "**", "*" ), File::FNM_DOTMATCH ).sum do |path|
      stat = File.lstat( path ) rescue nil
      stat&.file? ? stat.size : 0
    end
  end #def
  
  #---------------------------------------------------------------------------------------
  # asset_entry: the entry to serve for asset; exact name first, normalized name second
  #---------------------------------------------------------------------------------------
  def asset_entry( entries, &name )
    entries.find{|e| name.call(e) == asset } ||
    entries.find{|e| RmpFile.safe_relative_path( name.call(e) ) == asset }
  end #def
  
  #---------------------------------------------------------------------------------------
  # write_asset
  #---------------------------------------------------------------------------------------
  def write_asset( &block )
    FileUtils.rm_rf(tmpasset) if File.exist?(tmpasset) || File.symlink?(tmpasset)
    FileUtils.mkdir_p(File.dirname(tmpasset))
    File.open(tmpasset, "wb", &block)
  end #def
  
  ########################################################################################
  #
  # zip files
  #
  ########################################################################################
  def ziptable
    check_central_directory
    unreadable do
      Zip::File.open(source)  do |zip_file|
        ziptoc( zip_file )
      end
    end
  end #def
  
  def zipasset
    check_central_directory
    unreadable do
      Zip::File.open(source)  do |zip_file|
        zipcontent( zip_file )
      end
    end
  end #def
  
  #---------------------------------------------------------------------------------------
  # check_central_directory: reads the number of entries and the declared size of the
  # central directory from the end of central directory record (the zip64 one if the
  # record points to it), before rubyzip reads the directory entry by entry. A file without the record is left
  # to rubyzip, which refuses it.
  #---------------------------------------------------------------------------------------
  EOCD_SIGNATURE       = [0x06054b50].pack("V").freeze
  ZIP64_EOCD_SIGNATURE = [0x06064b50].pack("V").freeze
  ZIP64_LOCATOR        = [0x07064b50].pack("V").freeze
  
  def check_central_directory
    entries, size = central_directory
    return unless entries
    if entries > limit('max_entries')
      raise ConverterTooLarge, "#{File.basename(source)} has more than #{limit('max_entries')} entries"
    end
    if size > MAX_CENTRAL_DIRECTORY
      raise ConverterTooLarge, "the central directory of #{File.basename(source)} is larger than #{MAX_CENTRAL_DIRECTORY} bytes"
    end
  end #def
  
  # [entries, size] of the central directory as rubyzip (2.4) reads them, nil where
  # rubyzip fails as well. rubyzip reads the last END_OF_CDS_SIZE bytes, and takes
  # the last zip64 record in them whenever a zip64 record and a zip64 locator
  # signature appear anywhere in them (where the locator points is not checked),
  # else the last end of central directory record. Reading them any other way
  # would check other numbers than rubyzip goes by.
  END_OF_CDS_SIZE = 65_536 + 18
  
  def central_directory
    buf = File.open( source, "rb" ) do |file|
      file.seek( [file.size - END_OF_CDS_SIZE, 0].max )
      file.read.to_s.b
    end
    zip64   = buf.rindex( ZIP64_EOCD_SIGNATURE )
    locator = buf.rindex( ZIP64_LOCATOR )
    if zip64 && locator
      # size of record (8), versions (2 + 2), disks (4 + 4), entries on disk (8),
      # entries (8), size (8): rubyzip reads them from the record up to the locator
      record = buf.byteslice( (zip64 + 4)..locator ).to_s
      return nil unless record.bytesize >= 44
      record.byteslice( 28, 16 ).unpack( "Q<Q<" )
    elsif (index = buf.rindex( EOCD_SIGNATURE ))
      # disks (2 + 2), entries on disk (2), entries (2), size (4)
      record = buf.byteslice( (index + 4)..-1 ).to_s
      return nil unless record.bytesize >= 12
      record.byteslice( 6, 6 ).unpack( "vV" )
    end
  rescue SystemCallError, IOError
    nil
  end #def
  
  #---------------------------------------------------------------------------------------
  # tartoc
  #---------------------------------------------------------------------------------------
  def ziptoc( zip_file )
    list = [[I18n.translate(:label_filename), 
             I18n.translate(:label_filesize), 
             I18n.translate(:label_compressed_filesize)
    ]];
    ziplist( zip_file, "", list )
    @names = Set.new
    zip_file.entries.each {|entry| list_name( entry.name ) if entry.ftype == :file }
    list_assets( @names, true )
    html = list.to_html(
      :table_class => "list",
      :headings    => true,
      :cell        => {:class => "description"},
      :html_safe   => true
    )
    File.open(tmptarget, "wt"){|f| f.write html }
  end #def
  
  #---------------------------------------------------------------------------------------
  # ziplist
  #---------------------------------------------------------------------------------------
  # the tree is built from every entry's path, not by globbing directory
  # entries: archives written with zip -D, Python's zipfile and others carry no
  # directory entries at all, and their nested files were missing from the list
  def ziplist( zip_file, path="", arr=[], level=0 )
    zipnode( ziptree( zip_file ), arr, level )
  end #def
  
  # {bytes => {:dir => true, :label => name, :children => {...}} | {:dir => false, :entry => entry}}
  # in the order the entries appear in the archive. The tree is keyed on the bytes
  # of the names, and each name is decoded by itself (see name_to_utf8): a folder
  # whose entries are guessed apart is one folder, and two names that read alike
  # in two charsets are two entries. "/" is not a byte of a character in CP932
  def ziptree( zip_file )
    tree = {}
    zip_file.entries.each do |entry|
      next unless [:file, :directory].include?( entry.ftype )
      segments = entry.name.to_s.b.split('/').reject(&:empty?)
      next if segments.empty?
      # a deeper path is listed as one name below MAX_DEPTH directories
      segments = segments[0...MAX_DEPTH] + [segments[MAX_DEPTH..].join('/')] if segments.size > MAX_DEPTH + 1
      node = tree
      segments[0...-1].each do |segment|
        child = node[segment]
        child = node[segment] = {:dir => true, :label => name_to_utf8( segment ), :children => {}} unless child && child[:dir]
        node  = child[:children]
      end
      if entry.ftype == :directory
        node[segments.last] ||= {:dir => true, :label => name_to_utf8( segments.last ), :children => {}}
      else
        node[segments.last] = {:dir => false, :entry => entry}
      end
    end
    tree
  end #def
  
  def zipnode( node, arr, level )
    node.each do |_bytes, item|
      if item[:dir]
        arr << ["&nbsp;" * 2 * level + "<strong>" + CGI.escapeHTML(item[:label]) + "</strong>", "", ""]
        zipnode( item[:children], arr, level + 1 )
      else
        entry = item[:entry]
        arr << ["&nbsp;" * 2 * level + ziplink( entry ),
                number_to_human_size(entry.size),
                number_to_human_size(entry.compressed_size)
               ]
      end
    end
  end #def
  
  #---------------------------------------------------------------------------------------
  # ziplink
  #---------------------------------------------------------------------------------------
  def ziplink( entry, asset=nil )
    entry_link( entry.name )
  end #def
  
  #---------------------------------------------------------------------------------------
  # zipasset
  #---------------------------------------------------------------------------------------
  def zipcontent( zip_file )
    # see tarcontent. The entry is streamed into tmpasset instead of Zip::File#extract,
    # which would recreate symlink entries. Zip::File#extract also refused entries whose
    # data exceeds the declared size (Zip::EntrySizeError); the stream does not, so the
    # check is repeated here.
    files = zip_file.entries.select{|e| e.ftype == :file }
    @names = Set.new
    files.each {|e| list_name( e.name ) }
    list_assets( @names, true )
    entry = asset_entry( files ){|e| e.name }
    return unless entry
    check_asset_size( entry.size )
    entry.get_input_stream do |io|
      written = 0
      write_asset do |f|
        while( chunk = io.read(8192)) do
          written += chunk.bytesize
          raise Zip::EntrySizeError, "#{entry.name} exceeds its declared size #{entry.size}" if written > entry.size
          f.write chunk
        end
      end
    end
  rescue Zip::EntrySizeError
    FileUtils.rm_f(tmpasset)
    raise
  end #def
  
end #class
