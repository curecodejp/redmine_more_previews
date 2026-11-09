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
# 1.0.5
#       - HEIC/HEIF and TIFF, first image or page, when enabled and readable, up to
#         max_megapixels

class Maggie < RedmineMorePreviews::Conversion

  DENSITIES   = [["72", "72"], ["96", "96"], ["144", "144"], ["300", "300"]]
  CONVERT_BIN = RedmineMorePreviews::CONVERT_BIN
  
  # ImageMagick picks the coder of a file from a "<coder>:" prefix or its content, and
  # reads a name starting with "|" as a command and one starting with "-" as an option:
  # the input is read with the coder the converter was chosen for, and the output gets
  # a fixed name instead of one made from the (user chosen) file name
  CODERS      = {"image/jpeg" => "jpeg", "image/png" => "png", "image/gif" => "gif", "image/bmp" => "bmp"}.freeze
  OUTPUT      = "out"
  
  # see RedmineMorePreviews::IMAGEMAGICK_LIMITS
  LIMITS      = RedmineMorePreviews::IMAGEMAGICK_LIMITS
  
  # Formats that need a coder (and library) ImageMagick may lack, each converted
  # only when one of its extensions is enabled for Maggie, the file starts as the
  # format (Marcel reports the type of an unknown file by its name) and
  # ImageMagick reads the format. Only the first image ([0]: the primary image of
  # a HEIC file, the first page of a TIFF file) is converted. libheif applies the
  # rotation of a HEIC image itself; ImageMagick does not apply the orientation
  # of a TIFF image. The EXIF orientation the source carries is dropped, or the
  # browser would rotate the preview once more.
  IMAGE_FORMATS = {
    "heif" => {:label      => "HEIC/HEIF",
               :mimes      => %w(image/heic image/heif image/heic-sequence image/heif-sequence),
               :extensions => %w(heic heif),
               :magic      => :valid_heif_magic?,
               :coder      => "HEIC",
               :dimensions => :heif_dimensions,
               :options    => "+profile exif"},
    "tiff" => {:label      => "TIFF",
               :mimes      => %w(image/tiff),
               :extensions => %w(tif tiff),
               :magic      => :valid_tiff_magic?,
               :coder      => "TIFF",
               :dimensions => :tiff_dimensions,
               :options    => "-auto-orient +profile exif -colorspace sRGB"}
  }.freeze
  IMAGE_FORMAT_MIMES = IMAGE_FORMATS.values.flat_map{|f| f[:mimes] }.freeze
  
  # libheif and libtiff allocate memory for the size an image declares while
  # decoding it, outside ImageMagick's limits (some bytes per pixel: a 10-bit HEIC
  # image takes about 6). A HEIC or TIFF image is converted only when the size its
  # header declares (see RedmineMorePreviews.heif_dimensions / tiff_dimensions)
  # can be read and is at most max_megapixels (millions of pixels); a larger one is
  # answered with 413. The default lets 48 and 50 megapixel photos of phones pass.
  # A converter setting overrides it.
  SIZE_LIMITS = {'max_megapixels' => 64}.freeze
  
  # the formats (labels) whose coder ImageMagick lacks among the given extensions
  def self.unreadable_formats( extensions )
    IMAGE_FORMATS.values.
      select{|f| (f[:extensions] & extensions.map(&:to_s)).any? && !RedmineMorePreviews.imagemagick_reads?(f[:coder]) }.
      map{|f| f[:label] }
  end #def
    
  def status
    [:text_convert_available, Redmine::Thumbnail.convert_available?]
  end
  
  def convert
    mime_type = Marcel::MimeType.for(Pathname.new(source), name: File.basename(source))
    # Marcel reports video/quicktime for HEIF with most HEVC brands but heic (heix,
    # hevc, hevx, heim, heis, msf1, ...)
    mime_type = "image/heic" if mime_type == "video/quicktime" && RedmineMorePreviews.valid_heif_magic?(source)
    output    = thisdir("#{OUTPUT}.#{preview_format}")
    
    cmd = case mime_type
    when "image/jpeg", "image/png"
      "#{convert_command} -resample #{get_density}x#{get_density} #{shell_quote "#{CODERS[mime_type]}:#{source}"} #{shell_quote "#{preview_format}:#{output}"}"
      
    when "image/gif", "image/bmp"
      "#{convert_command} -density 72x72 #{shell_quote "#{CODERS[mime_type]}:#{source}"} -resample #{get_density}x#{get_density} #{shell_quote "#{preview_format}:#{output}"}"
    
    when *IMAGE_FORMAT_MIMES
      format = IMAGE_FORMATS.values.find{|f| f[:mimes].include?(mime_type) }
      if readable?(format) && within_limits?(format)
        "#{convert_command} -density 72x72 #{shell_quote "#{format[:coder].downcase}:#{source}[0]"} #{format[:options]} -resample #{get_density}x#{get_density} #{shell_quote "#{preview_format}:#{output}"}"
      end
      
    when "application/pdf"
      # Without Ghostscript a PDF cannot be rasterized. Never copy the
      # source PDF under a PNG/JPEG/GIF preview filename.
      if RedmineMorePreviews.valid_pdf_magic?(source) && Redmine::Thumbnail.gs_available?
        "#{convert_command} -density #{get_density} #{shell_quote "pdf:#{source}[0]"} #{shell_quote "#{preview_format}:#{output}"}"
      end
    end
    command( cd + join + cmd + join + move(output)) if cmd
  end #def
  
  def convert_command
    RedmineMorePreviews.convert_command
  end #def
  
  def readable?( format )
    enabled = converter_settings.to_h.dig("mime_types").to_h
    format[:extensions].any?{|ext| [true, 1, "1"].include?(enabled.dig(ext, "active")) } &&
      RedmineMorePreviews.send(format[:magic], source) &&
      RedmineMorePreviews.imagemagick_reads?(format[:coder])
  end #def
  
  # whether the size the image declares can be read and is within max_megapixels
  def within_limits?( format )
    width, height = RedmineMorePreviews.send(format[:dimensions], source)
    return false unless width && height
    if width * height > limit('max_megapixels') * 1_000_000
      raise RedmineMorePreviews::Exceptions::ConverterTooLarge,
            "#{File.basename(source)} declares #{width}x#{height} pixels, more than #{limit('max_megapixels')} megapixels"
    end
    true
  end #def
  
  def limit( key )
    value = converter_settings.to_h[key].to_i
    value > 0 ? value : SIZE_LIMITS[key]
  end #def
  
  def get_density
    DENSITIES.map{|a| a[1]}.include?(converter_settings['density'] ) ? converter_settings['density'] : "72"
  end #def
  
end #class