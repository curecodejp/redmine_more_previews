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
    module Extraction
    
      ####################################################################################
      # shared constants among VObject classes
      ####################################################################################
      
      ####################################################################################
      # include
      ####################################################################################
      include Modules::Escaping
      
      ####################################################################################
      # constants
      ####################################################################################
      
      # ----------------------------------------------------------------------------------
      # extracts semicolon separated array from value
      #  - fields: array of symbols to describe contents of array (if fixed length array)
      #    if fields is nil, then an unlimited array is returned and provided val[0] cannot 
      #    be a Hash
      #
      def get_array(fields, *val, **att)
        length = fields.length if fields.is_a?(Array) # fields may be nil or []
        arr = case val[0]
        when Hash
          val[0].deep_transform_keys{|key| key.to_s.downcase.to_sym }.yield_self do |h|
            fields.to_a.map{|field| h[field]}
          end
        when Array
          val[0]
        else
          case val.length
          when 1
            case val[0]
              # if value is a string, then it should be escaped already
            when String
              unesc_ssv_to_arr(val[0].to_s, length)
            else
              [val.to_s]
            end
          else
            val
          end
        end
        arr.fill("", arr.length..length).slice!(length) if length # pad arr to 'length' elements
        arr
      end #def 
      
      # ----------------------------------------------------------------------------------
      # extracts comma separated list from value
      #
      def get_list(*val, **att)
        case val[0]
        when Array
          val[0]
        else
          case val.length
          when 1
            case val[0]
            when String
              # if value is a string, then it should be escaped already
              unesc_csv_to_arr(val[0].to_s)
            else
              val.to_s
            end
          else
            val
          end
        end
      end #def 
      
      # ----------------------------------------------------------------------------------
      # extracts text from value
      #  - fields: array of symbols to describe contents of array (if fixed length array)
      #    if fields is nil, then an unlimited array is returned and provided val[0] cannot 
      #    be a Hash
      #
      def get_text(*val, **att)
        unesc(val[0])
      end #def 
      
      # ----------------------------------------------------------------------------------
      # extracts uri from value
      #   currently, it tries to parse and defaults to value, so nothong is really done
      #
      def get_uri(*val, **att)
        return val[0].to_s if plain_uri_parts( val[0].to_s )
        begin
          URI.parse(val[0].to_s)
        rescue URI::InvalidURIError
          URI.parse("") # we give up
        end
      end #def
      
      def get_uri_hash(*val, **att)
        [%i(scheme userinfo host port registry path opaque query fragment full), 
          begin
            plain_uri_parts( val[0].to_s ) || (URI.split(val[0].to_s) + [get_uri(*val, **att).to_s])
          rescue URI::InvalidURIError
            # a telephone number is text in vCard 3 and may be in vCard 4 (VALUE=text),
            # f.i. "+81 3 1234 5678": it is shown as it is written, without a link.
            # Other values that are no URI (PHOTO, URL ...) are not shown
            ["", "", "", "", "", "", "", "", ""] + [name == :tel ? val[0].to_s : get_uri(*val, **att).to_s]
          end
        ].transpose.to_h
      end #def
      
      # an image as a data URI (rfc2397) or in base64 (vCard 3, ENCODING=b) is split
      # as URI.split splits it, without its parser, which takes some 50 bytes of
      # memory for a byte of the value: a photo of a few MiB took more than a
      # conversion may take. A regular expression over the data takes as much, so
      # its characters are counted
      DATA_URI_HEAD = %r{\Adata:[!#$&^.+\w-]+/[!#$&^.+\w-]+(?:;[\w.=-]+)*\z}i
      
      def plain_uri_parts( str )
        comma = str.index( "," )
        if str.start_with?( "data:", "DATA:" ) && comma && comma < 256 &&
           str[0...comma].match?( DATA_URI_HEAD ) && str[(comma + 1)..-1].count( "^A-Za-z0-9+/=%_.~-" ).zero?
          ["data", nil, nil, nil, nil, nil, str[5..-1], nil, nil, str]
        elsif base64?( str )
          [nil, nil, nil, nil, nil, str, nil, nil, nil, str]
        end
      end #def
      
      def base64?( str )
        padding = str.index( "=" )
        !str.empty? && padding != 0 && str.count( "^A-Za-z0-9+/=" ).zero? && (padding.nil? || str[padding..-1].count( "^=" ).zero?)
      end #def
      private :base64?
      private :plain_uri_parts
      
      def get_uri_array(*val, **att)
        URI.split(val[0].to_s) + [get_uri(*val, **att).to_s]
      end #def
      
      # ----------------------------------------------------------------------------------
      # extracts date from value as formatted text
      #
      def get_f_date(*val, **att)
        case att[:VALUE].to_a.first
        when /date-and-or-time/i
          case val[0]
          when Date, Time, DateTime
            val[0].utc.strftime("%Y%m%dT%H%M%SZ")
          when String
            val[0].to_date.utc.strftime("%Y%m%dT%H%M%SZ") rescue val[0]
          else
            val[0].to_s # no idea what it could be here
          end
        when /text/i
          esc(val[0].to_s)
        else
          esc(val[0].to_s)
        end
      end #def
      
      # ----------------------------------------------------------------------------------
      # extracts date from value as localized text
      #
      def get_l_date(*val, **att)
        case att[:VALUE].to_a.first
        when /date-and-or-time/i
          case val[0]
          when Date, Time, DateTime
            localize(val[0])
          when String
            localize(val[0].to_date) rescue val[0]
          else
            val[0].to_s # no idea what it could be here
          end
        when /text/i
          unesc(val[0].to_s)
        else
          unesc(val[0].to_s)
        end
      end #def
      
    end #module
  end #module
end #module
end