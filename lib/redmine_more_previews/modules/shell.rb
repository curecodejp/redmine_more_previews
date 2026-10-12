# encoding: utf-8
# frozen_string_literal: true
#
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

require "benchmark"

module RedmineMorePreviews
  module Modules
    module Shell
      
       ##
       # Sends commands to the shell (more precisely, it sends commands directly to
       # the operating system).
       #
       def run(command, options={})
       
         cmd = command.flatten
         
         stdout, stderr, status = execute(cmd, stdin: options[:stdin])
         
         if status != 0 
           Rails.logger.error "`#{cmd.join(" ")}` failed with error:\n#{stderr}"
         end
         
         $stderr.print(stderr) unless options[:stderr] == false
         
         [stdout, stderr, status]
       end
       
       def execute(command, options = {})
         stdout, stderr, status =
           log(command.join(" ")) do
             send("execute_#{shell_api.gsub("-", "_")}", command, options)
           end
           
         [stdout, stderr, status.exitstatus]
       rescue Errno::ENOENT, IOError
         ["", "executable not found: \"#{command.first}\"", 127]
       end
       
       private
       
       # the command runs in a process group of its own and is stopped with
       # everything it started when it times out (see Lib::RmpProcess)
       def execute_open3(command, options = {})
         in_r,  in_w  = IO.pipe
         out_r, out_w = IO.pipe
         err_r, err_w = IO.pipe
         [in_w, out_r, err_r].each(&:binmode)
         # the pipes are closed below also when the command could not be started
         stdout_reader = Thread.new { out_r.read rescue "" }
         stderr_reader = Thread.new { err_r.read rescue "" }
         
         status = RedmineMorePreviews::Lib::RmpProcess.run(command, timeout: timeout, in: in_r, out: out_w, err: err_w) do
           # the child's ends: the readers see the end of the output when it exits
           [in_r, out_w, err_w].each(&:close)
           Thread.new do
             begin
               in_w.write options[:stdin].to_s
             rescue Errno::EPIPE, IOError
             ensure
               in_w.close rescue nil
             end
           end
         end
         
         [stdout_reader.value, stderr_reader.value, status]
       rescue RedmineMorePreviews::Exceptions::ConverterTimeout
         raise RedmineMorePreviews::Exceptions::ConverterTimeout, "Converter command timed out: #{command}"
       ensure
         [in_r, in_w, out_r, out_w, err_r, err_w].each { |io| io.close unless io.nil? || io.closed? }
       end
       
       def execute_posix_spawn(command, options = {})
         require "posix-spawn"
         child = POSIX::Spawn::Child.new(*command, input: options[:stdin].to_s, timeout: timeout)
         [child.out, child.err, child.status]
       rescue POSIX::Spawn::TimeoutExceeded
         raise RedmineMorePreviews::Exceptions::ConverterTimeout, "Converter command timed out: #{command}"
       end
       
       def log(command, &block)
         value = nil
         duration = Benchmark.realtime { value = block.call }
         Rails.logger.info "[%.2fs] %s" % [duration, command]
         value
       end
       
    end #module
  end #module
end #module
