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

    # Keep full HTML previews in an opaque-origin sandbox, while allowing the
    # preview document to load Redmine/plugin CSS and images from the same
    # response origin. CSP 'self' is matched against the protected response
    # URL's origin; it does not require sandbox allow-same-origin.
    HTML_PREVIEW_CSP =
      "sandbox; default-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self' data:".freeze

    # Converters whose HTML preview may start downloads: the plugin generates that
    # HTML itself (Zippy's archive listing, entry names escaped). Converters that
    # render uploaded content (Pass, Mark, ...) keep the bare sandbox, because
    # allow-downloads removes the sandboxed-downloads flag altogether -- a
    # <meta refresh> to an attachment response would then start a download
    # without any click. The browser applies the union of the iframe attribute
    # and the CSP sandbox directive, so both must carry the flag (see
    # ApplicationHelperPatch#more_previews_tag).
    DOWNLOAD_PREVIEW_CONVERTERS = %w(zippy).freeze

    # +file+ and +options+ must select the converter the same way the conversion
    # does (Converter.convert -> Converter.responsible(file), content detection
    # first): a text/html upload named archive.zip is rendered by Pass, so the
    # extension alone must not grant downloads. Pass the attachment's diskfile,
    # or the entry name with :content => the entry's bytes. Anything unreadable
    # or unknown gets the bare sandbox.
    def self.preview_allows_downloads?(file, options = {})
      return false if file.blank? || (options.key?(:content) && options[:content].nil?)
      converter = RedmineMorePreviews::Converter.responsible(file.to_s, options)
      converter.present? && DOWNLOAD_PREVIEW_CONVERTERS.include?(converter.id.to_s)
    end

    def self.html_preview_csp(file, options = {})
      return HTML_PREVIEW_CSP unless preview_allows_downloads?(file, options)
      HTML_PREVIEW_CSP.sub(/\Asandbox;/, 'sandbox allow-downloads;')
    end

    # only these media types may be served inline as assets; everything else
    # (html, svg, xml and any */*+xml, unknown types, ...) is forced to download
    INLINE_ASSET_MIME_TYPES =
      %r{\A(?:image/(?!svg)|audio/|video/|application/pdf\z|text/plain\z)}.freeze
  
    def preview_params
      params.permit(:format, :asset, :reload, :convert, :unsafe).
      merge({:request => request, 
             :asset   => @asset, 
             :format  => params[:format]&.downcase}.compact )
    end #def
    private :preview_params

    # file / options: see ControllerHelper.preview_allows_downloads?; they decide
    # whether the CSP sandbox allows downloads (DOWNLOAD_PREVIEW_CONVERTERS)
    def apply_preview_security_headers(file = nil, options = {})
      return unless params[:format].to_s.downcase == 'html'

      response.headers['Content-Security-Policy'] = ControllerHelper.html_preview_csp(file, options)
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
      mime = Rack::Mime.mime_type(File.extname(asset.to_s).downcase, nil)

      return 'attachment' unless mime && mime.match?(INLINE_ASSET_MIME_TYPES)

      requested_disposition || 'inline'
    end
    private :secure_asset_disposition
    
  end #module
end #module
