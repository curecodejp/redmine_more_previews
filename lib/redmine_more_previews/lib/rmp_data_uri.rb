# encoding: utf-8
# frozen_string_literal: true

# Redmine plugin to preview various file types in redmine's preview pane
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

require 'base64'
require 'marcel'

module RedmineMorePreviews
  module Lib
    # Images of an HTML preview, embedded in the page as data: URIs.
    #
    # An HTML preview is shown in a sandboxed frame (see ControllerHelper). Its
    # document has an opaque origin, so the browser sends the session cookie
    # (SameSite=Lax) with none of the requests the document makes: an image it
    # links to is refused in a project that is not public, wherever the link
    # points. An image embedded as a data: URI needs no request (the preview's
    # CSP allows img-src data:).
    module RmpDataUri
      # raster images only, judged by their content, never by their name
      MIME_TYPES = %w(image/png image/jpeg image/gif image/webp image/bmp).freeze

      # an image element and the value of its src attribute, which may hold the
      # other quote (LibreOffice writes a "'" of a name as it is)
      IMG_SRC = /(<img\b[^>]*?\bsrc\s*=\s*)(["'])((?:(?!\2)[^<>])*)\2/i

      class << self
        # a data: URI of the image at path, or nil when path is not a regular
        # file inside directory, not a raster image, or its URI would be longer
        # than budget bytes
        def image( directory, path, budget )
          return nil unless path.present? && File.file?( path ) && !File.symlink?( path )
          return nil unless RmpFile.within_directory?( directory, path )
          return nil if uri_size( File.size( path ) ) > budget
          mime = Marcel::MimeType.for( Pathname.new( path ) )
          return nil unless MIME_TYPES.include?( mime )
          "data:#{mime};base64,#{Base64.strict_encode64( File.binread( path ) )}"
        rescue SystemCallError
          nil
        end #def

        # html with the src of each image naming a file in directory replaced by
        # its data: URI, until the URIs would add more than budget bytes. A src
        # with a scheme, a query, a fragment, an absolute path or a ".." is kept
        def embed( html, directory, budget )
          html.gsub( IMG_SRC ) do
            match = Regexp.last_match
            path  = local_path( directory, match[3] )
            uri   = path && image( directory, path, budget )
            if uri
              budget -= uri.bytesize
              "#{match[1]}#{match[2]}#{uri}#{match[2]}"
            else
              match[0]
            end
          end
        end #def

        # the file a relative src names in directory, nil for any other src.
        # A src is percent-encoded (Libre encodes the names it writes, Nokogiri
        # the non-ASCII characters of a src it serializes)
        def local_path( directory, src )
          return nil if src.blank? || src =~ /\A[A-Za-z][A-Za-z0-9+.\-]*:/ || src =~ /[?#]/
          name = src.gsub( /%\h\h/ ) {|code| code[1, 2].hex.chr }.force_encoding( Encoding::UTF_8 )
          return nil unless name.valid_encoding?
          name = RmpFile.safe_relative_path( name )
          name && File.join( directory, name )
        end #def

        # the bytes of a data: URI of a file of size bytes, its media type
        # at most 30 bytes long
        def uri_size( size )
          4 * ((size + 2) / 3) + 'data:;base64,'.bytesize + 30
        end #def
      end
    end
  end
end
