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

require 'find'

module RedmineMorePreviews
  module Lib
    # The size of the preview cache, against Converter.max_cache. Adding up the
    # whole cache for every conversion would cost more than the conversion, so the
    # total is kept in a file and added up again at most every INTERVAL seconds,
    # by one process at a time (a lock file of its own); the others use the last
    # total meanwhile. The total is written to a new file and renamed over the
    # old one, so it is never read half written. The cache can outgrow the limit
    # by what is stored within one interval.
    module RmpCacheSize
      
      INTERVAL = 600
      
      def self.full?
        size >= RedmineMorePreviews::Converter.max_cache
      end #def
      
      # bytes, as last added up
      def self.size
        FileUtils.mkdir_p( storage )
        refresh if stale?
        File.read( total_path ).to_i
      rescue Errno::ENOENT
        0
      end #def
      
      def self.stale?
        !File.exist?( total_path ) || Time.now - File.mtime( total_path ) > INTERVAL
      end #def
      private_class_method :stale?
      
      def self.refresh
        File.open( File.join( storage, "cache_size.lock" ), File::RDWR | File::CREAT, 0644 ) do |lock|
          # another process is adding up: its total will do
          return unless lock.flock( File::LOCK_EX | File::LOCK_NB )
          begin
            return unless stale?
            tmp = "#{total_path}.#{Process.pid}"
            File.write( tmp, add_up.to_s )
            File.rename( tmp, total_path )
          ensure
            # see Conversion#with_cache_lock
            lock.flock( File::LOCK_UN )
          end
        end
      end #def
      private_class_method :refresh
      
      # bytes of the regular files below the storage path, the small lock, marker
      # and total files included
      def self.add_up
        total = 0
        Find.find( storage ) do |path|
          stat = File.lstat( path ) rescue next
          total += stat.size if stat.file?
        end
        total
      end #def
      
      def self.total_path
        File.join( storage, "cache_size" )
      end #def
      private_class_method :total_path
      
      def self.storage
        RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
      end #def
      private_class_method :storage
      
    end #module
  end #module
end #module
