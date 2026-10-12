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
    # The names of the assets a stored preview offers, for a converter that
    # extracts an asset only when it is asked for (Zippy): a request for a name
    # the list has not is answered without walking the archive again. The list
    # is stored next to the preview's directory (<dir>.assets, beside its marker
    # <dir>.converter), outside of it, where no asset can take its name. It holds
    # the state of the list, then one SHA256 of a name per line: names may be
    # long, and are only looked up.
    module RmpAssetList

      COMPLETE  = "complete"
      TRUNCATED = "truncated"

      def self.path( dir )
        "#{dir}.assets"
      end #def

      # names: the names an asset may be asked for by; complete: false if the
      # walk stopped at a limit, so that other names may lie beyond
      def self.write( dir, names, complete )
        path = path( dir )
        tmp  = "#{path}.#{Process.pid}.#{Thread.current.object_id}"
        File.open( tmp, "wb" ) do |f|
          f.puts( complete ? COMPLETE : TRUNCATED )
          names.each {|name| f.puts( digest( name ) ) }
        end
        File.rename( tmp, path )
      rescue SystemCallError => e
        FileUtils.rm_f( tmp ) if tmp
        Rails.logger.warn "Assets of #{dir} not listed: #{e.message}"
      end #def

      # true if the list has name, false if it has not, :beyond if a list that
      # stopped at a limit has not, nil if there is no list
      def self.lookup( dir, name )
        wanted = digest( name )
        File.open( path( dir ), "rb" ) do |f|
          state = f.gets.to_s.chomp
          return nil unless [COMPLETE, TRUNCATED].include?( state )
          f.each_line {|line| return true if line.chomp == wanted }
          state == COMPLETE ? false : :beyond
        end
      rescue SystemCallError
        nil
      end #def

      def self.remove( dir )
        FileUtils.rm_f( path( dir ) )
      end #def

      def self.digest( name )
        Digest::SHA256.hexdigest( name.to_s.b )
      end #def
      private_class_method :digest

    end #module
  end #module
end #module
