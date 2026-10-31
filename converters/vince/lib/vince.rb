# encoding: utf-8
#
# RedmineMorePreviews vcf (electronic business cards) previewer
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

class Vince < RedmineMorePreviews::Conversion

  # Ruby parsing and ERB rendering must not run without a memory/time limit in
  # the Redmine worker. The child is stopped by RmpProcess before it can grow
  # without bound. The existing conversion timeout is applied by #isolated.
  MAX_MEMORY = 512 * 1024 * 1024

  # Larger vCards are refused before the fork (HTTP 413). 100,000 cards take
  # some 4 MB, so this leaves room for photos embedded as data URIs.
  MAX_SIZE = 20 * 1024 * 1024

  def convert
    # Fetch Redmine configuration before forking. A forked child must not use
    # its inherited ActiveRecord connection, including via Vince translations.
    @iconize = converter_settings["iconize"].to_i > 0
    @vince_default_language = Setting.default_language
    I18n.with_locale(@vince_default_language) { I18n.translate(:"vcard.personal") }

    # RmpProcess.fork runs its block unbounded on platforms without fork.
    # Fail closed instead of processing untrusted vCards in the request worker.
    raise ConverterShellError, 'Vince requires process isolation' unless Process.respond_to?(:fork)

    if File.size(source) > MAX_SIZE
      raise ConverterTooLarge, "the vCard is larger than #{MAX_SIZE / 1024 / 1024} MiB"
    end

    isolated(:memory => MAX_MEMORY) do
      Thread.current[:redmine_more_previews_vince_language] = @vince_default_language
      begin
        @vcfs = VinceLib::VObject::Reader.new(:object => :vcard, :filepath => source).fileall

        case preview_format
        when "html", "inline"
          erb = ERB.new(File.read(File.join(views, 'vince', 'vince.html.erb')))
          obj = I18n.with_locale(@vince_default_language) { erb.result(binding).html_safe }.squish
        when "txt"
          erb = ERB.new(File.read(File.join(views, 'vince', 'vince.txt.erb')))
          obj = I18n.with_locale(@vince_default_language) { erb.result(binding).html_safe }.gsub(/\n{3,}/, "\n")
        end

        File.open(tmptarget, "wb") { |f| f.write(obj) }
      rescue StandardError => e
        # The child exits without a message (see RmpProcess.fork): log why the
        # vCard was not previewed here. The message can quote the vCard.
        Rails.logger.error "vCard #{File.basename(source)} not previewed: #{e.class}: #{e.message}\n#{Array(e.backtrace).join("\n")}"
        raise
      ensure
        Thread.current[:redmine_more_previews_vince_language] = nil
      end
    end
  end #def

end #class
