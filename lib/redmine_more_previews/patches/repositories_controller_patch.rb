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
    module RepositoriesControllerPatch
      def self.included(base)
        
        base.class_eval do
          #unloadable
            
         prepend ClassMethods
            
          alias_method  :find_project_repository_for_more_preview, :find_project_repository
          before_action :find_project_repository_for_more_preview, :only => [:more_asset, :more_preview ]
          before_action :find_path_param,                          :only => [:more_asset, :more_preview ]
          
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
            @entry = @repository.entry(@path, @rev)
            if @entry&.convertible?
              if params[:asset]
                @disposition = "attachment"
                respond_to do |format|
                  format.any { send_more_asset }
                end #respond
              else
                respond_to do |format|
                  format.html  { send_more_preview }
                  format.xml   { send_more_preview }
                  format.text  { send_more_preview }
                  format.pdf   { send_more_preview }
                  format.png   { send_more_preview }
                  format.jpeg  { send_more_preview }
                  format.gif   { send_more_preview }
                end
              end
            else #no convertible document
              render_404
            end
          end #def
          
          def more_asset
            @entry = @repository.entry(@path, @rev)
            if @entry&.convertible?
              respond_to do |format|
                format.any { send_more_asset }
              end #respond
            else #no convertible document
              render_404
            end #if
          end #def
          
          ################################################################################
          #
          # private
          #
          ################################################################################
          def send_more_preview
            if !params[:unsafe] && RedmineMorePreviews::Converter.cache_previews?
              # read before the freshness check: the ETag needs the selected converter
              content = entry_content_for_preview
              if params[:reload] || stale?(:etag => preview_etag(@repository.preview_mtime(@path, @rev, preview_params), @entry&.name || @path, :content => content))
                send_data @repository.more_preview(@path, @rev, preview_params, :entry_content => content),
                  :filename    => filename_for_content_disposition( @repository.preview_filename(@path, @rev, preview_params) ),
                  :type        => Rack::Mime.mime_type(".#{params[:format]}"),
                  :disposition => 'inline'
              end
            else #no cache
              content = entry_content_for_preview
              @repository.more_preview(@path, @rev, preview_params, :entry_content => content) do |preview_data|
                 send_data preview_data,
                   :filename    => filename_for_content_disposition( @repository.preview_filename(@path, @rev, preview_params) ),
                   :type        => Rack::Mime.mime_type(".#{params[:format]}"),
                   :disposition => 'inline'
              end
            end
          end #def
          private :send_more_preview

          # reads the entry once: the CSP and the ETag are decided on these bytes (the
          # entry is not on disk, and the converter is chosen by content) and the same
          # bytes are handed to the conversion, so they cannot disagree
          def entry_content_for_preview
            content = @repository.cat(@path, @rev)
            apply_preview_security_headers(@entry&.name || @path, :content => content)
            content
          end
          private :entry_content_for_preview
          
          def send_more_asset
            apply_asset_security_headers

            if !params[:unsafe] && RedmineMorePreviews::Converter.cache_previews?
              if params[:reload] || stale?(:etag => @repository.asset_mtime(@path, @rev, preview_params))
                data = @repository.more_asset(@path, @rev, preview_params)
                return render_404 if data.nil?
                send_data data,
                  :filename    => filename_for_content_disposition( File.basename(@asset) ),
                  :type        => Rack::Mime.mime_type( File.extname(@asset) ),
                  :disposition => secure_asset_disposition(@asset, @disposition)
              end
            else #no cache
              @repository.more_asset(@path, @rev, preview_params) do |preview_data, asset_data|
                 return render_404 if asset_data.nil?
                 send_data asset_data,
                   :filename    => filename_for_content_disposition( File.basename(@asset) ),
                   :type        => Rack::Mime.mime_type( File.extname(@asset) ),
                   :disposition => secure_asset_disposition(@asset, @disposition)
              end
              # the converter failed (f.i. Zip::EntrySizeError): nothing was yielded
              render_404 unless performed?
            end
          end #def
          private :send_more_asset
          
          # see AttachmentsControllerPatch#find_asset_param for the asset validation
          def find_path_param
            @path  = [@path, params[:baseformat]].compact.join(".")
            @asset = params[:asset].is_a?(Array) ? params[:asset].join('/') : params[:asset]
            @asset = [@asset, params[:assetformat]].compact.join(".").presence
            return if @asset.nil?
            @asset = RedmineMorePreviews::Lib::RmpFile.safe_relative_path(@asset)
            render_404 if @asset.nil?
          end #def
          private :find_path_param
          
        end #base
        
      end #self
      
      module ClassMethods
      
        def entry
          @entry = @repository.entry(@path, @rev)
          (show_error_not_found; return) unless @entry
          
          # If the entry is a dir, show the browser
          (show; return) if @entry.is_dir?
          
          if @repository.project.module_enabled?('redmine_more_previews') &&
             @entry.convertible?
              
            parent_path = @path.split('/')[0...-1].join('/')
            @entries = @repository.entries(parent_path, @rev).reject(&:is_dir?)
            if index = @entries.index{|e| e.name == @entry.name}
              @paginator = Redmine::Pagination::Paginator.new(@entries.size, 1, index+1)
            end
            
            if params[:asset]
              # find_path_param renders 404 for an unsafe asset name; it is not a
              # before_action here, so stop instead of sending the asset as well
              find_path_param
              return if performed?
              @disposition = "attachment"
              respond_to do |format|
                format.any { send_more_asset }
              end #respond
            else
              # decided on the entry's content, like the conversion (see ControllerHelper)
              @preview_allows_downloads = RedmineMorePreviews::ControllerHelper.
                preview_allows_downloads?(@entry.name, :content => @repository.cat(@path, @rev))
              render :action => 'more_preview'
            end
          else
            super
          end #if
        end #def 
        
      end #module
      
    end #module
  end #module
end #module

unless RepositoriesController.included_modules.include?(RedmineMorePreviews::Patches::RepositoriesControllerPatch)
  RepositoriesController.send(:include, RedmineMorePreviews::Patches::RepositoriesControllerPatch)
end
