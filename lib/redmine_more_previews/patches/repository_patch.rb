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
            convert_entry(path, rev, :preview_filepath, options, &block)
          end #def
          
          # class specific
          # the asset path, not the preview path (as in Attachment#more_asset):
          # with the preview as target a cached listing counted as "valid" and
          # the asset was never extracted
          def more_asset(path, rev, options={}, &block)
            convert_entry(path, rev, :preview_assetpath, options, &block)
          end #def

          # target: the method giving the path of the preview or asset. The entry is
          # written to a file of its name when it is converted, not when a stored
          # preview is served (see Converter.convert)
          def convert_entry(path, rev, target, options, &block)
            # nil if the repository was deleted (see RmpLifecycle)
            with_repository_preview_lifecycle_lock do
              if (e = preview_entry(path, rev))
                Dir.mktmpdir do |tmpdir|
                  RedmineMorePreviews::Converter.convert(
                    File.join(tmpdir, e.name),
                    send(target, path, rev, options),
                    options.merge(
                      :object => {:type => :repository, :object => self, :path => path, :rev => rev},
                      :converter => preview_selection(path, rev)["converter"],
                      :preview_format => preview_format(path, rev),
                      :source_content => -> { preview_content(path, rev) }
                    ),
                    &block
                  )
                end #Dir
              elsif block_given?
                yield nil
              end #if
            end
          end #def
          private :convert_entry

          # the entry, asked for once per repository instance (i.e. per request): the
          # SCM lists the directory of the entry each time (git starts git ls-tree),
          # and a request asks for it many times (the controller, the size, the
          # converter, each fragment of an email shown on its page)
          def preview_entry(path, rev)
            @preview_entries ||= {}
            key = [path, rev]
            return @preview_entries[key] if @preview_entries.key?(key)
            @preview_entries[key] = entry(path, rev)
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
            size = preview_entry(path, rev)&.size
            size.nil? || size.to_i > RedmineMorePreviews::Converter.max_repository_file
          end #def
          
          def preview_available?(path, rev, options={})
            File.exist?(preview_filepath(path, rev, options))
          end #def
          
          def asset_available?(path, rev, options={})
            File.exist?(preview_assetpath(path, rev, options))
          end #def
          
          # how the entry is converted (see Converter.selection): decided once per
          # repository instance (i.e. per request), on the bytes the conversion
          # runs on (see preview_content), so that the converter, the format it is
          # given, the directory its preview is stored in and the URL of the
          # preview cannot disagree. An entry the SCM gives no content for is
          # converted as an empty file (see more_preview), and decided as one:
          # never on a file of its name on the server
          def preview_selection(path, rev)
            @preview_selections ||= {}
            key = [path, rev]
            return @preview_selections[key] if @preview_selections.key?(key)
            e = preview_entry(path, rev)
            @preview_selections[key] =
              e ? RedmineMorePreviews::Converter.selection(e.name, :content => preview_content(path, rev).to_s) : {}
          end #def
          
          # the output format configured for the converter of the entry. A
          # request names a format only to be compared with it
          def preview_format(path, rev)
            preview_selection(path, rev)["format"]
          end #def
          
          # the media type of the preview
          def preview_mime(path, rev)
            RedmineMorePreviews::Converter::FORMAT_MIMES[preview_format(path, rev)].presence || "application/octet-stream"
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
          
          # see RmpLifecycle.hold
          def with_repository_preview_lifecycle_lock(&block)
            RedmineMorePreviews::Lib::RmpLifecycle.hold(Repository, previews_storagepath, id, &block)
          end
          private :with_repository_preview_lifecycle_lock

          def remove_more_preview_cache_on_destroy
            RedmineMorePreviews::Lib::RmpLifecycle.remove(Repository, previews_storagepath, id)
          end
          private :remove_more_preview_cache_on_destroy

          # directory containing all preview files and assets
          # per revision and content: the same path holds other content at another
          # revision (and a Filesystem repository has no revision), and a preview
          # links to the revision it was generated for (f.i. Zippy's asset links)
          # named after the configured format: the format of a request names no
          # directory
          def preview_dirname(path, rev, options={})
            File.join(preview_storagepath, path, preview_digest(path, rev), ["preview", preview_format(path, rev).presence ].compact.join("."))
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
            ["index", preview_format(path, rev).presence].compact.join(".")
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
            File.join(preview_dirname(path, rev, options), preview_assetname(path, rev, options) )
          end #def
          
        end #base
      end #self
      
      # see RmpLifecycle.cleanup
      def self.cleanup_removed_repository_cache(repository_id)
        RedmineMorePreviews::Lib::RmpLifecycle.cleanup(Repository, previews_storagepath, repository_id)
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


