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
  class Reader
  
    ######################################################################################
    # reads a vobject file
    ######################################################################################
    
    ######################################################################################
    # includes
    ######################################################################################
    include Constants::Defaults
    include Modules::Escaping
    include Modules::Setters
    
    ######################################################################################
    # constants
    ######################################################################################
    
    ######################################################################################
    # variables, field setters
    ######################################################################################
    FIELDS  = [
      :filepath          ,   # either filepath to be opened, or...
      :string            ,   # string to be interpreted
      :object            ,   # object name to be read, i.e. "VCARD" or "VCALENDAR"
    ]
    
    # ------------------------------------------------------------------------------------
    # define fields accessors
    #
    class << self
      def def_field(*names)
        class_eval do
          names.each do |name|
            define_method(name) do |*args|
              if args.empty?
                instance_variable_get("@#{name}")
              else
                instance_variable_set("@#{name}", *args)
              end
            end
            define_method("#{name}=") do |*args|
              instance_variable_set("@#{name}", *args)
            end
          end
        end
      end
    end
    def_field *FIELDS
    
    # ------------------------------------------------------------------------------------
    # initializes object
    #
    def initialize(*args, **options, &block)
      if block_given?
        if block.arity.zero?
          @args=args; @options=options
          instance_eval(&block)
        else
          yield self, args, options
        end
      else
        args.each do |arg|
          try(arg.first.to_s.downcase.to_sym, *(arg.from(1))) if arg.is_a?(Array)
        end
        options.each do |key, val|
          try(key.to_s.downcase.to_sym, *val)
        end
      end
    end #def
    
    # ------------------------------------------------------------------------------------
    # enumerates over vCard entries in a file
    #
    def fileeach(&block)
      return nil unless object.to_s.upcase.in?(SUPPORTEDOBJECTS.keys)
      obj   = SUPPORTEDOBJECTS[object.to_s.upcase].constantize
      offset=0; vcfs = []
      while(vcf, offset = from_file( offset ); offset)
        if block_given?
          yield obj.new(vcf) if vcf
        elsif vcf
          vcfs << obj.new(vcf)
        end
      end
      vcfs.compact unless block_given?
    end #def
    alias :fileall :fileeach
    
    # ------------------------------------------------------------------------------------
    # enumerates over vCard entries in memory
    #
    def stringeach(&block)
      return nil unless object.to_s.upcase.in?(SUPPORTEDOBJECTS.keys)
      obj = SUPPORTEDOBJECTS[object.to_s.upcase].constantize
      offset=0; vcfs = []
      while(vcf, offset = from_str( string, offset ); offset)
        if block_given?
          yield obj.new(vcf) if vcf
        elsif vcf
          vcfs << obj.new(vcf)
        end
      end
      vcfs.compact unless block_given?
    end #def
    alias :stringall :stringeach
    
    private
    
    # ------------------------------------------------------------------------------------
    # read one vcf set from vCard file
    #
    # returns current position in file
    #
    def from_file( offset=0 )
      return nil unless object.to_s.upcase.in?(SUPPORTEDOBJECTS.keys)
      bvc     = /\ABEGIN:#{object.to_s.upcase}/in # i case insensitive, n us-ascii encoding
      evc     = /\AEND:#{object.to_s.upcase}/in   # i case insensitive, n us-ascii encoding
      # read binary to keep compatibility between platforms
      File.open(filepath, "rb") { |f| read_object( f, offset, bvc, evc ) }
    end #def

    # ------------------------------------------------------------------------------------
    # read one vcf set from vCard string
    #
    # returns current position in String
    #
    def from_str( str, offset=0, **options )
      return nil unless object.to_s.upcase.in?(SUPPORTEDOBJECTS.keys)
      charset = options[:charset] || "UTF-8"
      bvc     = Regexp.new /\ABEGIN:#{object.to_s.upcase}/i.to_s.encode(charset)
      evc     = Regexp.new /\AEND:#{object.to_s.upcase}/i.to_s.encode(charset)
      StringIO.open(str) { |f| read_object( f, offset, bvc, evc ) }
    end #def

    # ------------------------------------------------------------------------------------
    # reads the lines of one object from offset: [array of [name, value, attributes],
    # position after its END], [nil, nil] at the end
    #
    # rfc6350:3.2 a line is folded by a line break followed by a single space or tab,
    # which are removed to unfold it, anywhere in the line (also within a parameter).
    # The lines are unfolded before they are split, and read whole: the size of a
    # vCard is bounded by its converter (see Vince::MAX_SIZE)
    #
    def read_object( io, offset, bvc, evc )
      begun   = false
      pos     = nil
      arr     = []
      logical = nil
      io.pos  = offset
      io.each_line( :chomp => true ) do |line|
        pos = io.tell
        if logical && line.start_with?( " ", "\t" )
          logical << line[1..-1]
          next
        end
        add_line( arr, logical )
        logical = nil
        case line;when bvc;begun = true; next; when evc;break;end;next unless begun
        logical = line.dup unless line.empty?
      end
      # an object without its END
      add_line( arr, logical )
      [arr.presence, pos]
    end #def

    def add_line( arr, line )
      return if line.nil?
      arr << parse( utf8( line ) )
    end #def

    # ------------------------------------------------------------------------------------
    # splits line into name, value and attributes. values remain unescaped
    #
    # rfc6350:3.3 contentline = [group "."] name *(";" param) ":" value
    #   - the group (f.i. "item1." of Apple's contacts) is dropped
    #   - a quoted parameter value may hold ":", ";" and ",": the line is split at a
    #     ":" or ";" outside quotes, and the quotes are removed; each value of a list
    #     may be quoted by itself (TYPE="work","pref")
    #   - a parameter without "=" is a type (vCard 2.1, f.i. "TEL;HOME;PREF"), and an
    #     empty one is left out
    #   - the names of parameters are case-insensitive: they are upcased
    #
    def parse( line )
      bytes       = line.b
      colon       = unquoted_index( bytes, ":" ) || bytes.index( ":" ) # an unbalanced quote
      str, value  = colon ? [line.byteslice( 0, colon ), line.byteslice( (colon + 1)..-1 )] : [line, nil]
      name, *atts = split_unquoted( str, ";" )
      name        = name.to_s.sub( /\A[A-Za-z0-9-]+\./, "" )
      attributes  = atts.reject( &:empty? ).map do |a|
        key, val = a.include?( "=" ) ? a.split( "=", 2 ) : ["TYPE", a]
        [key.upcase, val && split_unquoted( val, "," ).map { |v| unquote( v ) }.join( "," )]
      end.group_by( &:first ).transform_values { |pairs| pairs.map( &:last ) }
      [name, value, attributes.symbolize_keys] # symbolize necessary to work with splat operator
    end #def

    # the index of the first char outside double quotes in bytes (a binary string) from
    # index from, nil if there is none. Linear: a line may be as long as the vCard, and
    # the index of a character in a string of UTF-8 is counted from its start
    SEPARATORS = { ":" => /[":]/, ";" => /[";]/, "," => /[",]/ }.freeze

    def unquoted_index( bytes, char, from=0 )
      quoted = false
      i      = from
      while (j = bytes.index( quoted ? '"' : SEPARATORS.fetch( char ), i ))
        return j if !quoted && bytes.getbyte( j ) == char.ord
        quoted = !quoted
        i      = j + 1
      end
      nil
    end #def

    def split_unquoted( str, char )
      bytes = str.b
      parts = []
      i     = 0
      while (j = unquoted_index( bytes, char, i ))
        parts << str.byteslice( i, j - i )
        i = j + 1
      end
      parts << str.byteslice( i..-1 )
    end #def

    def unquote( val )
      val && val.length >= 2 && val.start_with?( '"' ) && val.end_with?( '"' ) ? val[1..-2] : val
    end #def

  end #class
end #module
end