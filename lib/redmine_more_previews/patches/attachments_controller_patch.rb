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
    module AttachmentsControllerPatch
      def self.included(base)
        
        base.class_eval do
          #unloadable
          
          prepend ClassMethods
          
          alias_method  :find_attachment_for_more_preview, :find_attachment
          alias_method  :file_readable_for_more_preview,   :file_readable
          alias_method  :read_authorize_for_more_preview,  :read_authorize
          before_action :find_attachment_for_more_preview, :only => [:more_preview, :more_asset]
          # Mirror Redmine's show/download filters: a missing or unreadable
          # attachment must return 404 before any cache/ETag or conversion work.
          before_action :file_readable_for_more_preview,   :only => [:more_preview, :more_asset]
          before_action :read_authorize_for_more_preview,  :only => [:more_preview, :more_asset]
          before_action :ensure_more_previews_module_enabled, :only => [:more_preview, :more_asset]
          before_action :find_asset_param,                 :only => [:more_preview, :more_asset]
          before_action :ensure_configured_preview_format, :only => [:more_preview]
          rescue_from   RedmineMorePreviews::Exceptions::ConverterLockTimeOut, :with => :render_more_preview_busy
          rescue_from   RedmineMorePreviews::Exceptions::ConverterTooLarge,    :with => :render_more_preview_too_large
          
          ################################################################################
          #
          # include helpers
          #
          ################################################################################
          include RedmineMorePreviews::ControllerHelper
          
          ################################################################################
          #
          # controller actions
          #
          ################################################################################
          def more_preview
            if @attachment.preview_convertible?
              respond_with_more_preview
            else #no convertible document
              render_404
            end
          end #def
          
          def more_asset
            if @attachment.preview_convertible?
              respond_with_more_asset
            else #no convertible document
              render_404
            end #if
          end #def
          
          ################################################################################
          #
          # private
          #
          ################################################################################
          # The standard attachment permission check still applies. A project
          # administrator may separately disable preview conversion for a project.
          # Reject direct preview and asset requests for disabled projects too.
          def ensure_more_previews_module_enabled
            render_404 unless @attachment.project&.module_enabled?('redmine_more_previews')
          end
          private :ensure_more_previews_module_enabled

          # see ControllerHelper#preview_format_requested?
          def ensure_configured_preview_format
            render_404 unless preview_format_requested?(@attachment.preview_format)
          end
          private :ensure_configured_preview_format

          # see ControllerHelper#send_more_preview
          def more_preview_record; @attachment;          end
          def more_preview_args;   [];                   end
          def more_preview_name;   @attachment.filename; end
          # the converter is selected on the file on disk
          def more_preview_source; [@attachment.diskfile, {}]; end
          private :more_preview_record, :more_preview_args, :more_preview_name, :more_preview_source
          
          # see ControllerHelper#more_preview_asset
          def find_asset_param
            @asset = more_preview_asset(params[:asset].is_a?(Array) ? params[:asset].join('/') : params[:asset])
          end #def
          private :find_asset_param
        end #base
        
      end #self
      
      module ClassMethods
      
        def show
          if @attachment.project&.module_enabled?('redmine_more_previews') &&
             request.format.html? &&
             @attachment.preview_convertible?
            if @attachment.container.respond_to?(:attachments)
              @attachments = @attachment.container.attachments.to_a
              if index = @attachments.index(@attachment)
                @paginator = Redmine::Pagination::Paginator.new(
                  @attachments.size, 1, index+1
                )
              end
            end
            render :action => 'more_preview', :formats => :html
          else
            super
          end
        end #def 
        
      end #module  
    end #module
  end #module
end #module

unless AttachmentsController.included_modules.include?(RedmineMorePreviews::Patches::AttachmentsControllerPatch)
  AttachmentsController.send(:include, RedmineMorePreviews::Patches::AttachmentsControllerPatch)
end

