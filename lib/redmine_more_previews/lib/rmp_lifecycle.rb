# encoding: utf-8
# frozen_string_literal: true

# Redmine plugin to preview various file types in redmine's preview pane
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
    # The previews of a record (an attachment, a repository) are kept in
    # <root>/<id>, and go with the record. A conversion may outlive the request
    # that deleted it, and would write its preview after the previews were
    # removed. So:
    #
    # - a conversion holds a shared lock on <root>/<id>.lifecycle.lock, outside
    #   the previews, and looks the record up once it holds it: conversions of
    #   the same record run side by side, and none starts after a deletion;
    # - a committed deletion writes <root>/<id>.cleanup_pending and removes the
    #   previews under the exclusive lock, without waiting for it: while a
    #   conversion holds the lock, the last conversion to end removes them, or
    #   the cache cleanup task does (the marker survives a restart).
    #
    # The lock file is removed with the previews. A conversion still waiting on
    # it holds a removed file then, and finds the record gone.
    module RmpLifecycle

      LOCK   = ".lifecycle.lock"
      MARKER = ".cleanup_pending"

      # yields under the shared lock, if the record exists; nil if it does not.
      # Raises ConverterLockTimeOut after the lock timeout of the converters
      def self.hold( model, root, id )
        dir = File.join( root, id.to_s )
        FileUtils.mkdir_p( root )
        File.open( "#{dir}#{LOCK}", File::RDWR | File::CREAT, 0644 ) do |lock|
          deadline = RmpProcess.now + RedmineMorePreviews::Converter.lock_timeout
          until lock.flock( File::LOCK_SH | File::LOCK_NB )
            if RmpProcess.now >= deadline
              raise RedmineMorePreviews::Exceptions::ConverterLockTimeOut, "#{label( model )} #{id} is busy"
            end
            sleep 0.05
          end
          begin
            # looked up after the lock is held, not before: a deletion committed
            # while this request waited is seen. Unlike a persistent tombstone,
            # a database restored with this id is converted again
            return nil unless model.uncached { model.unscoped.exists?( id ) }
            yield
          ensure
            lock.flock( File::LOCK_UN )
          end
        end
      ensure
        cleanup( model, root, id ) if dir && File.file?( "#{dir}#{MARKER}" )
      end #def

      # after a committed deletion of the record
      def self.remove( model, root, id )
        dir = File.join( root, id.to_s )
        # nothing was converted for the record. A conversion creates the lock
        # file before it looks the record up, so one that starts now finds the
        # record gone. Previews of an earlier version have no lock file
        return unless File.exist?( "#{dir}#{LOCK}" ) || File.symlink?( dir ) || File.exist?( dir )
        FileUtils.mkdir_p( root )
        # the intent is written before the lock is tried, as a conversion
        # holding it removes the previews when it ends
        File.write( File.join( root, "#{id}#{MARKER}" ), "pending\n" )
        cleanup( model, root, id )
      rescue StandardError => e
        Rails.logger.error "#{model.name} preview cache cleanup failed: #{e.class}: #{e.message}"
      end #def

      # removes the previews of a deleted record whose cleanup is pending, unless
      # a conversion holds the lock. true if done (or the record exists again)
      def self.cleanup( model, root, id )
        return false unless id.to_s.match?( /\A[0-9]+\z/ )
        dir     = File.join( root, id.to_s )
        pending = "#{dir}#{MARKER}"
        return false unless File.file?( pending )

        File.open( "#{dir}#{LOCK}", File::RDWR | File::CREAT, 0644 ) do |lock|
          return false unless lock.flock( File::LOCK_EX | File::LOCK_NB )
          begin
            if model.uncached { model.unscoped.exists?( id ) }
              # a restored database reused this id: remove only the stale
              # request, never the previews of the record that has it now
              File.delete( pending ) if File.file?( pending )
              return true
            end

            if File.symlink?( dir )
              File.unlink( dir ) # the link, not what it points to
            elsif File.directory?( dir )
              unless RmpFile.within_directory?( root, dir )
                raise ArgumentError, "#{label( model )} cache path is outside storage"
              end
              # raises if it cannot remove all: the marker stays, to retry
              FileUtils.remove_entry_secure( dir )
            end
            File.delete( pending ) if File.file?( pending )
            File.delete( "#{dir}#{LOCK}" ) if File.file?( "#{dir}#{LOCK}" )
            true
          ensure
            lock.flock( File::LOCK_UN )
          end
        end
      rescue StandardError => e
        Rails.logger.error "#{model.name} preview cache cleanup failed: #{e.class}: #{e.message}"
        false
      end #def

      # the cleanups left pending in root (see RmpCacheClean)
      def self.cleanup_pending( model, root )
        Dir.glob( File.join( root, "*#{MARKER}" ) ).each do |marker|
          cleanup( model, root, File.basename( marker ).delete_suffix( MARKER ) )
        end
      end #def

      def self.label( model )
        model.name.underscore.humanize.downcase + " preview"
      end #def
      private_class_method :label

    end #module
  end #module
end #module
