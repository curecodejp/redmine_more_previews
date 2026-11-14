# encoding: utf-8
#
# RedmineMorePreviews converter to text files
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
#require 'routes'

class Mark < RedmineMorePreviews::Conversion

  #---------------------------------------------------------------------------------
  # delegates
  #---------------------------------------------------------------------------------
  delegate :url_for, :to => "Rails.application.routes.url_helpers"
           
  #---------------------------------------------------------------------------------
  # constants
  #---------------------------------------------------------------------------------
  PANDOC_BIN = 'pandoc'.freeze
  PANDOC_FRM = {"text/markdown" => "markdown", "text/x-web-textile" => "textile", "text/html" => "html"}
  # bytes of address space pandoc may take (see Lib::RmpProcess.run). It takes
  # some 90 MiB for a Markdown file of 60 KB, and 180 MiB for 450 KB. Within
  # the default time limit an input nested deep reached some 255 MiB; the limit
  # bounds what it takes when the time limit is raised
  MAX_MEMORY = 1024**3
  # with --sandbox, pandoc reads no file but those on its command line, f.i.
  # none that LaTeX in the input includes. pandoc before 2.15 refuses the option
  SANDBOX_VERSION = Gem::Version.new("2.15")
  
  class << self
    # the version of pandoc, asked once per process (see #pandoc_bin)
    attr_accessor :pandoc_version
  end
  
  #---------------------------------------------------------------------------------
  # check: is Pandoc available?
  #---------------------------------------------------------------------------------
  def status
    s = run [PANDOC_BIN, "--version"]
    [:text_pandoc_available, s[2] == 0 ]
  end
  
  ########################################################################################
  #
  # convert
  #
  ########################################################################################
  def convert
    command(cd + join + pandoc + join + move(thisdir(outfile)), memory: MAX_MEMORY)
  end #def
  
  #---------------------------------------------------------------------------------
  # pandoc_bin: pandoc, with --sandbox where the version is known to take it
  #---------------------------------------------------------------------------------
  def pandoc_bin
    version = (self.class.pandoc_version ||= installed_pandoc_version)
    version && version >= SANDBOX_VERSION ? "#{PANDOC_BIN} --sandbox" : PANDOC_BIN
  end #def
  
  # nil if pandoc does not tell it: it is asked again for the next conversion
  def installed_pandoc_version
    out, _, status = run [PANDOC_BIN, "--version"], :stderr => false
    version = status == 0 && out.to_s[/\Apandoc(?:\.exe)? (\d+(?:\.\d+)*)/, 1]
    Gem::Version.new(version) if version
  end #def
  private :installed_pandoc_version
  
  #---------------------------------------------------------------------------------
  # pandoc
  #---------------------------------------------------------------------------------
  def pandoc
  
    mime    = RedmineMorePreviews::Converter.mime( source )
    frompts = PANDOC_FRM[mime["mime"]]
    
    # the configured format (the format of the request is compared with it
    # before a conversion, and an asset request names none)
    case preview_format
    when "html"
      base_url = case object["object"]
      when Repository
        url_for( :controller    => "repositories",
                 :action        => "raw",
                 :id            => object["object"].project.identifier,
                 :repository_id => object["object"].identifier_param,
                 :rev           => object["rev"],
                 :path          => object["path"],
                 :only_path     => true
        )
      when Attachment
        url_for( :controller    => "attachments",
                 :action        => "download",
                 :id            => object["object"].id,
                 :filename      => object["object"].filename,
                 :only_path     => true
        )
      else
        nil
      end
      
      if base_url
        base = "<base href='#{ERB::Util.html_escape(base_url)}'>"
        "#{pandoc_bin} #{shell_quote source} -f #{frompts} -t html -s -V header-includes=#{shell_quote base} -o #{shell_quote outfile}"
      else
        "#{pandoc_bin} #{shell_quote source} -f #{frompts} -t html -s -o #{shell_quote outfile}"
      end
      
    when "inline"
      "#{pandoc_bin} #{shell_quote source} -f #{frompts} -t html -o #{shell_quote outfile}"
    when "txt"
      "#{pandoc_bin} #{shell_quote source} -f #{frompts} -t plain -o #{shell_quote outfile}"
    end.to_s
    
  end #def
  
end #class
