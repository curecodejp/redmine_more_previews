# encoding: utf-8
#
# RedmineMorePreviews converter to text files
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

class Peek < RedmineMorePreviews::Conversion
  
  # as Redmine's thumbnails of a PDF, with a fixed output name (see Maggie::OUTPUT)
  SIZE   = 800
  OUTPUT = "out"
  
  def convert
    case preview_format
    when 'pdf'
      FileUtils.cp( source, tmptarget )
    when 'jpg', 'png', 'gif'
      # not Redmine::Thumbnail.generate: it does not check the start of the PDF on
      # every supported Redmine (see RedmineMorePreviews.valid_pdf_magic?), and its
      # timeout kills the shell only, leaving convert and Ghostscript running
      return unless RedmineMorePreviews.valid_pdf_magic?(source) && Redmine::Thumbnail.gs_available?
      output = thisdir("#{OUTPUT}.#{preview_format}")
      cmd    = "#{RedmineMorePreviews.convert_command} #{shell_quote "pdf:#{source}[0]"} -thumbnail #{shell_quote "#{SIZE}x#{SIZE}>"} #{shell_quote "#{preview_format}:#{output}"}"
      command( cd + join + cmd + join + move(output) )
    end
  end #def
  
end #class
