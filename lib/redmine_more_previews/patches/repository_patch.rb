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
          
          ################################################################################
          #
          # preview data functions
          #
          ################################################################################
          # class specific
          def more_preview(path, rev, options={}, &block)
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
          end #def
          
          # class specific
          def more_asset(path, rev, options={}, &block)
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
          end #def
          
          # the entry's bytes, read once per repository instance (i.e. per request):
          # the controller decides the CSP, the cache directory is named and the
          # conversion runs on the same bytes, so they cannot disagree
          def preview_content(path, rev)
            @preview_contents ||= {}
            key = [path, rev]
            return @preview_contents[key] if @preview_contents.key?(key)
            @preview_contents[key] = cat(path, rev)
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
          def asset_link( path, rev, asset )
          
            extname     = File.extname( path)
            basename    = File.basename(path, extname)
            dirname     = File.dirname(path)
            
            assetformat = File.extname(asset)
            assetname   = File.basename(asset, assetformat)
            
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
            
            if asset_available?(path, rev, :asset => asset)
              ApplicationController.helpers.link_to( asset, _link,
                :class => "icon icon-file #{Marcel::MimeType.for(Pathname.new(path, rev, preview_assetpath(:asset => asset)), name: File.basename(asset))&.tr('/', '-')}",
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
          
          # directory containing all preview files and assets
          # the entry's digest stands for the revision: the same path holds other
          # content at another revision (and a Filesystem repository has none)
          def preview_dirname(path, rev, options={})
            format = options[:format].presence || preview_format(path, rev).presence
            File.join(preview_storagepath, path, preview_digest(path, rev), ["preview", format ].compact.join("."))
          end #def
          
          def preview_digest(path, rev)
            @preview_digests ||= {}
            @preview_digests[[path, rev]] ||= Digest::SHA256.hexdigest(preview_content(path, rev).to_s)
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
      
      def self.previews_storagepath
        File.join(RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH, "repository_previews")
      end #def
      
      # up to 6.1.0 the previews were kept per repository class and identifier
      # (f.i. repository/gits/<identifier>/<path>), shared between projects
      def self.remove_legacy_cache
        storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
        legacy  = File.join(storage, "repository")
        return unless File.directory?(legacy) && RedmineMorePreviews::Lib::RmpFile.within_directory?(storage, legacy)
        FileUtils.rm_rf(legacy)
      end #def
      
    end #module
  end #module
end #module

unless Repository.included_modules.include?(RedmineMorePreviews::Patches::RepositoryPatch)
  Repository.send(:include, RedmineMorePreviews::Patches::RepositoryPatch)
end


