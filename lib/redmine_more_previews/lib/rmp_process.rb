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
      
      # signals whose handlers a forked child must not keep: a server's handler
      # would start shutting the server down in the child
      CHILD_SIGNALS = %w(TERM INT HUP QUIT USR1 USR2).freeze

      # Runs the block in a forked child with a time limit and, where the memory of
      # a process can be read (Linux), a memory limit of that many bytes beyond
      # what the child starts with. For work in Ruby, f.i. parsing an email, whose
      # time and memory nothing else bounds: the child is stopped as a command is,
      # and it runs out of memory, not the server. The block's results must be
      # files. The child leaves with exit!, running no at_exit hooks and no ensure
      # of the caller (a test runner, a database connection, a tmp directory).
      #
      # The memory is watched from here, on the child's private memory: a limit
      # of the address space alone lets the child reuse the free memory it
      # inherits, whose pages the resident memory counts from the start as
      # shared with the parent, and a thread in the child does not run while the
      # child is in a regular expression. The address space is limited as well,
      # to twice the memory, for growth between two looks.
      #
      # Returns whether the block ran to its end (false when it raised, or the
      # child was killed or stopped for its memory); raises ConverterTimeout when
      # the time limit passes. Without fork (Windows) the block runs in this
      # process, with neither limit.
      def self.fork( timeout:, memory: nil )
        unless Process.respond_to?( :fork )
          yield
          return true
        end
        pid = Process.fork do
          begin
            CHILD_SIGNALS.each {|signal| Signal.trap( signal, "DEFAULT" ) rescue nil }
            Process.setpgid( 0, 0 )
            limit_address_space( 2 * memory ) if memory
            yield
            exit!( 0 )
          rescue Exception
            exit!( 1 )
          end
        end
        # also here: the group must exist before stop signals it
        Process.setpgid( pid, pid ) rescue nil
        status = watch( pid, now + timeout, memory )
        raise Exceptions::ConverterTimeout, "child timed out after #{timeout}s" if status.nil?
        status != :memory && status.success?
      ensure
        stop( pid, status.is_a?( Process::Status ) ? status : nil ) if pid
      end #def
      
      # waits for the child until deadline: its status, :memory once its private
      # memory grew by more than memory bytes, or nil if it is still running
      def self.watch( pid, deadline, memory )
        base = private_memory( pid ) if memory
        loop do
          status = reap( pid )
          return status if status
          return nil if now >= deadline
          return :memory if base && ( private_memory( pid ) || base ) - base > memory
          sleep POLL
        end
      end #def
      private_class_method :watch
      
      # bytes of the pages only the process has, those it allocated and those it
      # copied from the parent on writing them (Linux 4.14); the resident memory
      # where that is not available; nil if neither can be read
      def self.private_memory( pid )
        rollup = File.read( "/proc/#{pid}/smaps_rollup" ) rescue nil
        kb = if rollup
          rollup.scan( /^Private_(?:Clean|Dirty):\s+(\d+)\s+kB/ ).sum {|(value)| value.to_i }
        else
          File.read( "/proc/#{pid}/status" )[/^VmRSS:\s+(\d+)\s+kB/, 1]&.to_i
        end
        kb && kb * 1024
      rescue SystemCallError
        nil
      end #def
      private_class_method :private_memory
      
      def self.limit_address_space( bytes )
        size = File.read( "/proc/self/status" )[/^VmSize:\s+(\d+)\s+kB/, 1]
        return unless size
        limit = size.to_i * 1024 + bytes
        Process.setrlimit( Process::RLIMIT_AS, limit, limit )
      rescue SystemCallError, NotImplementedError
      end #def
      private_class_method :limit_address_space
      
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
