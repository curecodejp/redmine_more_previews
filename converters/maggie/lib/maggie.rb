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

class Maggie < RedmineMorePreviews::Conversion

  DENSITIES   = [["72", "72"], ["96", "96"], ["144", "144"], ["300", "300"]]
  CONVERT_BIN = (Redmine::Configuration['imagemagick_convert_command'] || 'convert').freeze
  
  # ImageMagick picks the coder of a file from a "<coder>:" prefix or its content, and
  # reads a name starting with "|" as a command and one starting with "-" as an option:
  # the input is read with the coder the converter was chosen for, and the output gets
  # a fixed name instead of one made from the (user chosen) file name
  CODERS      = {"image/jpeg" => "jpeg", "image/png" => "png", "image/gif" => "gif", "image/bmp" => "bmp"}.freeze
  OUTPUT      = "out"
  
  # bounds of ImageMagick's pixel cache. width, height and disk are hard limits (the
  # conversion fails): -resample enlarges an image by its own resolution, which the
  # file sets. They do not bound Ghostscript's rendering of a PDF page.
  LIMITS      = [["width", "16KP"], ["height", "16KP"], ["area", "128MP"],
                 ["memory", "256MiB"], ["map", "512MiB"], ["disk", "1GiB"]].freeze
    
  def status
    [:text_convert_available, Redmine::Thumbnail.convert_available?]
  end
  
  def convert
    mime_type = Marcel::MimeType.for(Pathname.new(source), name: File.basename(source))
    output    = thisdir("#{OUTPUT}.#{preview_format}")
    
    cmd = case mime_type
    when "image/jpeg", "image/png"
      "#{convert_command} -resample #{get_density}x#{get_density} #{shell_quote "#{CODERS[mime_type]}:#{source}"} #{shell_quote "#{preview_format}:#{output}"}"
      
    when "image/gif", "image/bmp"
      "#{convert_command} -density 72x72 #{shell_quote "#{CODERS[mime_type]}:#{source}"} -resample #{get_density}x#{get_density} #{shell_quote "#{preview_format}:#{output}"}"
    
    when "application/pdf"
      # Ghostscript decides on the content, not on the coder ImageMagick asks for,
      # whether it runs a file as PDF or as PostScript. Marcel reports a file as PDF
      # when %PDF- appears near its start, so check the start as Redmine's thumbnails do.
      if !pdf_magic?
        nil
      elsif Redmine::Thumbnail.gs_available?
        "#{convert_command} -density #{get_density} #{shell_quote "pdf:#{source}[0]"} #{shell_quote "#{preview_format}:#{output}"}"
      else
        copy( source, output )
      end
    end
    command( cd + join + cmd + join + move(output)) if cmd
  end #def
  
  # as Redmine::Thumbnail.valid_pdf_magic?, which Redmine 6.0 before 6.0.8 lacks
  def pdf_magic?
    magic = File.binread(source, 8).to_s
    magic.start_with?("%PDF-".b) || magic == "\xEF\xBB\xBF%PDF-".b
  end #def
  
  def convert_command
    ([shell_quote(CONVERT_BIN)] + LIMITS.map{|resource, value| "-limit #{resource} #{value}"}).join(" ")
  end #def
  
  def get_density
    DENSITIES.map{|a| a[1]}.include?(converter_settings['density'] ) ? converter_settings['density'] : "72"
  end #def
  
end #class