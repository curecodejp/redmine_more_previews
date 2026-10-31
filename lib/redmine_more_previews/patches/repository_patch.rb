# encoding: utf-8
# frozen_string_literal: true
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

module RedmineMorePreviews
  module Patches
    module RepositoryPatch
      def self.included(base)
        base.class_eval do
          #unloadable

          # Repository IDs scope cached previews. When a repository is deleted,
          # its cached files must not remain on the server indefinitely.
          # The disk cache is derived data. Do not delete it if the database
          # transaction rolls back the repository deletion.
          after_destroy_commit :remove_more_preview_cache_on_destroy

          ################################################################################
          #
          # preview data functions
          #
          ################################################################################
          # class specific
          def more_preview(path, rev, options={}, &block)
            with_repository_preview_lifecycle_lock do
              # Check after acquiring the lifecycle lock. Already-started
              # requests cannot recreate cache after a committed deletion.
              # Unlike a persistent tombstone, a DB restore may reuse this ID.
              return nil unless Repository.uncached { Repository.unscoped.exists?(id) }
              if entry(path, rev)
                Dir.mktmpdir do |tmpdir|
                  filepath = File.join(tmpdir, entry(path, rev).name)
                  File.open( filepath, "wb") {|f| f.write(preview_content(path, rev))}
                  RedmineMorePreviews::Converter.convert(
                    filepath,
                    preview_filepath(path, rev, options),
                    options.merge(
                      :object => {:type => :repository, :object => self, :path => path, :rev => rev},
                      :preview_format => preview_format(path, rev)
                    ), 
                    &block
                  )
                end #Dir
              elsif block_given?
                yield nil
              end #if
            end
          end #def
          
          # class specific
          def more_asset(path, rev, options={}, &block)
            with_repository_preview_lifecycle_lock do
              # Check after acquiring the lifecycle lock. Already-started
              # requests cannot recreate cache after a committed deletion.
              # Unlike a persistent tombstone, a DB restore may reuse this ID.
              return nil unless Repository.uncached { Repository.unscoped.exists?(id) }
              if entry(path, rev)
                Dir.mktmpdir do |tmpdir|
                  filepath = File.join(tmpdir, entry(path, rev).name)
                  File.open( filepath, "wb") {|f| f.write(preview_content(path, rev))}
                  # the asset path, not the preview path (as in Attachment#more_asset):
                  # with the preview as target a cached listing counted as "valid" and
                  # the asset was never extracted
                  RedmineMorePreviews::Converter.convert(
                    filepath,
                    preview_assetpath(path, rev, options),
                    options.merge(
                      :object => {:type => :repository, :object => self, :path => path, :rev => rev},
                      :preview_format => preview_format(path, rev)
                    ), 
                    &block
                  )
                end #Dir
              elsif block_given?
                yield nil
              end #if
            end
          end #def
          
          # the entry's bytes, read once per repository instance (i.e. per request):
          # the controller decides the CSP, the cache directory is named and the
          # conversion runs on the same bytes, so they cannot disagree
          def preview_content(path, rev)
            @preview_contents ||= {}
            key = [path, rev]
            return @preview_contents[key] if @preview_contents.key?(key)
            # repository files are not bound by the attachment size limit: the size
            # the SCM reports is checked before the file is read (cat reads it whole)
            if preview_too_large?(path, rev)
              raise RedmineMorePreviews::Exceptions::ConverterTooLarge, "#{path} is larger than #{RedmineMorePreviews::Converter.max_repository_file} bytes, or of unknown size"
            end
            @preview_contents[key] = cat(path, rev)
          end #def
          
          # a file whose size the SCM does not report (Bazaar, CVS) counts as too
          # large: it could only be checked after it has been read whole
          def preview_too_large?(path, rev)
            size = entry(path, rev)&.size
            size.nil? || size.to_i > RedmineMorePreviews::Converter.max_repository_file
          end #def
          
          def preview_available?(path, rev, options={})
            File.exist?(preview_filepath(path, rev, options))
          end #def
          
          def asset_available?(path, rev, options={})
            File.exist?(preview_assetpath(path, rev, options))
          end #def
          
          # class specific
          def preview_format(path, rev)
            if e = entry(path, rev)
              extension = File.extname(e.name)[1..-1].downcase
              RedmineMorePreviews::Converter.conversion_extension(extension) if extension
            end
          end #def
          
          def preview_mtime(path, rev, options={})
            preview_available?(path, rev, options) ? File.mtime(preview_filepath(path, rev, options)) : Time.now
          end #def
          
          def asset_mtime(path, rev, options={})
            asset_available?(path, rev, options) ? File.mtime(preview_assetpath(path, rev, options)) : Time.now
          end #def
          
          ################################################################################
          #
          # path functions
          #
          ################################################################################
          # generated is used only while Cliff writes its freshly extracted
          # attachments.html; public links otherwise require a stored asset.
          def asset_link( path, rev, asset, generated = false )
            # Both repository asset routes require an extension as well.
            assetformat = File.extname(asset)
            return ERB::Util.html_escape(asset.to_s) if assetformat.length <= 1

            extname     = File.extname( path)
            basename    = File.basename(path, extname)
            dirname     = File.dirname(path)
            
            # Preserve the relative subdirectory when removing the extension:
            # the controller rebuilds the nested cache path from :asset.
            assetname   = asset.delete_suffix(assetformat)
            
            _link = Rails.application.routes.url_helpers.url_for(
              :controller    => "repositories",
              :action        => "more_asset",
              :id            => project.identifier,
              :repository_id => identifier_param,
              :rev           => rev,
              :path          => [dirname, basename].join("/"),
              :baseformat    => extname[1..-1],
              :asset         => assetname,
              :assetformat   => assetformat[1..-1], 
              :only_path     => true
            )
            
            if generated || asset_available?(path, rev, :asset => asset)
              ApplicationController.helpers.link_to( asset, _link,
                :class => "icon icon-file #{Marcel::MimeType.for(generated ? nil : Pathname.new(preview_assetpath(path, rev, :asset => asset)), name: File.basename(asset))&.tr('/', '-')}",
                :style => "padding-top:2px;padding-bottom:2px;"
              )
            else
              "" # asset does not exist
            end
          end #def
          
          ################################################################################
          #
          # preview file functions
          #
          ################################################################################
          
          #
          # directories
          #
          
          # directory of all previews
          def previews_storagepath
            RedmineMorePreviews::Patches::RepositoryPatch.previews_storagepath
          end #def
          
          # directory of the previews of this repository: the identifier is unique
          # only within a project (and blank for the default repository)
          def preview_storagepath
            File.join(previews_storagepath, id.to_s)
          end #def
          
          # Shared locks allow concurrent previews. Deletion takes an exclusive
          # lock, outside the cache tree, to wait for active converters.
          # Both lock modes have a bounded wait to avoid hanging request threads.
          def with_repository_preview_lifecycle_lock(mode = File::LOCK_SH)
            FileUtils.mkdir_p(previews_storagepath)
            File.open("#{preview_storagepath}.lifecycle.lock", File::RDWR | File::CREAT, 0644) do |lock|
              deadline = RedmineMorePreviews::Lib::RmpProcess.now + RedmineMorePreviews::Converter.lock_timeout
              until lock.flock(mode | File::LOCK_NB)
                if RedmineMorePreviews::Lib::RmpProcess.now >= deadline
                  raise RedmineMorePreviews::Exceptions::ConverterLockTimeOut, "repository preview #{id} is busy"
                end
                sleep 0.05
              end
              begin
                yield
              ensure
                lock.flock(File::LOCK_UN)
              end
            end
          ensure
            if mode == File::LOCK_SH && File.file?("#{preview_storagepath}.cleanup_pending")
              RedmineMorePreviews::Patches::RepositoryPatch.cleanup_removed_repository_cache(id)
            end
          end
          private :with_repository_preview_lifecycle_lock

          def remove_more_preview_cache_on_destroy
            # Persist the intent before trying the exclusive lock. An active
            # conversion may outlive the HTTP request that destroyed the row;
            # it will retry cleanup when its shared lock is released.
            FileUtils.mkdir_p(previews_storagepath)
            File.write("#{preview_storagepath}.cleanup_pending", "pending\n")
            RedmineMorePreviews::Patches::RepositoryPatch.cleanup_removed_repository_cache(id)
          rescue StandardError => e
            Rails.logger.error "Repository preview cache cleanup failed: #{e.class}: #{e.message}"
          end
          private :remove_more_preview_cache_on_destroy

          # directory containing all preview files and assets
          # per revision and content: the same path holds other content at another
          # revision (and a Filesystem repository has no revision), and a preview
          # links to the revision it was generated for (f.i. Zippy's asset links)
          def preview_dirname(path, rev, options={})
            format = options[:format].presence || preview_format(path, rev).presence
            File.join(preview_storagepath, path, preview_digest(path, rev), ["preview", format ].compact.join("."))
          end #def
          
          def preview_digest(path, rev)
            @preview_digests ||= {}
            @preview_digests[[path, rev]] ||=
              Digest::SHA256.new.update(rev.to_s).update("\0").update(preview_content(path, rev).to_s).hexdigest
          end #def
          
          #
          # files
          #
          
          # preview file name
          def preview_filename(path, rev, options={})
            format = options[:format].presence || preview_format(path, rev).presence
            ["index", format].compact.join(".")
          end #def
          
          # full path to preview file on disk
          def preview_filepath(path, rev, options={})
            File.join(preview_dirname(path, rev, options), preview_filename(path, rev, options) )
          end #def
          
          # asset file name
          # as Attachment#preview_assetname: the asset keeps its own name, the requested
          # preview format is not appended to it
          def preview_assetname(path, rev, options={})
            assetformat = options[:assetformat].presence
            [options[:asset], assetformat].compact.join(".")
          end #def
          
          # full path to asset file on disk
          def preview_assetpath(path, rev, options={})
#           File.join(preview_dirname(path, rev, options.merge(:format => preview_format(path, rev))), preview_filename(path, rev, options) )
            File.join(preview_dirname(path, rev, options.merge(:format => preview_format(path, rev))), preview_assetname(path, rev, options) )
          end #def
          
        end #base
      end #self
      
      # Non-blocking cleanup: do not hold a Redmine request open for the entire
      # conversion timeout. A pending marker survives worker restarts and is
      # retried by exiting preview requests and the cache-clean rake task.
      def self.cleanup_removed_repository_cache(repository_id)
        return false unless repository_id.to_s.match?(/\A[0-9]+\z/)
        root = previews_storagepath
        dir = File.join(root, repository_id.to_s)
        pending = "#{dir}.cleanup_pending"
        return false unless File.file?(pending)

        File.open("#{dir}.lifecycle.lock", File::RDWR | File::CREAT, 0644) do |lock|
          return false unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          begin
            if Repository.uncached { Repository.unscoped.exists?(repository_id) }
              # A restored database reused this ID: remove only the stale
              # cleanup request, never the new repository's previews.
              File.delete(pending) if File.file?(pending)
              return true
            end

            if File.symlink?(dir)
              File.unlink(dir) # remove the link, not its external target
            elsif File.directory?(dir)
              unless RedmineMorePreviews::Lib::RmpFile.within_directory?(root, dir)
                raise ArgumentError, 'repository cache path is outside storage'
              end
              FileUtils.remove_entry_secure(dir)
            end
            File.delete(pending) if File.file?(pending)
            true
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      rescue StandardError => e
        Rails.logger.error "Repository preview cache cleanup failed: #{e.class}: #{e.message}"
        false
      end

      def self.previews_storagepath
        File.join(RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH, "repository_previews")
      end #def
      
      # up to 6.1.0 the previews were kept per repository class and identifier
      # (f.i. repository/gits/<identifier>/<path>), shared between projects
      def self.remove_legacy_cache
        storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
        legacy  = File.join(storage, "repository")
        return unless File.directory?(legacy) && RedmineMorePreviews::Lib::RmpFile.within_directory?(storage, legacy)
        # only the former cache directories: the storage path may be a shared one
        Redmine::Scm::Base.all.each do |scm|
          dir = File.join(storage, "Repository::#{scm}".underscore.pluralize)
          next unless File.directory?(dir) && RedmineMorePreviews::Lib::RmpFile.within_directory?(storage, dir)
          FileUtils.rm_rf(dir)
        end
        begin
          Dir.rmdir(legacy)
        rescue Errno::ENOTEMPTY, Errno::ENOENT
          # other content is kept; or another process (f.i. a Puma worker) removed it
        end
      end #def
      
    end #module
  end #module
end #module

unless Repository.included_modules.include?(RedmineMorePreviews::Patches::RepositoryPatch)
  Repository.send(:include, RedmineMorePreviews::Patches::RepositoryPatch)
end


