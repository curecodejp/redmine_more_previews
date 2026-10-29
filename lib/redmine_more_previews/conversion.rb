# encoding: utf-8
# frozen_string_literal: true

# Redmine plugin to preview various file types in redmine's preview pane
#
# Copyright © 2018 -2022 Stephan Wenzel <stephan.wenzel@drwpatent.de>
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


require 'fileutils'

module RedmineMorePreviews 
  class Conversion
    # Change cache identity when debug diagnostics or their exposure policy
    # changes. Old cache files may contain arbitrary internal instance variables
    # (including absolute paths) and must never be reused after this fix.
    # Evict cached previews created before LibreOffice filesystem isolation.
    # Even a fixed converter must not serve a previously generated unsafe PDF.
    # Invalidate previous Vince and Libre rendering and Maggie PDF raster results
    # so upgrades to 6.1.4 regenerate previews using the corrected converters.
    CACHE_FORMAT_VERSION = 'maintenance-6.1.4-v1'.freeze
    SAFE_DEBUG_FIELDS = %w(converter converter_version plugin_version source_type preview_format).freeze

  
    
    #-------------------------------------------------------------------------------------
    # include libraries
    #-------------------------------------------------------------------------------------
    include Redmine::Utils::Shell
    include RedmineMorePreviews::Lib
    include RedmineMorePreviews::Modules::Shell
    include RedmineMorePreviews::Exceptions
    
    #-------------------------------------------------------------------------------------
    # delegations
    #-------------------------------------------------------------------------------------
    delegate :url_helpers, :to => "Rails.application.routes"
    
    #-------------------------------------------------------------------------------------
    # instance variables
    #-------------------------------------------------------------------------------------
    attr_accessor :id, :name, :threadsafe, :semaphore, :mime_types, :project, :object, 
                  :source, :format, :preview_format, :request, :timeout, :shell_api,
                  :target,    :dir,         :file,        :ext,        :targetpath,
                  :asset,     :assetdir,    :assetfile,   :assetext,   :assetpath,
                  :assets,                                             :assetspaths,
                  :tmptarget, :tmpdir,      :tmpfile,     :tmpext, 
                  :tmpasset,  :tmpassetdir, :tmpassetfile,:tmpassetext,
                  :tmpassetspaths,
                  :settings, :unique_id,
                  :transient, :reload, :unsafe,
                  :version, :plugin_version,
                  :converter, :views, :pub_dir
    
    #-------------------------------------------------------------------------------------
    # initialize
    #-------------------------------------------------------------------------------------
    def initialize(id, options={})
    
      options.symbolize_keys!
      
      self.id             = id.to_s
      self.name           = options[:name].to_s
      self.version        = options[:version].to_s
      self.plugin_version = Redmine::Plugin.registered_plugins[:redmine_more_previews].version
      
      self.converter      = RedmineMorePreviews::Converter.find(id)
      self.views          = converter.path.views
      self.pub_dir        = converter.path.public_directory
      
      self.settings       = options[:settings].presence || {}
      raise ConverterWrongArgument unless settings.is_a?(Hash)
      
      self.threadsafe     = options[:threadsafe].presence || false
      raise ConverterWrongArgument unless [true,false].include?(threadsafe)
      
      self.semaphore      = options[:semaphore].presence
      raise ConverterWrongArgument unless semaphore.is_a?(Mutex) || semaphore.nil?
      
      self.timeout        = options[:timeout].presence
      raise ConverterWrongArgument unless timeout.is_a?(Numeric)
      
      self.shell_api      = options[:shell_api].presence
      raise ConverterWrongArgument unless shell_api.present?
      
      self.mime_types     = options[:mime_types].presence || {}
      raise ConverterWrongArgument unless mime_types.is_a?(Hash)
      
      self.object         = (options[:object].presence || {}).stringify_keys
      self.project        = object['object'].try(:project)
      
      self.unique_id      = case object['type']
      when :attachment
        object['object'].id
      when :repository
        entry = object['object'].try(:entry, object['path'], object['rev'])
        entry.try(:info)
      else
        object['object'].try(:object_id)
      end
      
      self.format         = options[:format].to_s.downcase
      self.preview_format = options[:preview_format].to_s.downcase
      self.request        = options[:request]
      
      # preview 
      self.target         = options[:target]
      
      # should preview asset be served instead of preview
      # asset names come from request parameters and archive entries: they are
      # joined to the cache and tmp directories, so they must not be able to
      # leave them (absolute paths, "..", NUL). Invalid names are rejected here
      # so no converter ever sees them.
      self.assets         = safe_asset_names(options[:assets])
      self.asset          = safe_asset_name(options[:asset])
      
      # should cache be renewed
       self.reload        = options[:reload].presence || false
      
      # should an unsafe reload be one
       self.unsafe        = options[:unsafe].presence || false
      
      # create path_sets for cache storage
      self.targetpath, self.dir,        self.file,       self.ext      = path_set( target,                :nocreate => true )
      # an asset is stored below the directory of its preview at its own path
      # (a/b.txt -> <preview>/a/b.txt): that directory is the asset's as well, for
      # its lock, its marker and what is copied into it. The directory of the
      # target held the asset at a/a/b.txt, where it was never found again
      suffix = File.join( "", asset.to_s )
      self.dir = targetpath.delete_suffix( suffix ) if asset && targetpath.to_s.end_with?( suffix )
      self.assetpath,  self.assetdir,   self.assetfile,  self.assetext = path_set( File.join(dir, asset), :nocreate => true ) if asset
      self.assetspaths = assets.to_a.map{ |ass| path_set( File.join(dir, ass), nil, :nocreate => true )}
    end #def
    
    #-------------------------------------------------------------------------------------
    # asset name validation
    #-------------------------------------------------------------------------------------
    # returns the normalized asset name, nil if none was given, raises if it is unsafe
    def safe_asset_name( name )
      return nil if name.blank?
      Lib::RmpFile.safe_relative_path( name ) || raise(ConverterBadArgument, "unsafe asset name")
    end #def
    private :safe_asset_name
    
    def safe_asset_names( names )
      names = Array(names).map{|name| safe_asset_name(name) }.compact
      names.presence
    end #def
    private :safe_asset_names
    
    # raises unless path lies below directory (after resolving ".." and symlinks)
    def ensure_within!( directory, path )
      return if path.nil?
      raise ConverterBadArgument, "path outside of preview directory" unless Lib::RmpFile.within_directory?( directory, path )
    end #def
    private :ensure_within!
    
    #-------------------------------------------------------------------------------------
    # lock and unlock, if converter is not thread safe
    #-------------------------------------------------------------------------------------
    def lock;     threadsafe ||               (semaphore && semaphore.lock);      end #def
    def unlock;   threadsafe ||               (semaphore && semaphore.unlock);    end #def
    def try_lock; threadsafe ||               (semaphore && semaphore.try_lock);  end #def
    def locked?;  return false if threadsafe; (semaphore && semaphore.locked?);   end #def
    def owned?;   return true  if threadsafe; (semaphore && semaphore.owned?);    end #def
    
    # the converter's semaphore, waited for no longer than the wait limit
    # (ConverterLockTimeOut): a conversion holds it until it ends or times out
    def sync
      return yield if threadsafe || semaphore.nil? || semaphore.owned?
      wait_for( "converter #{name}" ) { semaphore.try_lock }
      begin
        yield
      ensure
        semaphore.unlock
      end
    end #def
    
    # calls the block until it returns true, raises ConverterLockTimeOut once the wait
    # limit (Converter.lock_timeout) has passed
    def wait_for( what )
      deadline = Lib::RmpProcess.now + RedmineMorePreviews::Converter.lock_timeout
      until yield
        raise ConverterLockTimeOut, "#{what} is busy" if Lib::RmpProcess.now >= deadline
        sleep 0.05
      end
    end #def
    private :wait_for
    
    #-------------------------------------------------------------------------------------
    # conversion slots
    #-------------------------------------------------------------------------------------
    # at most Converter.max_conversions conversions run at the same time, counted
    # across processes with one lock file per slot: a Mutex per converter and per
    # process lets every Redmine process run its own conversions, and a request
    # for another file does not wait for it at all. A request does not wait for a
    # free slot either (ConverterLockTimeOut at once): a conversion holds its slot
    # for up to the time limit, so waiting would only keep the request's thread busy
    def with_slot
      # a conversion does not wait for a second slot
      return yield if Thread.current[:redmine_more_previews_slot]
      slot = nil
      directory = File.join( RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH, "slots" )
      FileUtils.mkdir_p( directory )
      slot = RedmineMorePreviews::Converter.max_conversions.times.lazy.map{ |n| try_slot( directory, n ) }.find(&:itself)
      raise ConverterLockTimeOut, "no free conversion slot" unless slot
      Thread.current[:redmine_more_previews_slot] = true
      yield
    ensure
      if slot
        Thread.current[:redmine_more_previews_slot] = nil
        slot.flock( File::LOCK_UN ) # see with_cache_lock
        slot.close
      end
    end #def
    private :with_slot
    
    def try_slot( directory, n )
      file = File.open( File.join( directory, "#{n}.lock" ), File::RDWR | File::CREAT, 0644 )
      return file if file.flock( File::LOCK_EX | File::LOCK_NB )
      file.close
      nil
    end #def
    private :try_slot
    
    #-------------------------------------------------------------------------------------
    # convertible?
    #-------------------------------------------------------------------------------------
    def convertible?(filename)
      @mime_types.keys.include?( File.extname(filename).downcase.to_sym )
    end #def
    
    #-------------------------------------------------------------------------------------
    # source_mime
    #-------------------------------------------------------------------------------------
    def source_mime_ext(options={})
      mime_data = RedmineMorePreviews::Converter.mime( source, options )
      mime_data && mime_data["format"]
    end #ddef
    
    #-------------------------------------------------------------------------------------
    # preview
    #-------------------------------------------------------------------------------------
    def preview(file, options={}, &block)
      
      # transient?
      self.transient = block_given?
      
      # sourcefile, either direct or copied in a tmp dir from elsewhere 
      begin; self.source = file.path; rescue; raise ConverterBadArgument; end
      
      # an asset the stored preview does not offer is not converted for: its
      # name comes from the request, and every new name would convert again
      # (an asset stored already is served, whatever the list says)
      listed = asset && (File.file?( assetpath ) ? true : asset_listed)
      unless reload
        if listed == false
          Rails.logger.info "Asset #{asset} of #{file.path} not found in its preview"
          return nil
        elsif listed == :beyond
          raise ConverterTooLarge, "#{asset} lies beyond the limits of #{File.basename(file.path)}"
        end
      end

      # a failure is remembered for a while (see Lib::RmpFailures): the same
      # request fails at once instead of converting again, until a reload. An
      # asset's failure only if the asset is known to exist: a failure kept for
      # any name asked for would take a file for each
      failure = targetpath if !asset || listed == true
      # an asset of a converter that writes its assets with its preview is
      # converted with the preview: the preview's failure is the asset's as well
      whole = File.join( dir, ["index", preview_format].join(".") ) if asset && listed.nil? && !assets_on_demand?
      # one kept is looked for whatever the name: looking writes no file
      if reload
        Lib::RmpFailures.forget( targetpath )
        Lib::RmpFailures.forget( whole )
      elsif !stored? && (reason = Lib::RmpFailures.recorded( targetpath ) || Lib::RmpFailures.recorded( whole ))
        Rails.logger.info "Preview for #{file.path} failed before (#{reason}), not converted again"
        raise ConverterTooLarge, "#{File.basename(file.path)} failed before" if reason == "too_large"
        return nil
      end
      
      # do conversion
      # locks are always taken in this order: cache lock, conversion slot, converter
      # semaphore
      begin
        if unsafe || transient
          # transient (non-cached) conversion, yielded in block. What the block is
          # given is checked first: it may return from the caller
          with_slot { sync { transient_preview do |*files|
            # an asset missing from a preview that was converted is no failure of the
            # preview's; none at all is
            @preview_converted = !files[0].nil?
            Lib::RmpFailures.record( failure || whole_failed( whole ), "empty" ) if (asset ? files[1] : files[0]).nil?
            block.call( *files )
          end } }
        else
          # cached conversion, just read from file
          data = cached_preview
          data.nil? ? Lib::RmpFailures.record( failure || whole_failed( whole ), "empty" ) : Lib::RmpFailures.forget( failure )
          data
        end
      rescue ConverterLockTimeOut => e
        # answered with 503 by the controller; nothing failed, it may succeed later
        Rails.logger.warn "Preview for #{file.path} not generated: #{e.message}"
        raise
      rescue ConverterTooLarge => e
        # answered with 413 by the controller
        Rails.logger.warn "Preview for #{file.path} not generated: #{e.message}"
        # the conversion may have listed the asset meanwhile (see store_asset_list);
        # an asset too large exists, and is the asset's failure, not the preview's
        failure ||= targetpath if asset && (@asset_too_large || asset_listed == true)
        Lib::RmpFailures.record( failure || whole_failed( whole ), "too_large" )
        raise
      rescue Exception => e
        Rails.logger.error "An error occured while generating preview for #{file.path}"
        Rails.logger.error "Exception was: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        failure ||= targetpath if asset && asset_listed == true
        Lib::RmpFailures.record( failure || whole_failed( whole ), "error" )
        return nil
      end
    end #def
    
    #-------------------------------------------------------------------------------------
    # transient_preview
    #-------------------------------------------------------------------------------------
    # read: false leaves the converted files in the tmp directory unread, for a
    # block that only copies them (see cached_preview)
    def transient_preview( read: true, &block )
      Dir.mktmpdir do |tdir|
        files = []
        self.tmptarget, self.tmpdir,     self.tmpfile,     self.tmpext      = path_set(tdir, ["index", preview_format].join("."))
        self.tmpasset,  self.tmpassetdir,self.tmpassetfile,self.tmpassetext = path_set(tmpdir, asset )
        self.tmpassetspaths = assets.to_a.map do |ass|
          path_set( File.join(tmpdir, ass), nil, :nocreate => true )
        end 
        # defense in depth: asset names are validated in initialize, make sure
        # nothing is written outside the tmp directory anyway
        ensure_within!( tmpdir, tmpasset ) if asset
        tmpassetspaths.each{|ass| ensure_within!( tmpdir, ass.first ) }
        # one time limit for all the commands of this conversion
        @deadline = Lib::RmpProcess.now + conversion_timeout
        convert
        debug if RedmineMorePreviews::Converter.debug? # debug will overwrite the result of convert
        if block_given? && !read
          yield
        elsif block_given?
          result = [tmptarget, tmpasset, tmpassetspaths.map(&:first)].flatten.compact.map do |f|
            read_limited( f ) if regular_file_within?( tmpdir, f )
          end
          yield *result
        end
      end
    end #def
    
    #-------------------------------------------------------------------------------------
    # cached_preview
    #-------------------------------------------------------------------------------------
    def cached_preview
      # the converter semaphore is per converter (and per process): requests of
      # two converters for the same file, or two processes, must not interleave
      # the marker check, the replacement and the read of one cache directory.
      # A cached preview is served under this lock alone: a request for it does
      # not wait for a conversion of another file.
      with_cache_lock do
        # the directory holds the preview and its assets: whatever another
        # converter left there must go before this one writes into it (an asset
        # conversion alone would otherwise mark the other converter's index as ours)
        discard_cache unless cached_by_this_converter?
        if !valid || reload || !cached_by_this_converter?
          # a full cache takes no new previews: convert, serve and forget
          if Lib::RmpCacheSize.full?
            Rails.logger.warn "Preview cache is full, #{dir} is not stored"
            # nothing is stored: a converter's limits on what it stores do not apply
            self.transient = true
            return with_slot { sync { transient_preview{|target_data, asset_data, *|
              @preview_converted = !target_data.nil?
              asset ? asset_data : target_data
            } } }
          end
          # a preview that could not be served is not stored either; the names a
          # converter listed before it stopped at a limit or failed are, so that
          # another name is not looked for again
          begin
            with_slot { sync { transient_preview( read: false ) { check_output_size; copy_over } } }
          rescue ConverterLockTimeOut
            raise
          rescue StandardError
            store_asset_list
            raise
          end
        end
        read_safe
      end
    end #def
    
    # an exclusive advisory lock on <dir>.lock, held across processes. A request
    # for a preview that is being converted waits no longer than the wait limit
    def with_cache_lock
      return yield unless dir
      FileUtils.mkdir_p( File.dirname( dir ) )
      File.open( "#{dir}.lock", File::RDWR | File::CREAT, 0644 ) do |lock|
        wait_for( "preview #{dir}" ) { lock.flock( File::LOCK_EX | File::LOCK_NB ) }
        begin
          yield
        ensure
          # closing alone keeps the lock while a child forked meanwhile, by
          # another request, holds the file (see Lib::RmpProcess.fork)
          lock.flock( File::LOCK_UN )
        end
      end
    end #def
    private :with_cache_lock
    
    def discard_cache
      return unless dir && File.directory?( dir )
      # only ever remove a preview directory inside the plugin's storage
      raise ConverterBadArgument unless Lib::RmpFile.within_directory?( RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH, dir )
      FileUtils.rm_rf( dir )
      FileUtils.rm_f( marker_path )
      Lib::RmpAssetList.remove( dir )
    end #def
    private :discard_cache
    
    #-------------------------------------------------------------------------------------
    # which converter produced the cached preview
    #-------------------------------------------------------------------------------------
    # the cache directory is per attachment and format, not per converter: when
    # the converter selection changes (settings, or a file whose content and
    # extension point to different converters) a preview produced by another
    # converter must not be served as this converter's output -- the response
    # policy (f.i. the download sandbox flag) is chosen for this converter
    def marker_path
      dir && "#{dir}.converter"
    end #def
    private :marker_path
    
    def cache_marker
      mode = RedmineMorePreviews::Converter.debug? ? 'debug' : 'normal'
      "#{id}:#{CACHE_FORMAT_VERSION}:#{mode}"
    end #def
    private :cache_marker

    def cached_by_this_converter?
      marker_path && File.file?( marker_path ) && File.read( marker_path ).strip == cache_marker
    end #def

    def write_marker
      File.write( marker_path, cache_marker ) if marker_path
    end #def
    private :write_marker

    #-------------------------------------------------------------------------------------
    # assets offered by the stored preview
    #-------------------------------------------------------------------------------------
    # true for a converter that extracts an asset only when it is asked for, and
    # lists the names it offers (see list_assets); false for one that writes all
    # its assets with the preview
    def assets_on_demand?
      false
    end #def

    # a converter that extracts its assets on demand gives the names they may be
    # asked for while it makes the preview; complete is false if it stopped at a
    # limit. They are stored with the preview (see Lib::RmpAssetList)
    def list_assets( names, complete )
      @listed_assets = [names, complete]
    end #def

    # whether the asset asked for exists, known from the stored preview of this
    # converter without converting: true, false (it does not), :beyond (a list
    # that stopped at a limit has not its name) or nil (not known)
    def asset_listed
      return nil unless cached_by_this_converter?
      if assets_on_demand?
        Lib::RmpAssetList.lookup( dir, asset )
      elsif File.file?( File.join( dir, ["index", preview_format].join(".") ) )
        File.file?( assetpath )
      end
    rescue SystemCallError
      nil
    end #def
    private :asset_listed
    
    # the preview or asset asked for is stored: it is served whatever failure was
    # remembered, which a request that failed may write after another stored it
    def stored?
      !( unsafe || transient ) && valid && cached_by_this_converter? && File.file?( asset ? assetpath : targetpath )
    rescue SystemCallError
      false
    end #def
    private :stored?
    
    # the key of the preview's failure for an asset that failed with it (see
    # preview), nil once the preview is converted or stored: then the failure is
    # the asset's
    def whole_failed( whole )
      whole unless whole.nil? || @preview_converted || File.file?( whole )
    end #def
    private :whole_failed
    
    #-------------------------------------------------------------------------------------
    # copy over
    #-------------------------------------------------------------------------------------
    # called under the cache lock (see cached_preview), which guards the directory
    def copy_over
      if File.exist?(tmpdir)
        FileUtils.mkdir_p( dir )
        # copy all files.
        # Dir.glob() also produces "." ".."
        # therefore get files and directories with 
        # Dir.children() and reassemble paths
        Dir.children(tmpdir).each do |f|
          FileUtils.copy_entry(File.join(tmpdir,f), File.join(dir,f), true, false, true)
        end
        write_marker
        store_asset_list
      end
    end #def
    
    # the names of the assets a converter listed (see list_assets), with the
    # marker they are taken by
    def store_asset_list
      return unless @listed_assets && dir
      FileUtils.mkdir_p( dir )
      write_marker
      Lib::RmpAssetList.write( dir, *@listed_assets )
    end #def
    private :store_asset_list
    
    #-------------------------------------------------------------------------------------
    # read safe
    #-------------------------------------------------------------------------------------
    # only regular files strictly below the preview directory are served; a
    # symlink (f.i. extracted from an archive) pointing elsewhere is not followed
    def regular_file_within?( directory, path )
      path.present? && File.file?( path ) && !File.symlink?( path ) && Lib::RmpFile.within_directory?( directory, path )
    end #def
    private :regular_file_within?
    
    # the files to serve of a conversion in the tmp directory, see read_limited
    def check_output_size
      [tmptarget, tmpasset].compact.each do |path|
        next unless File.file?( path ) && File.size( path ) > RedmineMorePreviews::Converter.max_output
        @asset_too_large = asset && path == tmpasset
        raise ConverterTooLarge, "#{File.basename(path)} is larger than #{RedmineMorePreviews::Converter.max_output} bytes"
      end
    end #def
    private :check_output_size
    
    # a converted file is served from memory: one larger than the limit is not
    # read (ConverterTooLarge)
    def read_limited( path )
      if File.size( path ) > RedmineMorePreviews::Converter.max_output
        @asset_too_large = asset && [tmpasset, assetpath].include?( path )
        raise ConverterTooLarge, "#{File.basename(path)} is larger than #{RedmineMorePreviews::Converter.max_output} bytes"
      end
      File.open( path, "rb" ) {|io| io.read}
    end #def
    private :read_limited
    
    # called under the cache lock (see cached_preview), which guards the directory
    def read_safe
      if asset
        # a requested asset that is missing or not servable must not fall back to the preview
        return nil unless regular_file_within?( dir, assetpath )
        read_limited( assetpath )
      elsif target && regular_file_within?( dir, targetpath )
        read_limited( targetpath )
      else
        nil
      end
    end #def
    
    #-------------------------------------------------------------------------------------
    # check
    #-------------------------------------------------------------------------------------
    def check
      sync{ @status = status }; @status
    rescue ConverterLockTimeOut, ConverterTimeout
      nil
    end #def
    
    #-------------------------------------------------------------------------------------
    # pathset create path, director
    #-------------------------------------------------------------------------------------
    def path_set( path, filename=nil, **options)
      return [nil, nil, nil, nil] if path.nil?
      raise ConverterBadArgument unless path.present?
      fullpath = filename ? File.join(path, filename) : path
      directory = File.dirname( fullpath )
      raise ConverterBadArgument if directory == File.dirname("")
      FileUtils.mkdir_p( directory ) unless (File.directory?( directory ) || options[:nocreate])
      filename, extension = File.basename( fullpath ), File.extname( fullpath )
      [fullpath, directory, filename, extension]
    end #def
    
    #-------------------------------------------------------------------------------------
    # urls for assets
    #-------------------------------------------------------------------------------------
    def asset_path(asset)
      asset_format = File.extname(asset)
      asset_base   = File.basename(asset, asset_format)
      asset_format.gsub!(/\A\./, "") # remove preceeding dot
      case object['type']
      when :attachment
        url_helpers.more_asset_path(object['object'].id, :asset => asset_base, :assetformat => asset_format)
      when :repository
        ext  = File.extname(object['path'])
        path = File.join(File.dirname(object['path']),File.basename(object['path'], ext))
        ext.gsub!(/\A\./, "") # remove preceeding dot
        url_helpers.url_for(
          :controller    => "repositories", 
          :action        => "more_asset",
          :id            => object['object'].project.identifier,
          :repository_id => object['object'].identifier,
          :rev           => object['rev'],
          :path          => path,
          :baseformat    => ext.gsub(/\A\./, ""), 
          :asset         => asset_base,
          :assetformat   => asset_format,
          :only_path     => true
        )
      end
    end #def
    
    ######################################################################################
    #
    # unix and windows command line helpers
    #
    ######################################################################################
    # move src to tmparget
    def move( src, tgt= tmptarget)
      mv  = Redmine::Platform.mswin? ? "move" : "mv"
      "#{mv} #{shell_quote src} #{shell_quote tgt} "
    end #def
    
    # copy src to tmparget
    def copy( src, tgt= tmptarget)
      cp  = Redmine::Platform.mswin? ? "copy" : "cp"
      "#{cp} #{shell_quote src} #{shell_quote tgt} "
    end #def
    
    # cd to tmpdir
    def cd
      "cd #{shell_quote tmpdir}"
    end #def
    
    # prepend thisdir to filename
    def thisdir( name )
      File.join(".", name)
    end #def
    
    # join two commands in command line
    def join
      Redmine::Platform.mswin? ? " & " : "; "
    end #def
    
    # list files in dir
    def ls( dir )
      Dir.glob(File.join(dir, "*"))
    end #def
    
    # execute command, within the time limit of the conversion: a command that
    # runs out of it is stopped with all the processes it started, and the
    # conversion fails (ConverterTimeout) even with options[:dontfail]
    def command( cmd, options={})
      remaining = @deadline ? @deadline - Lib::RmpProcess.now : conversion_timeout
      raise ConverterTimeout, "no time left" unless remaining > 0
      status = Lib::RmpProcess.run( cmd, :timeout => remaining )
      unless status.success?
        Rails.logger.error("Creating preview with #{name} failed (#{status}):\nCommand: #{cmd}")
        raise ConverterShellError unless options[:dontfail]
        return false
      end
      true
    rescue ConverterTimeout
      Rails.logger.error("Creating preview with #{name} timed out after #{conversion_timeout}s:\nCommand: #{cmd}")
      raise
    end #def
    
    # runs the block in a child process within the time left for the conversion
    # and, where it can be bounded, memory bytes (see Lib::RmpProcess.fork): for a
    # converter that parses the file in Ruby. The block's results must be files
    def isolated( memory: )
      remaining = @deadline ? @deadline - Lib::RmpProcess.now : conversion_timeout
      raise ConverterTimeout, "no time left" unless remaining > 0
      return true if Lib::RmpProcess.fork( :timeout => remaining, :memory => memory ) { yield }
      Rails.logger.error("Creating preview with #{name} failed in its child process")
      raise ConverterShellError
    rescue ConverterTimeout
      Rails.logger.error("Creating preview with #{name} timed out after #{conversion_timeout}s")
      raise
    end #def

    # seconds all the commands of one conversion may run together: the plugin
    # setting, or more if the converter needs it (Libre starts slowly)
    def conversion_timeout
      [RedmineMorePreviews::Converter.conversion_timeout, converter&.conversion_timeout.to_i].max
    end #def
    
    # create outfile name for programs that create conversions having the same basename
    # of the converted file as the input file, f.i. LibreOffice creates a my.html file
    # from a conversion of a my.odt file
    def outfile
      File.basename(source, File.extname(source)) + ".#{preview_format}"
    end #def
    
    def converter_settings
      Setting["plugin_redmine_more_previews"].to_h.dig("converter", id).to_h
    end #def
    
    ######################################################################################
    #
    # helper functios
    #
    ######################################################################################
    def public_web_directory
      converter.public_web_directory
    end #def
    
    def assets_directory
      File.join(public_web_directory, 'assets')
    end #def
    
    def images_directory
      File.join(public_web_directory, 'images')
    end #def
    
    def javascripts_directory
      File.join(public_web_directory, 'javascripts')
    end #def
    
    def stylesheets_directory
      File.join(public_web_directory, 'stylesheets')
    end #def
    
    def javascript_include_tag(rel_path, **options, &block)
      if block_given?
        ApplicationController.helpers.content_tag(:script, :src => [javascripts_directory, rel_path].join('/'), &block)
      else
        ApplicationController.helpers.content_tag(:script, "", :src => [javascripts_directory, rel_path].join('/'))
      end
    end #def
    
    def stylesheet_link_tag(rel_path, **options)
      ApplicationController.helpers.tag(:link, :rel => "stylesheet", :media => 'all', :href => [stylesheets_directory, rel_path].join('/'))
    end #def
    
    ######################################################################################
    #
    # override these methods
    #
    ######################################################################################
    def status
      #
      # child classes should override this method
      #
      # returns :symbol for translation or string and boolean: true: ok, false: not ok
      # ["External Program Name is available (needed for #{@name})", true ]
      # ["External Program Name is not available (needed for #{@name})", false ]
      # if nil is returned, no status is given (f.i. if no external program is needed)
      
      nil
    end #def
    
    def valid
      #
      # child classes should override this method
      #
      # converter is given a chance to invalidate the cached conversion
      # 
      # returns true, if data in cache is valid, else false
      #
      #
      @target && File.exist?(@target)
    end #def
    
    def convert
      #
      # child classes should override this method
      #
      # and convert the source file to a target file with format extension
      #   
      #   @mime_types     (Hash)
      #   @object         (Hash) {:type => :attachment, :object => @attachment}, or 
      #                          {:type => :repository, :object => @repository, :path => @path, :rev => @rev}
      #                          
      #   @project        (Project)  project 
      #   @name           (String)   beautiful name of converter
      #   
      #   @preview_format (String)   "html", "inline", "text" or "pdf"
      #   @source         (String)   path of source file
      #   
      #   --- the following data are just for informational purposes 
      #       do not write to the paths below to stay thread safe
      #       
      #   @target         (String)   full target path
      #   @dir            (String)   target directory of full target path
      #   @file           (String)   target filename of full target path
      #   @ext            (String)   target filename extension of full target path
      #   @asset          (String)   name of preview asset, f.i. an inline image
      #   
      #   --- the following paths belong to your converter -------
      #
      #   @tmptarget      (String)   full tmp target path
      #   @tmpdir         (String)   target directory of full tmp target path
      #   @tmpfile        (String)   target filename of full tmp target path
      #   @tmpext         (String)   target directory of full tmp target path
      #   
      # asset, asset=, assetdir, assetdir=, assetext, assetext=, assetfile, assetfile=, 
      # assets, assets=, cached_preview, cd, check, command, convert, convertible?, 
      # copy_over, dir, dir=, execute, ext, ext=, file, file=, format, format=, id, id=, 
      # join, lock, locked?, mime_types, mime_types=, move, name, name=, object, object=, 
      # outfile, owned?, path_set, preview, preview_format, preview_format=, project, 
      # project=, read_safe, reload, reload=, request, request=, run, semaphore, 
      # semaphore=, settings, settings=, shell_api, shell_api=, source, source=, status, 
      # sync, target, target=, threadsafe, threadsafe=, timeout, timeout=, tmpdir, 
      # tmpdir=, tmpext, tmpext=, tmpfile, tmpfile=, tmptarget, tmptarget=, transient, 
      # transient_preview, transient=, try_lock, unlock, valid
      
      #
      # when here, then do conversion
      #
      debug # we just do debug
      
    end #def
    
    # Debug previews share the same cache between users: the viewer's role does
    # not protect a debug result generated by another user. Only emit public
    # metadata, not instance variables that may contain paths or request data.
    def debug_fields
      {
        'converter' => name.to_s,
        'converter_version' => version.to_s,
        'plugin_version' => plugin_version.to_s,
        'source_type' => object['type'].to_s,
        'preview_format' => preview_format.to_s
      }.slice(*SAFE_DEBUG_FIELDS)
    end
    private :debug_fields

    def debug
      details = debug_fields

      case preview_format
      when "html", "inline"
        erb = ERB.new(File.read(File.join(__dir__, 'conversion', 'convert.html.erb')))
        obj = erb.result(binding)
      when "txt"
        erb = ERB.new(File.read(File.join(__dir__, 'conversion', 'convert.txt.erb')))
        obj = erb.result(binding)
      when "pdf"
        erb = ERB.new(File.read(File.join(__dir__, 'conversion', 'convert.pdf.erb')))
        obj = erb.result(binding)
      when "jpg", "jpeg", "gif", "png"
        erb = ERB.new(File.read(File.join(__dir__, 'conversion', 'convert.pango.erb')))
        obj = RmpImg.to_img(erb.result(binding), format)
      else
        raise ConverterWrongArgument
      end
      File.binwrite(tmptarget, obj)
    end #def
    
  end #class
end #module
