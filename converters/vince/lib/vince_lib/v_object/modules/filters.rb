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
  module Modules
    module Filters
    
      ####################################################################################
      # shared constants among VObject classes
      ####################################################################################
      
      ####################################################################################
      # constants
      ####################################################################################
      
      #-----------------------------------------------------------------------------------
      # filter fields with optional block providing field, value and attributes
      #
      def select(*fields, &block)
        fields = (fields.presence || self.class::FIELDS).map{|field| field.to_s.downcase.to_sym}
        self.class.new(
        fields.map do |field|
          try( field ).try( :values ).to_a.map do |args|
            if block_given?
              # the attributes are given as keywords: Ruby 3 passes a hash given as the
              # last argument to the **attributes of a block no more
              *val, att = Array.wrap(args)
              selected  = att.is_a?(Hash) ? yield( *val, **att ) : yield( *Array.wrap(args) )
              [field.to_s.upcase] + Array.wrap(args) if selected
            else
              [field.to_s.upcase] + Array.wrap(args)
            end
          end.compact
        end.flatten(1).select(&:present?))
      end #def
      alias :all :select
      
      #-----------------------------------------------------------------------------------
      # ngative filter fields with optional block providing field, value and attributes
      #
      def unselect(*blockedfields, &block)
        blockedfields = (blockedfields.presence || self.class::FIELDS).map{|field| field.to_s.downcase.to_sym}
        fields = self.class::FIELDS - blockedfields
        select(*fields, &block)
      end #def
      
      #-----------------------------------------------------------------------------------
      # select fields matching ALL attributes with optional block providing field, value 
      # and attributes
      #
      def select_by_all_attributes(*fields, **atts, &block)
        select(*fields){|*f,**a|  match_hashes(a, atts, &block)}
      end #def
      
      #-----------------------------------------------------------------------------------
      # select fields matching ANY attributes with optional block providing field, value 
      # and attributes
      #
      def select_by_any_attribute(*fields, **atts, &block)
        select(*fields){|*f,**a|  share_hashes(a, atts, &block)}
      end #def
      
      #-----------------------------------------------------------------------------------
      # unselect fields matching ALL attributes with optional block providing field, value 
      # and attributes
      #
      def unselect_by_all_attributes(*fields, **atts, &block)
        select(*fields){|*f,**a| !match_hashes(a, atts, &block)}
      end#def
      
      #-----------------------------------------------------------------------------------
      # unselect fields matching ANY attributes with optional block providing field, value 
      # and attributes
      #
      def unselect_by_any_attribute(*fields, **atts, &block)
        select(*fields){|*f,**a| !share_hashes(a, atts, &block)}
      end#def
      
      #-----------------------------------------------------------------------------------
      # matches if all values in hash1 contains all of hash2 with indifferent access
      # optionally manipulate values with block. h2 may contain Regular Expressions
      #
      def match_hashes(h1, h2, &block)
        array_minus(
          expand_hash( h2.transform_keys{|k| k.to_s.upcase } ).map{|k,v| [k, block_given? ? yield( v ) : v]},
          expand_hash( h1.transform_keys{|k| k.to_s.upcase } ).map{|k,v| [k, block_given? ? yield( v ) : v]}
        ).blank?
      end #def
      
      #-------------------------------------------------------------------------------------
      # matches if any values in hash1 correspond to hash2 with indifferent access
      # optionally manipulate values with block. h2 may contain Regular Expressions
      #
      def share_hashes(h1, h2, &block)
        array_and(
          expand_hash( h1.transform_keys{|k| k.to_s.upcase } ).map{|k,v| [k, block_given? ? yield( v ) : v]},
          expand_hash( h2.transform_keys{|k| k.to_s.upcase } ).map{|k,v| [k, block_given? ? yield( v ) : v]}
        ).present?
      end #def
      
      #-------------------------------------------------------------------------------------
      # the paths through a nested hash, each the keys down to a value and the value:
      # {"TYPE" => ["work", "pref"]} gives [["TYPE", "work"], ["TYPE", "pref"]]
      #
      def expand_hash( hash, path=[] )
        hash.flat_map do |key, value|
          case value
          when Hash  then expand_hash( value, path + [key] )
          when Array then value.map { |el| path + [key] + (el.is_a?(Array) ? el : [el]) }
          else            [path + [key, value]]
          end
        end
      end #def

      #-------------------------------------------------------------------------------------
      # compare two fields by PREF attribute for sorting fields by preference
      #
      def pref( arr1, arr2 )
        pref_rank( arr1 ) <=> pref_rank( arr2 )
      end #def
      
      #-------------------------------------------------------------------------------------
      # the preference of a field [value, attributes], 1 the most preferred:
      # rfc6350:5.3 PREF=1..100; vCard 3 TYPE=pref and vCard 2.1 PREF without a value
      # are 1; a field without one comes after those with one. The attributes are read
      # with symbol keys (see Reader#parse), in any case
      #
      def pref_rank( arr )
        att = arr.last.is_a?(Hash) ? arr.last.transform_keys{|k| k.to_s.upcase } : {}
        if att.key?('PREF')
          rank = Array(att['PREF']).compact.last.to_i
          return rank.positive? ? rank : 1
        end
        types = Array(att['TYPE']).flatten.compact.flat_map{|t| t.to_s.split(',') }
        types.any?{|t| t.strip.casecmp?('pref') } ? 1 : 101
      end #def
      
      #-------------------------------------------------------------------------------------
      # calculates array 1 - array 2. Array 1 may inlude Regexp
      #
      def array_minus(a1, a2)
        arr = a1.dup
        arr.each do |k1,v1| 
         case v1
          when Regexp
            a2.each do |k2,v2|
              arr -= [[k1,v1]] if k1 == k2 && v2.to_s =~ v1
            end
          else
            arr -= [[k1, v1]] if a2.include?([k1, v1])
          end
        end
        arr
      end #def
      
      #-------------------------------------------------------------------------------------
      # calculates array 1 & array 2. Array 2 may inlude Regexp
      #
      def array_and(a1, a2)
        arr = []
        a2.each do |k2,v2| 
         case v2
          when Regexp
            a1.each do |k1,v1|
              arr += [[k1,v1]] if k1 == k2 && v1.to_s =~ v2
            end
          else
            a1.each do |k1,v1|
              arr += [[k1,v1]] if k1 == k2 && v1 == v2
            end
          end
        end
        arr
      end #def
      
    end #module
  end #module
end #module
end