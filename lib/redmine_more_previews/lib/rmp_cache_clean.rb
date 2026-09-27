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
    # Removes the previews cached more than a number of days ago, by the marker
    # each stored preview has (<dir>.converter, written when it is stored; using
    # a preview does not renew it). A preview is removed under its cache lock,
    # and skipped while a request holds the lock: it is removed on the next run.
    # The lock files stay, as a request may be waiting on one. Failures
    # remembered longer than Converter.failure_ttl are removed as well.
    module RmpCacheClean
      
      # the number of previews removed
      def self.run( days )
        cutoff  = Time.now - days * 24 * 60 * 60
        removed = 0
        Dir.glob( File.join( storage, "**", "*.converter" ) ).each do |marker|
          next unless old?( marker, cutoff )
          dir = marker.delete_suffix( ".converter" )
          next unless RmpFile.within_directory?( storage, dir )
          File.open( "#{dir}.lock", File::RDWR | File::CREAT, 0644 ) do |lock|
            next unless lock.flock( File::LOCK_EX | File::LOCK_NB )
            # the preview may have been converted again meanwhile
            next unless old?( marker, cutoff )
            FileUtils.rm_rf( dir )
            FileUtils.rm_f( marker )
            removed += 1
          end
        end
        remove_failures
        removed
      end #def
      
      def self.old?( marker, cutoff )
        stat = File.lstat( marker )
        stat.file? && stat.mtime <= cutoff
      rescue Errno::ENOENT
        false
      end #def
      private_class_method :old?
      
      def self.remove_failures
        cutoff = Time.now - RedmineMorePreviews::Converter.failure_ttl
        Dir.glob( File.join( storage, "failures", "*" ) ).each do |path|
          File.delete( path ) if File.file?( path ) && File.mtime( path ) <= cutoff
        rescue Errno::ENOENT
        end
      end #def
      private_class_method :remove_failures
      
      def self.storage
        RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
      end #def
      private_class_method :storage
      
    end #module
  end #module
end #module
