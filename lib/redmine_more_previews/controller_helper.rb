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
  module ControllerHelper

    HTML_PREVIEW_CSP =
      "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:".freeze

    # asset extensions a browser would treat as active content when served inline
    ACTIVE_CONTENT_ASSET_EXTENSIONS =
      %w[.html .htm .xhtml .xht .svg .svgz .xml .xsl .xslt .mht .mhtml].freeze
  
    def preview_params
      params.permit(:format, :asset, :reload, :convert, :unsafe).
      merge({:request => request, 
             :asset   => @asset, 
             :format  => params[:format]&.downcase}.compact )
    end #def
    private :preview_params

    def apply_preview_security_headers
      return unless params[:format].to_s.downcase == 'html'

      response.headers['Content-Security-Policy'] = HTML_PREVIEW_CSP
      response.headers['X-Content-Type-Options'] = 'nosniff'
      response.headers['Referrer-Policy'] = 'no-referrer'
    end
    private :apply_preview_security_headers

    def apply_asset_security_headers
      response.headers['X-Content-Type-Options'] = 'nosniff'
    end
    private :apply_asset_security_headers

    # assets extracted from archives etc. must never be rendered inline as
    # active content in the Redmine origin
    def secure_asset_disposition(asset, requested_disposition = nil)
      extension = File.extname(asset.to_s).downcase

      return 'attachment' if ACTIVE_CONTENT_ASSET_EXTENSIONS.include?(extension)

      requested_disposition || 'inline'
    end
    private :secure_asset_disposition
    
  end #module
end #module
