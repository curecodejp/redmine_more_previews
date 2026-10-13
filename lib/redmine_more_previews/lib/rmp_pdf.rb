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
  module Lib
    module RmpPdf
      class << self
        # Returns a PDF string for a converter
        def more_prewiew_to_pdf(locals={})
          pdf = Redmine::Export::PDF::ITCPDF.new(::I18n.locale)
          pdf.set_title("Converter diagnostics")
          pdf.alias_nb_pages
          options = {}
          options[:format] = ::Setting.date_format unless ::Setting.date_format.blank?
          pdf.footer_date = ::I18n.l(User.current.today.to_date, **options)
          pdf.add_page
          
          pdf.SetFontStyle('B',11)
          buf = "Converter diagnostics"
          pdf.RDMMultiCell(190, 5, buf)
          
          pdf.SetFontStyle('',8)
          # The caller passes only public metadata. Never print arbitrary
          # conversion instance variables or source identifiers here.
          pdf.RDMMultiCell(190, 5, "Converter diagnostic fields (internal details omitted):")

          # Defense in depth: this renderer accepts only the same safe fields
          # emitted by Conversion#debug_fields, even if another caller passes
          # additional entries.
          locals.each do |key, value|
            next unless RedmineMorePreviews::Conversion::SAFE_DEBUG_FIELDS.include?(key.to_s)

            buf = "#{key}: #{value}"
            pdf.RDMMultiCell(190, 5, buf)
          end
          pdf.output
        end #def
      end #class
    end #module
  end #module
end #module
