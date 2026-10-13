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

require 'fileutils'

module RedmineMorePreviews
  module Lib
    module RmpFile
      class << self
        
        # ------------------------------------------------------------------------------ #
        #
        def create_filename( filename, mime_type, options={} )
          extension = File.extname(filename.to_s)
          basename  = File.basename(filename.to_s, extension)
          extension = Rack::Mime::MIME_TYPES.invert[mime_type.to_s].presence.to_s if extension.blank?
          basename  = mime_type.to_s =~ /image/ ? "image" : "file" if basename.blank?
          sanitize( "#{basename}#{extension}", options)
        end #def
        
        #---------------------------------------------------------------------------------
        # sanitize
        #
        # sanitize(filename, , options = {})
        # returns sanitized filename(string)
        #  
        #  options:
        # :ignore_delimiters => true
        #         true:
        #         will accept names with directory delimiters 
        #         and will replace delimiters with "_"
        #         else
        #         will chop off directory names
        #        
        #---------------------------------------------------------------------------------
        def sanitize( filename, options = {} )
          # Bad as defined by wikipedia: https://en.wikipedia.org/wiki/Filename#Reserved_characters_and_words
          # Also have to escape the backslash, ampersand, ", ', and ;
          _bad_chars = /\/|\\|\?|%|\*|:|\|\"|\'|\<|\>| |;|&/
          _filename  = RmpText.to_utf8(filename.to_s.dup) # in case filename is nil
          _filename  = _filename.gsub(_bad_chars, '_') if options[:ignore_delimiters]
          _filename  = File.basename( _filename ) 
          _filename  = _filename.presence || "noname"
          _extension = File.extname(  _filename)
          _filestem  = File.basename( _filename, _extension)
          # limit maximum length of filename to 260 characters
          _extension = _extension[0..255]      # limit extension length
          _fslength  = 260 - _extension.length # limit basename accordingly
          _filename  = "#{_filestem[0.._fslength]}#{_extension}"
          _filename.gsub(_bad_chars, '_')
        end #def
        
        # ------------------------------------------------------------------------------ #
        # safe_relative_path( path(string) )
        # returns a normalized relative path ("dir/file.txt") that cannot leave the
        # directory it is joined to, or nil if the path is empty, absolute, contains
        # a NUL byte or a ".." segment. Used for asset names coming from request
        # parameters and from archive entries.
        #
        def safe_relative_path( path )
          _path = RmpText.to_utf8(path.to_s.dup)
          return nil if _path.include?("\0")
          return nil if _path.start_with?("/", "\\")     # absolute or UNC path
          return nil if _path =~ /\A[A-Za-z]:/            # windows drive letter
          segments = _path.split(%r{[\\/]+}).reject{|seg| seg.empty? || seg == "." }
          return nil if segments.empty?
          # NTFS strips trailing dots and spaces of a component, so ".. " or "..."
          # would resolve to ".." on a Windows host: judge each segment without them
          return nil if segments.any?{|seg| ["", ".", ".."].include?(seg.sub(/[. ]+\z/, "")) }
          segments.join("/")
        end #def
        
        # ------------------------------------------------------------------------------ #
        # within_directory?( base(string), path(string) )
        # returns true if path (after resolving ".." and symlinks of existing parts)
        # lies strictly below base. Non-existing parts of path are resolved lexically.
        #
        def within_directory?( base, path )
          return false unless File.directory?(base)
          _base = File.realpath(base)
          _path = realpath_lexical(path)
          _path.start_with?(_base + File::SEPARATOR)
        end #def
        
        # resolves symlinks of the existing part of path, appends the rest lexically
        def realpath_lexical( path )
          existing, rest = File.expand_path(path), []
          until File.exist?(existing) || existing == File.dirname(existing)
            rest.unshift(File.basename(existing))
            existing = File.dirname(existing)
          end
          File.join(File.realpath(existing), *rest)
        end #def
        private :realpath_lexical
        
        # ------------------------------------------------------------------------------ #
        # unique_filename( filenames(array or set), filename(string) )
        # returns filename, which is unique to filenames,
        # whereby extensions are kept: name.txt, name.2.txt, name.3.txt, ...
        #
        # counters (a Hash kept by the caller across calls) remembers the next index
        # of each series of names, so that n equal names do not try 2, 3, ... anew
        # each time; pass a Set as filenames for the same reason. A loop, not a
        # recursion: many equal names overflowed the stack.
        #
        def unique_filename( filenames, filename, index=2, counters: nil )
          return filename unless filenames.include?( filename )
          series = unique_filename_series( filename )
          index  = [index, counters[series].to_i].max if counters
          index += 1 while filenames.include?( "#{series[0]}.#{index}#{series[1]}" )
          counters[series] = index + 1 if counters
          "#{series[0]}.#{index}#{series[1]}"
        end #def
        
        # the basename and extension a numbered name is made of: an index already
        # in the name (text.2.txt, name.2) is replaced, not appended to
        def unique_filename_series( filename )
          extname = File.extname( filename )
          if extname =~ /\A\.\d+\z/            # the extension is an index: name.2
            [File.basename( filename, extname ), ""]
          elsif extname.blank?                   # no extension
            [filename, ""]
          else                                   # text.txt, or text.2.txt
            tmpname = File.basename( filename, extname )
            indname = File.extname( tmpname )
            [indname =~ /\A\.\d+\z/ ? File.basename( tmpname, indname ) : tmpname, extname]
          end
        end #def
        private :unique_filename_series
        
        # ------------------------------------------------------------------------------ #
        # make_filenames_unique( filenames(array) )
        # returns array of filenames, with each name unique
        # whereby extensions are kept
        #
        def make_filenames_unique( filenames )
        
           new_filenames = []
           # all but the first name must be unique_filename
           filenames.each do |filename|
             new_filenames << unique_filename( new_filenames, filename )
           end #each
           new_filenames
        end#def
        
        # ------------------------------------------------------------------------------ #
        # sanitize_subdir(subdir, dir)
        # returns sanitized subdir(string), which does not expand higher than dir(string)
        #        
        def sanitize_subdir( subdir, dir )
          subpath  = Pathname.new( subdir )
          path     = Pathname.new( dir )
          expanded = subpath.expand_path( path )
          relative = expanded.relative_path_from( path )
          #puts relative.to_path
          subdir unless !!(relative.to_path =~ /\A\.\./)
        end #def
        
        #-----------------------------------------------------------------------------------
        # get directory, if it does not exist, create directory
        #-----------------------------------------------------------------------------------
        def directory( subdir, dir=nil )
          subdir = sanitize_subdir(subdir, dir) if dir
          FileUtils.mkdir_p subdir if subdir && !File.exist?(subdir)
          subdir
        end #def
        
        #-----------------------------------------------------------------------------------
        # get directory, if it does not exist, create directory
        #-----------------------------------------------------------------------------------
        def file_directory( filepath, dir=nil )
          filedir = File.dirname( filepath )
          directory( filedir, dir=nil )
        end #def
        
      end #class
    end #module
  end #module
end #module
