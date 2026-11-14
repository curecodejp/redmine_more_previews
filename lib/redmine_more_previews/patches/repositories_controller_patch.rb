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
          before_action :ensure_more_previews_module_enabled, :only => [:more_asset, :more_preview ]
          before_action :find_path_param,                          :only => [:more_asset, :more_preview ]
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
            @entry = @repository.preview_entry(@path, @rev)
            # see ControllerHelper#preview_format_requested?; the entry is read
            # here, once (a file too large to read is answered with 413)
            if @entry&.convertible? && preview_format_requested?(@repository.preview_format(@path, @rev))
              respond_with_more_preview
            else #no convertible document
              render_404
            end
          end #def
          
          def more_asset
            @entry = @repository.preview_entry(@path, @rev)
            if @entry&.convertible?
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
          # Reading the underlying repository requires its usual permission,
          # but the project's module toggle must also disable direct previews.
          def ensure_more_previews_module_enabled
            render_404 unless @repository.project.module_enabled?('redmine_more_previews')
          end
          private :ensure_more_previews_module_enabled

          # see ControllerHelper#send_more_preview
          def more_preview_record; @repository;    end
          def more_preview_args;   [@path, @rev];  end
          def more_preview_name;   @entry.name;    end
          # the bytes more_preview read (Repository#preview_content keeps them for
          # the request): the CSP, the media type and the ETag are decided on them
          # (the entry is not on disk, and the converter is chosen by content), and
          # the conversion uses them, so they cannot disagree
          def more_preview_source
            [@entry.name, {:content => @repository.preview_content(@path, @rev)}]
          end
          private :more_preview_record, :more_preview_args, :more_preview_name, :more_preview_source
          
          # see ControllerHelper#more_preview_asset
          def find_path_param
            @path  = [@path, params[:baseformat]].compact.join(".")
            asset  = params[:asset].is_a?(Array) ? params[:asset].join('/') : params[:asset]
            # the asset route matches ".../file.ext@/image.png": the name it
            # takes starts with the "/" after the "@", a link relative to the
            # preview (".../file.ext@/index.html") always has it
            asset  = asset.delete_prefix("/") if action_name == "more_asset" && asset.is_a?(String)
            @asset = more_preview_asset(asset)
          end #def
          private :find_path_param
          
        end #base
        
      end #self
      
      module ClassMethods
      
        def entry
          @entry = @repository.preview_entry(@path, @rev)
          (show_error_not_found; return) unless @entry
          
          # If the entry is a dir, show the browser
          (show; return) if @entry.is_dir?
          
          # a file too large to preview is shown as Redmine shows it
          if @repository.project.module_enabled?('redmine_more_previews') &&
             @entry.convertible? && !@repository.preview_too_large?(@path, @rev)
              
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
              respond_with_more_asset
            else
              # only the html preview is sandboxed, so only that page needs the
              # download decision (made on the entry's content, like the conversion)
              if @repository.preview_format(@path, @rev) == 'html'
                @preview_allows_downloads = RedmineMorePreviews::ControllerHelper.
                  preview_allows_downloads?(@entry.name, :content => @repository.preview_content(@path, @rev))
              end
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
