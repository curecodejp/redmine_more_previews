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
  
  def convert
    case File.extname( source ).downcase
    when ".zip"
      asset ? zipasset : ziptable 
    when ".tgz"
      asset ? tgzasset : tgztable
    when ".tar"
      asset ? tarasset : tartable
    else
      # nothing
    end #def
  end #def
  
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
    unreadable( Zlib::GzipFile::Error ) do
      Zlib::GzipReader.open(source) do |tarfile|
        tartoc( Gem::Package::TarReader.new( tarfile ))
      end
    end
  end #def
  
  def tgzasset
    unreadable( Zlib::GzipFile::Error ) do
      Zlib::GzipReader.open(source) do |tarfile|
        tarcontent( Gem::Package::TarReader.new( tarfile ))
      end
    end
  end #def
  
  # an archive that cannot be opened offers no asset: an empty list is stored, so
  # that no name opens it again (an error of the system may pass, and is not taken
  # for the archive's)
  def unreadable( error )
    yield
  rescue error
    list_assets( [], true ) unless @listed_assets || File.file?( RmpAssetList.path( dir ) )
    raise
  end #def
  
  #---------------------------------------------------------------------------------------
  # tartoc
  #---------------------------------------------------------------------------------------
  def tartoc( tarball )
    list = [[I18n.translate(:label_filepath)]]
    @names = Set.new
    complete = begin
      tarlist( tarball, "", list)
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
        arr << [("&nbsp;" * 2 * level + "<strong>" + CGI.escapeHTML(File.basename(RmpText.to_utf8(entry.full_name)))) + "</strong>"]
      end
    end
  end #def
  
  #---------------------------------------------------------------------------------------
  # each_tar_entry: the entries within the limits. Each entry takes a 512 byte
  # header and its data rounded up to 512 bytes, all of which is inflated to get
  # past it; the size is taken from the header before the data is read. Returns
  # false if the walk stops at a limit, true if the archive ends before
  #---------------------------------------------------------------------------------------
  def each_tar_entry( tarball )
    entries, bytes = 0, 0
    tarball.each do |entry|
      entries += 1
      bytes   += 512 + (entry.header.size + 511) / 512 * 512
      return false if entries > limit('max_entries') || bytes > limit_bytes('max_inflated')
      yield entry
    end
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
  # The link is the preview request itself plus ?asset=<name>: both the attachments and
  # the repositories preview actions serve the asset when the parameter is present, so
  # no named route is needed (more_preview_path is the attachments route and produced
  # /attachments/... links inside repository previews). Using request.path rather than a
  # url helper with request.params also keeps query parameters such as script_name /
  # host / anchor, which url helpers interpret as options, out of the (cached) listing.
  # The name is passed unencoded (to_query encodes it once); an extra
  # URI.encode_www_form_component produced "dir%252Ffile" and the asset was not found.
  # Only the rev parameter is kept: a revision the route's :rev does not take (a slash,
  # capitals) comes as a parameter, and without it the link leads to the default branch.
  #---------------------------------------------------------------------------------------
  def entry_link( name )
    basename = File.basename(RmpText.to_utf8(name))
    safe     = RmpFile.safe_relative_path( name )
    return CGI.escapeHTML(basename) unless safe
    query  = {:asset => safe}
    rev    = request.query_parameters["rev"]
    query[:rev] = rev if rev.is_a?( String ) && rev.present?
    path   = "#{request.path}?#{ query.to_query }"
    link_to basename, path, :download => basename
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
    write_asset{|f| while( chunk = entry.read(8192)) do f.write chunk end }
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
    unreadable( Zip::Error ) do
      Zip::File.open(source)  do |zip_file|
        ziptoc( zip_file )
      end
    end
  end #def
  
  def zipasset
    check_central_directory
    unreadable( Zip::Error ) do
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
  
  # {name => {:dir => true, :children => {...}} | {:dir => false, :entry => entry}}
  # in the order the entries appear in the archive
  def ziptree( zip_file )
    tree = {}
    zip_file.entries.each do |entry|
      next unless [:file, :directory].include?( entry.ftype )
      segments = RmpText.to_utf8( entry.name ).split('/').reject(&:empty?)
      next if segments.empty?
      # a deeper path is listed as one name below MAX_DEPTH directories
      segments = segments[0...MAX_DEPTH] + [segments[MAX_DEPTH..].join('/')] if segments.size > MAX_DEPTH + 1
      node = tree
      segments[0...-1].each do |segment|
        child = node[segment]
        child = node[segment] = {:dir => true, :children => {}} unless child && child[:dir]
        node  = child[:children]
      end
      if entry.ftype == :directory
        node[segments.last] ||= {:dir => true, :children => {}}
      else
        node[segments.last] = {:dir => false, :entry => entry}
      end
    end
    tree
  end #def
  
  def zipnode( node, arr, level )
    node.each do |name, item|
      if item[:dir]
        arr << ["&nbsp;" * 2 * level + "<strong>" + CGI.escapeHTML(name) + "</strong>", "", ""]
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
