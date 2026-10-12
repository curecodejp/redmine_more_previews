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

require 'digest'

module RedmineMorePreviews
  module Lib
    # Conversions that failed, remembered for Converter.failure_ttl seconds: a
    # request for them fails at once instead of converting again, whether previews
    # are cached or not. A failure is kept per preview or asset, by the path its
    # result would be stored at: that path stands for the attachment (or the
    # repository, path, revision and content), the format and the asset, so a
    # failing asset does not stop the list or the other assets. An administrator's
    # reload forgets it.
    module RmpFailures
      
      # why a conversion failed: too_large is answered with 413 again, the others
      # give no preview (404)
      REASONS = %w(error empty too_large).freeze
      
      # the reason, nil unless a failure is remembered
      def self.recorded( key )
        return nil if key.nil?
        path = path( key )
        return nil unless File.file?( path )
        return nil if Time.now - File.mtime( path ) > RedmineMorePreviews::Converter.failure_ttl
        reason = File.read( path ).strip
        REASONS.include?( reason ) ? reason : nil
      rescue SystemCallError
        nil
      end #def
      
      def self.record( key, reason )
        return if key.nil?
        path = path( key )
        FileUtils.mkdir_p( File.dirname( path ) )
        tmp = "#{path}.#{Process.pid}.#{Thread.current.object_id}"
        File.write( tmp, reason )
        File.rename( tmp, path )
      rescue SystemCallError => e
        Rails.logger.warn "Failure of #{key} not remembered: #{e.message}"
      end #def
      
      def self.forget( key )
        File.delete( path( key ) ) unless key.nil?
      rescue Errno::ENOENT
      end #def
      
      def self.path( key )
        File.join( RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH, "failures", Digest::SHA256.hexdigest( key.to_s ) )
      end #def
      private_class_method :path
      
    end #module
  end #module
end #module
