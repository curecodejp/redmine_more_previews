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

