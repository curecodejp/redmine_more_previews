# encoding: utf-8
#
# RedmineMorePreviews eml converter
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
# 1.0.0
#       - initial version
# 1.0.1
#       - added timezone support for mail dates in cliff
# 1.0.2
#       - simplified hooks views
# 1.0.3
#       - required files for non eager loading
# 1.1.0
#       - added internationalization for de, en, es, fr, pt, ru, jp, zh
# 1.1.1
#       - fixed japanese localization
# 1.1.2
#       - HTML-escape mail header values and the mail body; label the Cc row correctly
#       - keep the bundled header template in sync
# 1.1.3
#       - bound the size, delimiter lines and nesting of emails; parse them in a child process with a time and memory limit
#       - show why an email is not previewed without the backtrace
#       - keep Mail's warnings of unparsable header fields out of stderr
# 1.1.4
#       - preview emails attached without a file extension
#       - reuse the cached email headers on attachment and repository pages
#       - remove the unused legacy hooks and duplicate templates
# 1.1.5
#       - keep the header fragments in their boxes when converted without the cache
#       - show an inline size notice instead of a 413 page for emails beyond the limits
# 1.1.6
#       - decode text and HTML bodies using their declared charset
#       - preserve Japanese encodings and repair HTML meta charset after conversion
# 1.1.7
#       - embed the inline images of HTML previews as data: URIs
# 1.1.8
#       - show the header boxes for the file Cliff converts, selected by its content
#       - save an attachment whose name is longer than a file system takes, or is . or ..; the subject in French
#

require_relative 'lib/cliff'
require_relative 'lib/cliff_lib/hooks'

RedmineMorePreviews::Converter.register :cliff do
  name           'Cliff'
  author         'Stephan Wenzel'
  description    'Preview email files in preview pane'
  version        '1.1.8'
  url            'https://github.com/HugoHasenbein/redmine_more_previews_cliff'
  author_url     'https://github.com/HugoHasenbein/redmine_more_previews_cliff'
                 
  settings       :logo    => 'logo.png',
                 :partial => 'settings/redmine_more_previews/cliff/settings',
                 :default => Cliff::LIMITS.transform_values(&:to_s)
                 
  mime_types     :eml  =>    {:formats => [:html], :mime => 'message/rfc822', :icon => 'eml.png' },
                 :mime  =>   {:formats => [:html], :mime => 'message/rfc822', :icon => 'eml.png' }
end

