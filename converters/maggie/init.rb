# encoding: utf-8
#
# RedmineMorePreviews preview / convert images
#
# Copyright © 2020 Stephan Wenzel <stephan.wenzel@drwpatent.de>
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
# 1.0.0
#       - initial version
# 1.0.1
#       - simplified code version
# 1.0.2
#       - fixed japanese localization
# 1.0.3
#       - validate PDF headers, explicit ImageMagick formats, resource limits
# 1.0.4
#       - share the ImageMagick resource limits with Peek
# 1.0.5
#       - HEIC/HEIF and TIFF (first image or page), when ImageMagick reads them
#
require_relative 'lib/maggie'

RedmineMorePreviews::Converter.register :maggie do
  name           'Maggie'
  author         'Stephan Wenzel'
  description    'Convert images'
  version        '1.0.5'
  url            'https://github.com/HugoHasenbein/redmine_more_previews_maggie'
  author_url     'https://github.com/HugoHasenbein/redmine_more_previews_maggie'
                 
  settings       :logo    => "logo.png",
                 :partial => 'settings/redmine_more_previews/maggie/settings'
                 
  mime_types(    :png  =>    {:formats => [:png, :jpg, :gif], :mime => "image/png",        :icon => "png.png" },
                 :jpg  =>    {:formats => [:png, :jpg, :gif], :mime => "image/jpeg",       :icon => "jpg.png" },
                 :gif  =>    {:formats => [:png, :jpg, :gif], :mime => "image/gif",        :icon => "gif.png" },
                 :bmp  =>    {:formats => [:png, :jpg, :gif], :mime => "image/bmp",        :icon => "bmp.png" },
                 :pdf  =>    {:formats => [:png, :jpg, :gif], :mime => "application/pdf",  :icon => "pdf.png" },
                 :heic =>    {:formats => [:png, :jpg, :gif], :mime => "image/heic" },
                 :heif =>    {:formats => [:png, :jpg, :gif], :mime => "image/heif" },
                 :tif  =>    {:formats => [:png, :jpg, :gif], :mime => "image/tiff" },
                 :tiff =>    {:formats => [:png, :jpg, :gif], :mime => "image/tiff" },
            )
end


