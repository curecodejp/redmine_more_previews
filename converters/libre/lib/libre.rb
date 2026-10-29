# encoding: utf-8
#
# RedmineMorePreviews converter to preview office files with LibreOffice
#
# Copyright © 2020 Stephan Wenzel <stephan.wenzel@drwpatent.de>
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

require 'open3'
require 'timeout'

class Libre < RedmineMorePreviews::Conversion
  LIBRE_OFFICE_BIN = '/usr/bin/soffice'.freeze
  BWRAP_BIN = '/usr/bin/bwrap'.freeze
  ENV_BIN = '/usr/bin/env'.freeze
  ALLOWED_OUTPUT_FORMATS = %w(html txt pdf png jpg).freeze

  # A missing or unusable sandbox must never fall back to host soffice.
  # This profile supports system-packaged /usr/bin/soffice on Linux.
  def status
    [:text_libre_office_available, sandbox_available?]
  end

  def convert
    raise ConverterShellError, 'LibreOffice sandbox unavailable' unless sandbox_available?

    Dir.mktmpdir do |tdir|
      user_installation = File.join(tdir, 'user_installation')
      command(cd + join + soffice(source, user_installation))
      # Everything in /output is untrusted even after the converter exits.
      # In particular, never follow an output symlink in fix_image_path or
      # copy it into the shared preview cache.
      validate_libre_output!
      fix_image_path
      validate_libre_output!
      generated = File.join(tmpdir, outfile)
      raise ConverterShellError, 'LibreOffice output is missing' unless File.file?(generated)
      File.rename(generated, tmptarget) unless generated == tmptarget
    end
  end

  def sandbox_available?
    return false if Redmine::Platform.mswin?
    return false unless [LIBRE_OFFICE_BIN, BWRAP_BIN, ENV_BIN].all? { |path| File.executable?(path) }
    return false unless File.directory?('/etc/fonts') && File.file?('/etc/ld.so.cache')

    # Unlike a mere executable check, this catches disabled user namespaces and
    # common container seccomp restrictions. The bounded check runs only when
    # status is requested; the real conversion still fails closed on errors.
    return @sandbox_probe_ok unless @sandbox_probe_ok.nil?
    command = [ENV_BIN, '-i', BWRAP_BIN, '--die-with-parent', '--new-session',
               '--unshare-user', '--unshare-pid', '--unshare-net', '--unshare-ipc', '--unshare-uts',
               '--ro-bind', '/usr', '/usr']
    %w(/bin /sbin /lib /lib64).each do |path|
      if File.symlink?(path)
        command.concat(['--symlink', File.readlink(path), path])
      elsif File.directory?(path)
        command.concat(['--ro-bind', path, path])
      end
    end
    command.concat(['--', '/usr/bin/true'])
    @sandbox_probe_ok = Timeout.timeout(5) { Open3.capture3(*command).last.success? }
  rescue Errno::ENOENT, Errno::EACCES, Timeout::Error
    @sandbox_probe_ok = false
  end
  private :sandbox_available?

  def validate_libre_output!
    pending = [tmpdir]
    while (directory = pending.pop)
      Dir.children(directory).each do |name|
        path = File.join(directory, name)
        stat = File.lstat(path) # Unlike File.file?, never follows symlinks.
        if stat.directory?
          pending << path
        elsif !stat.file? || stat.nlink != 1
          raise ConverterShellError, 'LibreOffice produced an unsafe output entry'
        end
      end
    end
  rescue SystemCallError => e
    raise ConverterShellError, "Could not inspect LibreOffice output: #{e.class}"
  end
  private :validate_libre_output!

  def soffice(src, user_installation)
    output_format = preview_format.to_s
    unless ALLOWED_OUTPUT_FORMATS.include?(output_format)
      raise ConverterBadArgument, 'Unsupported LibreOffice output format'
    end
    if Redmine::Platform.mswin?
      raise ConverterShellError, 'LibreOffice sandbox is not supported on Windows'
    end

    # Redmine stores attachments under absolute paths. Bind only this single
    # input, never its containing directory or the host filesystem root.
    paths = [src, user_installation, tmpdir]
    unless paths.all? { |path| path.is_a?(String) && path.start_with?('/') && !path.include?("\0") }
      raise ConverterBadArgument, 'LibreOffice sandbox requires absolute paths'
    end

    input_name = File.basename(src)
    profile_host_dir = File.dirname(user_installation)
    if input_name == '.' || input_name == '..' || src == '/' ||
       tmpdir == '/' || profile_host_dir == '/'
      raise ConverterBadArgument, 'Refusing to mount a host root or directory as LibreOffice input'
    end
    input_in_sandbox = File.join('/input', input_name)
    # bwrap 0.4.0 does not support --clearenv. Clear the inherited environment
    # before bwrap starts, then supply a minimal environment via --setenv.
    args = [
      ENV_BIN, '-i', BWRAP_BIN,
      '--die-with-parent', '--new-session',
      '--unshare-user', '--unshare-pid', '--unshare-net', '--unshare-ipc', '--unshare-uts',
      '--dir', '/usr',
      '--ro-bind', '/usr/bin', '/usr/bin',
      '--ro-bind', '/usr/lib', '/usr/lib',
      '--dir', '/usr/share',
      '--dir', '/etc',
      '--ro-bind', '/etc/fonts', '/etc/fonts',
      '--ro-bind', '/etc/ld.so.cache', '/etc/ld.so.cache',
      '--dev', '/dev', '--proc', '/proc',
      '--tmpfs', '/tmp', '--tmpfs', '/run',
      '--dir', '/input',
      '--ro-bind', src, input_in_sandbox,
      '--bind', tmpdir, '/output',
      '--bind', profile_host_dir, '/profile',
      '--setenv', 'HOME', '/tmp',
      '--setenv', 'TMPDIR', '/tmp',
      '--setenv', 'XDG_CACHE_HOME', '/tmp/cache',
      '--setenv', 'XDG_CONFIG_HOME', '/tmp/config',
      '--setenv', 'PATH', '/usr/bin:/bin',
      '--setenv', 'LANG', 'C.UTF-8',
      '--chdir', '/tmp', '--',
      LIBRE_OFFICE_BIN,
      '--headless', '--invisible', '--nodefault', '--nofirststartwizard',
      '--nolockcheck', '--nologo', '--norestore',
      '--convert-to', output_format,
      '--outdir', '/output',
      '-env:UserInstallation=file:///profile/user_installation',
      input_in_sandbox
    ]
    # The /usr/share tree may contain application secrets. Mount only the
    # resources LibreOffice actually needs, not all of /usr/share or /usr/local.
    optional_dirs = %w(
      /usr/lib64 /usr/share/fonts /usr/share/fontconfig /usr/share/locale
      /usr/share/mime /usr/share/libreoffice /usr/share/icu /usr/share/zoneinfo
      /etc/alternatives /etc/libreoffice
    )
    extra_mounts = optional_dirs.select { |path| File.directory?(path) }.flat_map do |path|
      ['--ro-bind', path, path]
    end
    # Merged-usr platforms have /bin and /lib as symlinks; older distributions
    # may have real directories. Preserve the host layout, without binding /.
    %w(/bin /sbin /lib /lib64).each do |path|
      if File.symlink?(path)
        extra_mounts.concat(['--symlink', File.readlink(path), path])
      elsif File.directory?(path)
        extra_mounts.concat(['--ro-bind', path, path])
      end
    end
    # Mount configuration resources before the execution arguments.
    execution = args.index('--setenv')
    args.insert(execution, *extra_mounts)
    args.map { |arg| shell_quote(arg) }.join(' ')
  end

  def fix_image_path
    filepath = Dir[tmpdir + '/*.html'][0]
    return if filepath.nil?
    basefilename = File.basename(filepath, '.html')
    return if basefilename.ascii_only?
    if File.exist?(filepath)
      text = File.read(filepath)
      new_contents = text.gsub(/(?<=img src=")([A-Za-z%\d_.-]+)(?=_html)/, ERB::Util.url_encode(basefilename))
      File.open(filepath, 'w') { |file| file.puts new_contents }
    end
  end
end
