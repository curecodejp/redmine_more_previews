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
    # Runs a converter command with a time limit. The command gets a process group
    # of its own, and the whole group is stopped: the shell of a command string,
    # and whatever the converter starts in turn (convert -> gs, soffice ->
    # soffice.bin), would keep running if only the direct child was killed.
    #
    # Windows has no process groups to signal: only the direct child is stopped
    # there, not the processes it started.
    module RmpProcess
      
      # seconds a stopped command gets to exit after TERM, before KILL
      KILL_GRACE = 3
      POLL       = 0.05
      
      # command: a String (run by the shell if it needs one) or an Array (run
      # without a shell). The block, if given, is called right after the spawn,
      # f.i. to close the child's ends of pipes.
      #
      # Returns the Process::Status; raises ConverterTimeout when the time limit
      # passes. Also after a normal exit, processes left behind in the group are
      # killed.
      def self.run( command, timeout:, **options )
        pid = Process.spawn( *Array(command), **options, **group_option )
        yield pid if block_given?
        status = wait( pid, now + timeout )
        raise Exceptions::ConverterTimeout, "command timed out after #{timeout}s" unless status
        status
      ensure
        stop( pid, status ) if pid
      end #def
      
      def self.group_option
        Redmine::Platform.mswin? ? { :new_pgroup => true } : { :pgroup => true }
      end #def
      private_class_method :group_option
      
      # waits for the command until deadline; nil if it is still running then
      def self.wait( pid, deadline )
        loop do
          status = reap( pid )
          return status if status
          return nil if now >= deadline
          sleep POLL
        end
      end #def
      private_class_method :wait
      
      def self.reap( pid )
        Process.wait2( pid, Process::WNOHANG )&.last
      end #def
      private_class_method :reap
      
      # status: nil if the command is still running
      def self.stop( pid, status )
        if Redmine::Platform.mswin?
          unless status
            Process.kill( 'KILL', pid ) rescue nil
            Process.wait( pid )
          end
          return
        end
        unless status
          signal_group( pid, 'TERM' )
          deadline = now + KILL_GRACE
          until now >= deadline
            status ||= reap( pid )
            break if status && !group_alive?( pid )
            sleep POLL
          end
        end
        signal_group( pid, 'KILL' )
        Process.wait( pid ) unless status
      rescue Errno::ECHILD
      end #def
      private_class_method :stop
      
      def self.signal_group( pid, signal )
        Process.kill( signal, -pid )
      rescue Errno::ESRCH, Errno::EPERM
      end #def
      private_class_method :signal_group
      
      def self.group_alive?( pid )
        Process.kill( 0, -pid )
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end #def
      private_class_method :group_alive?
      
      def self.now
        Process.clock_gettime( Process::CLOCK_MONOTONIC )
      end #def
      
    end #module
  end #module
end #module
