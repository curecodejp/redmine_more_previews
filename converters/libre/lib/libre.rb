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

  #---------------------------------------------------------------------------------
  # constants
  #---------------------------------------------------------------------------------
  LIBRE_OFFICE_BIN = 'soffice'.freeze
  ALLOWED_OUTPUT_FORMATS = %w(html txt pdf png jpg).freeze
  
  #---------------------------------------------------------------------------------
  # check: is LibreOffice available?
  #---------------------------------------------------------------------------------
  def status
    s = run [LIBRE_OFFICE_BIN, "--version"]
    [:text_libre_office_available, s[2] == 0 ]
  end
  
  def convert
  
    Dir.mktmpdir do |tdir| 
    user_installation = File.join(tdir, "user_installation")
    command(cd + join + soffice( source, user_installation ) )
    fix_image_path
    command(cd + join + move(thisdir(outfile)) )
    end
    
  end #def
  
  def soffice( src, user_installation )
    # The format originates in administrator-editable plugin settings. Validate before
    # interpolating it into a shell command, and quote the accepted argument.
    output_format = preview_format.to_s
    unless ALLOWED_OUTPUT_FORMATS.include?(output_format)
      raise ConverterBadArgument, 'Unsupported LibreOffice output format'
    end
    quoted_format = shell_quote(output_format)
    # Quote the complete -env argument, not just the path portion: a TMPDIR
    # containing spaces or shell metacharacters must remain one soffice argument.
    if Redmine::Platform.mswin?
    "#{LIBRE_OFFICE_BIN} --headless --invisible --nodefault --nofirststartwizard --nolockcheck --nologo --norestore --convert-to #{quoted_format} --outdir #{shell_quote tmpdir} #{shell_quote src}"
    else
    "#{LIBRE_OFFICE_BIN} --headless --invisible --nodefault --nofirststartwizard --nolockcheck --nologo --norestore --convert-to #{quoted_format} --outdir #{shell_quote tmpdir} #{shell_quote("-env:UserInstallation=file://#{user_installation}")} #{shell_quote src}"
    end
  end #def

  def fix_image_path
    filepath = Dir[tmpdir+"/*.html"][0]
    return if filepath.nil?
    basefilename = filepath.split('/')[-1].split('.')[0]
    return if basefilename.ascii_only?
    if File.exist?(filepath)
      text = File.read(filepath)
      new_contents = text.gsub(/(?<=img src=")([A-Za-z%\d_]+)(?=_html)/, URI::encode_www_form_component(basefilename))
      File.open(filepath, "w") {|file| file.puts new_contents }
    end
  end
  
end #class
