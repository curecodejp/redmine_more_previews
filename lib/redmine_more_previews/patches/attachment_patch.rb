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
    module AttachmentPatch
      def self.included(base)
        base.class_eval do
          #unloadable
          
          # the previews of an attachment go with it (see remove_more_preview_cache_on_destroy)
          after_destroy_commit :remove_more_preview_cache_on_destroy

          ################################################################################
          #
          # preview data functions
          #
          ################################################################################
          # class specific
          def more_preview(options={}, &block)
            convert_attachment(:preview_filepath, options, &block)
          end #def
          
          # class specific
          def more_asset(options={}, &block)
            convert_attachment(:preview_assetpath, options, &block)
          end #def

          # target: the method giving the path of the preview or asset. nil if
          # the attachment was deleted: a conversion does not start after its
          # deletion, and one running then removes its previews when it ends
          # (see RmpLifecycle)
          def convert_attachment(target, options, &block)
            RedmineMorePreviews::Lib::RmpLifecycle.hold(Attachment, previews_storagepath, id) do
              RedmineMorePreviews::Converter.convert(
                diskfile,
                send(target, options),
                options.merge(
                  :object => {:type => :attachment, :object => self},
                  :converter => preview_selection["converter"],
                  :preview_format => preview_format
                ),
                &block
              )
            end
          end #def
          private :convert_attachment
          
          def preview_convertible?
            RedmineMorePreviews::Converter.convertible?(filename)
          end #def
          
          def preview_available?(options={})
            File.exist?(preview_filepath(options))
          end #def
          
          def asset_available?(options={})
            File.exist?(preview_assetpath(options))
          end #def
          
          # how this file is converted (see Converter.selection): decided once,
          # on the content of the file as the conversion decides it, so that the
          # converter, the format it is given, the directory its preview is
          # stored in and the URL of the preview cannot disagree. A file that
          # cannot be read is not converted
          def preview_selection
            @preview_selections ||= {}
            @preview_selections.fetch(diskfile) do
              @preview_selections[diskfile] =
                begin
                  RedmineMorePreviews::Converter.selection(diskfile)
                rescue SystemCallError
                  {}
                end
            end
          end #def
          
          # the output format configured for the converter of this file. A
          # request names a format only to be compared with it
          def preview_format
            preview_selection["format"]
          end #def
          
          # the media type of the preview
          def preview_mime
            RedmineMorePreviews::Converter::FORMAT_MIMES[preview_format].presence || "application/octet-stream"
          end #def
          
          def preview_mtime(options={})
            preview_available?(options) ? File.mtime(preview_filepath(options)) : Time.now
          end #def
          
          def asset_mtime(options={})
            asset_available?(options) ? File.mtime(preview_assetpath(options)) : Time.now
          end #def
          
          ################################################################################
          #
          # path functions
          #
          ################################################################################
          # The Cliff converter calls this while generating its attachment list,
          # before the extracted files have been copied to the preview cache.
          # Only that known-extracted path may bypass the cache existence check.
          def asset_link( asset, generated = false )
            extname = File.extname(asset)
            # The route requires an extension. Keep extensionless attachments
            # visible as escaped text rather than making the entire email fail.
            return ERB::Util.html_escape(asset.to_s) if extname.length <= 1

            basename = File.basename(asset, extname)
            _link = Rails.application.routes.url_helpers.more_asset_path(
              self, basename, extname[1..-1]
            )

            if generated || asset_available?(:asset => asset)
              ApplicationController.helpers.link_to( asset, _link,
               :class => "icon icon-file #{Marcel::MimeType.for(generated ? nil : Pathname.new(preview_assetpath(:asset => asset)), name: File.basename(asset))&.tr('/', '-')}",
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
            RedmineMorePreviews::Patches::AttachmentPatch.previews_storagepath
          end #def
          
          # directory of this preview
          def preview_storagepath
            File.join(previews_storagepath, id.to_s)
          end #def
          
          # directory containing all preview files and assets, named after the
          # configured format: the format of a request names no directory
          def preview_dirname(options={})
            File.join(preview_storagepath, ["preview", preview_format.presence ].compact.join("."))
          end #def
          
          #
          # files
          #
          
          # preview file name
          def preview_filename(options={})
            ["index", preview_format.presence].compact.join(".")
          end #def
          
          # full path to preview file on disk
          def preview_filepath(options={})
            File.join(preview_dirname(options), preview_filename(options) )
          end #def
          
          # asset file name
          def preview_assetname(options={})
            assetformat = options[:assetformat].presence
            [options[:asset], assetformat].compact.join(".")
          end #def
          
          # full path to asset file on disk
          def preview_assetpath(options={})
             File.join(preview_dirname(options), preview_assetname(options) )
         end #def
          
          # The previews are kept by the id of the attachment: they are removed with
          # it, also when its file stays because another attachment shares it
          # (Attachment#delete_from_disk keeps such a file, and removes the file
          # and the thumbnails as without the plugin). A link in place of the
          # previews is removed, not followed (see RmpLifecycle)
          def remove_more_preview_cache_on_destroy
            RedmineMorePreviews::Lib::RmpLifecycle.remove(Attachment, previews_storagepath, id)
          end #def
          private :remove_more_preview_cache_on_destroy
          
        end #base
      end #self

      def self.previews_storagepath
        File.join(RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH, "attachments")
      end #def
       
    end
  end  
end

unless Attachment.included_modules.include?(RedmineMorePreviews::Patches::AttachmentPatch)
  Attachment.send(:include, RedmineMorePreviews::Patches::AttachmentPatch)
end

