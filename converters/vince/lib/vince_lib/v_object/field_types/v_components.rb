# encoding: utf-8
#
# RedmineMorePreviews vcf (electronic business cards) previewer
#
# Copyright © 2021 Stephan Wenzel <stephan.wenzel@drwpatent.de>
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
module VinceLib

module VObject
  module FieldTypes
    class VComponents < VList
    
      # a list of components separated by ";", f.i. ORG (organization;unit;unit):
      # rfc6350:6.6.4 ORG-value = component *(";" component). The lists of VList
      # (CATEGORIES, NICKNAME) are separated by ","
      #
      def get_list(*val, **att)
        if val.length == 1 && val[0].is_a?(String)
          # if value is a string, then it should be escaped already
          unesc_ssv_to_arr(val[0])
        else
          super
        end
      end #def
      
    end #class
  end #module
end #module
end
