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

class Libre < RedmineMorePreviews::Conversion
  LIBRE_OFFICE_BIN = '/usr/bin/soffice'.freeze
  BWRAP_BIN = '/usr/bin/bwrap'.freeze
  ENV_BIN = '/usr/bin/env'.freeze
  ALLOWED_OUTPUT_FORMATS = %w(html txt pdf png jpg).freeze

  # Conversion must never silently fall back to unsandboxed LibreOffice.
  # This version supports Linux installations using system-packaged LibreOffice
  # and bubblewrap. Other platforms need a separate, equivalent sandbox.
  def status
    available = !Redmine::Platform.mswin? &&
                File.executable?(LIBRE_OFFICE_BIN) && File.executable?(BWRAP_BIN) &&
                File.executable?(ENV_BIN) &&
                File.directory?('/etc/fonts') && File.file?('/etc/ld.so.cache')
    [:text_libre_office_available, available]
  end

  def convert
    raise ConverterShellError, 'LibreOffice sandbox unavailable' unless sandbox_available?

    Dir.mktmpdir do |tdir|
      user_installation = File.join(tdir, 'user_installation')
      command(cd + join + soffice(source, user_installation))
      fix_image_path
      command(cd + join + move(thisdir(outfile)))
    end
  end

  def sandbox_available?
    !Redmine::Platform.mswin? &&
      File.executable?(LIBRE_OFFICE_BIN) && File.executable?(BWRAP_BIN) &&
      File.executable?(ENV_BIN) && File.directory?('/etc/fonts') && File.file?('/etc/ld.so.cache')
  end
  private :sandbox_available?

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
      '--symlink', 'usr/bin', '/bin',
      '--symlink', 'usr/sbin', '/sbin',
      '--symlink', 'usr/lib', '/lib',
      '--symlink', 'usr/lib64', '/lib64',
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
      /etc/alternatives
    )
    extra_mounts = optional_dirs.select { |path| File.directory?(path) }.flat_map do |path|
      ['--ro-bind', path, path]
    end
    # Mount configuration resources before the execution arguments.
    execution = args.index('--setenv')
    args.insert(execution, *extra_mounts)
    args.map { |arg| shell_quote(arg) }.join(' ')
  end

  def fix_image_path
    filepath = Dir[tmpdir + '/*.html'][0]
    return if filepath.nil?
    basefilename = filepath.split('/')[-1].split('.')[0]
    return if basefilename.ascii_only?
    if File.exist?(filepath)
      text = File.read(filepath)
      new_contents = text.gsub(/(?<=img src=")([A-Za-z%\d_]+)(?=_html)/, URI::encode_www_form_component(basefilename))
      File.open(filepath, 'w') { |file| file.puts new_contents }
    end
  end
end
