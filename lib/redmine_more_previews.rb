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

require 'open3'

module RedmineMorePreviews
  
  # Whether a file starts as a PDF: Ghostscript runs a file as PostScript unless
  # it does, whatever coder ImageMagick asks for, while Marcel already reports
  # application/pdf when %PDF- appears near the start. Every converter that hands
  # a PDF to Ghostscript (also through Redmine::Thumbnail) checks this first:
  # Redmine's own Redmine::Thumbnail.valid_pdf_magic? is missing in 6.0.0 - 6.0.7
  # and 6.1.0, and could be bypassed before 6.0.10 / 6.1.3.
  def self.valid_pdf_magic?(path)
    magic = File.binread(path, 8).to_s
    magic.start_with?("%PDF-".b) || magic == "\xEF\xBB\xBF%PDF-".b
  rescue SystemCallError
    false
  end #def
  
  CONVERT_BIN = (Redmine::Configuration['imagemagick_convert_command'] || 'convert').freeze
  
  # bounds of ImageMagick's pixel cache. width, height and disk are hard limits (the
  # conversion fails): -resample enlarges an image by its own resolution, which the
  # file sets. They do not bound Ghostscript's rendering of a PDF page, which only
  # the time limit of the conversion stops (see Conversion#command).
  IMAGEMAGICK_LIMITS = [["width", "16KP"], ["height", "16KP"], ["area", "128MP"],
                        ["memory", "256MiB"], ["map", "512MiB"], ["disk", "1GiB"]].freeze
  
  # the ImageMagick program the previews run: Redmine's imagemagick_convert_command,
  # "convert" (ImageMagick 6) unless it is set, f.i. to "magick" (ImageMagick 7)
  def self.convert_bin
    CONVERT_BIN
  end #def

  # ImageMagick's convert with the limits above, for Maggie and Peek
  def self.convert_command
    ([Redmine::Utils::Shell.shell_quote(convert_bin)] + IMAGEMAGICK_LIMITS.map{|resource, value| "-limit #{resource} #{value}"}).join(" ")
  end #def

  # Whether a file starts as a HEIC image: an ISO BMFF "ftyp" box whose major brand
  # is a HEVC brand, or "mif1" / "msf1" with a HEVC brand among the compatible ones.
  # Marcel reports image/heic for a file named so whatever it holds, and libheif
  # decodes whatever codec an image item names, not only HEVC: a file that names
  # an AVIF brand anywhere is not handed to the HEIC coder. A file that hides an
  # AV1 (or other) item behind HEVC brands is decoded if libheif has a decoder for it.
  HEVC_BRANDS = %w(heic heix hevc hevx heim heis hevm hevs).freeze
  AVIF_BRANDS = %w(avif avis).freeze

  def self.valid_heif_magic?(path)
    head = File.binread(path, 256).to_s
    return false unless head.bytesize >= 16 && head[4, 4] == "ftyp".b
    size   = head[0, 4].unpack1("N")
    # the whole box is read, or its brands cannot all be checked
    return false unless size >= 16 && size % 4 == 0 && size <= head.bytesize
    major  = head[8, 4]
    brands = head[16...size].to_s.scan(/.{4}/m)
    return false if ([major] + brands).any?{|brand| AVIF_BRANDS.include?(brand) }
    HEVC_BRANDS.include?(major) || (%w(mif1 msf1).include?(major) && brands.any?{|brand| HEVC_BRANDS.include?(brand) })
  rescue SystemCallError
    false
  end #def

  # Whether a file starts as a TIFF image (little or big endian, classic or BigTIFF)
  TIFF_MAGICS = ["II*\0", "MM\0*", "II+\0", "MM\0+"].map(&:b).freeze

  def self.valid_tiff_magic?(path)
    TIFF_MAGICS.include?(File.binread(path, 4).to_s)
  rescue SystemCallError
    false
  end #def

  # Whether the ImageMagick program has a coder that reads the format (f.i. "HEIC"):
  # the format column of "-list format" (ImageMagick 6 and 7 alike), mode "r".
  # The module column may be empty (f.i. HEIC of ImageMagick 6.9.12 on Ubuntu
  # 24.04: "HEIC            r--"). Asked once per program and process, as
  # Redmine::Thumbnail.convert_available?. It tells whether the coder is
  # installed: a policy.xml that denies the coder still fails the conversion.
  def self.imagemagick_reads?(coder)
    imagemagick_formats.match?(/^\s*#{Regexp.escape(coder)}\*?\s+(?:[A-Z0-9]\S*\s+)?r[w-][+-](?:\s|$)/)
  end #def

  # cached once it succeeds: a failure (a fork error, a program being upgraded)
  # is asked again, rather than keeping HEIC and TIFF off until Redmine restarts
  # once per program also when the first requests come together
  IMAGEMAGICK_FORMATS_LOCK = Mutex.new

  def self.imagemagick_formats
    bin = convert_bin
    IMAGEMAGICK_FORMATS_LOCK.synchronize do
      @imagemagick_formats ||= {}
      return @imagemagick_formats[bin] if @imagemagick_formats.key?(bin)
      out = imagemagick_list_formats
      out ? (@imagemagick_formats[bin] = out) : ""
    end
  end #def
  
  # "-list format" of the program, nil when it fails or runs longer than
  # imagemagick_list_timeout seconds: it is asked within a request
  def self.imagemagick_list_formats
    # Windows has no process groups to signal (see Lib::RmpProcess)
    windows = Redmine::Platform.mswin?
    group = windows ? {:new_pgroup => true} : {:pgroup => true}
    Open3.popen2e(convert_bin, "-list", "format", **group) do |stdin, out, wait|
      stdin.close
      reader = Thread.new { out.read }
      unless wait.join(imagemagick_list_timeout)
        begin; Process.kill("KILL", windows ? wait.pid : -wait.pid); rescue SystemCallError; end
        wait.join
        return nil
      end
      wait.value.success? ? reader.value : nil
    end
  rescue SystemCallError, IOError
    nil
  end #def
  
  def self.imagemagick_list_timeout
    10
  end #def
  
  def self.reset_imagemagick_formats
    IMAGEMAGICK_FORMATS_LOCK.synchronize { @imagemagick_formats = nil }
  end #def

end

require_relative "redmine_more_previews/constants"
require_relative "redmine_more_previews/exceptions"
require_relative "redmine_more_previews/modules"
require_relative "redmine_more_previews/hooks"
require_relative "redmine_more_previews/lib"

require_relative "redmine_more_previews/controller_helper"
require_relative "redmine_more_previews/converter"
require_relative "redmine_more_previews/conversion"
require_relative "redmine_more_previews/plugin_loader"

require_relative "redmine_more_previews/patches"

