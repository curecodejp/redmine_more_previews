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
  module Patches 
    module ApplicationHelperPatch

      # Allow-list scrubber for converter output that is embedded directly
      # into the Redmine page (preview_format = inline). Converter input is
      # attacker controlled, so script-capable markup must never reach the
      # Redmine origin.
      class InlinePreviewScrubber < Rails::HTML::PermitScrubber

        ALLOWED_TAGS = %w[
          a abbr acronym address b big blockquote br caption cite code col colgroup
          dd del dfn div dl dt em figcaption figure h1 h2 h3 h4 h5 h6 hr i img ins
          kbd li link mark ol p pre q s samp small span strike strong sub sup
          table tbody td tfoot th thead time tr tt u ul var
        ].freeze

        # style survives only after Loofah's css safe-list scrub (no url(),
        # position, expression() ...); Cliff's header tables rely on it
        ALLOWED_ATTRIBUTES = %w[
          abbr align alt border cellpadding cellspacing cite class colspan datetime
          download height href hreflang lang media rel rowspan scope span
          src start style summary title type valign width xml:lang
        ].freeze

        # nodes whose text content must not survive as visible text either;
        # every other disallowed node is stripped but keeps its children
        PRUNED_TAGS = %w[script style noscript template textarea title].freeze

        # strict path charset: no "..", "\\", query or fragment
        PLUGIN_STYLESHEET_HREF =
          %r{\A/plugin_assets/redmine_more_previews/(?:[A-Za-z0-9_\-]+/)*[A-Za-z0-9_\-]+\.css\z}.freeze

        def initialize
          super
          self.tags       = ALLOWED_TAGS
          self.attributes = ALLOWED_ATTRIBUTES
        end

        protected

        def allowed_node?(node)
          return false unless super
          return true  unless node.name == 'link'
          # only this plugin's own static stylesheets (Vince ships its css this
          # way); anything else - other same-origin urls included, since
          # uploaded .css attachments are served as text/css - is dropped
          node['rel'].to_s.strip.casecmp?('stylesheet') &&
            node['href'].to_s.match?(PLUGIN_STYLESHEET_HREF)
        end

        def scrub_node(node)
          if PRUNED_TAGS.include?(node.name)
            node.remove
          else
            super
          end
        end

      end #class

      def self.included(base)
        base.class_eval do
        
          #unloadable 

          def sanitize_inline_preview(html)
            html = html.to_s
            return ''.html_safe if html.blank?
            sanitizer = defined?(Rails::HTML5::SafeListSanitizer) ? Rails::HTML5::SafeListSanitizer : Rails::HTML::SafeListSanitizer
            sanitizer.new.sanitize(html, :scrubber => RedmineMorePreviews::Patches::ApplicationHelperPatch::InlinePreviewScrubber.new).to_s.html_safe
          end #def

          def more_previews_tag(path, filename, options={})

            html_preview = options[:type].to_s.split(';').first == 'text/html'

            if RedmineMorePreviews::Converter.embed? && !html_preview
              content_tag(:div, 
                content_tag(
                  :object,
                  tag(:embed, :href => path, :type => options[:type]),
                  { :style   => "position:absolute;top:0;left:0;width:95%;height:100%;",
                    :title   => filename,
                    :type    => options[:type],
                    :data    => path,
                    :id      => 'preview_object',
                   }.merge(options)
                ),
                :id     => "preview_pane",
                :style  => "position:relative;padding-top:141%;",
              )
            else
              iframe_options = {
                :style                => "position:absolute;top:0;left:0;width:95%;height:16px;",
                :seamless             => "seamless",
                :scrolling            => "no",
                :frameborder          => "0",
                :allowtransparency    => "true",
                :title                => filename,
                :src                  => path,
                :id                   => 'preview_frame',
                :onload               => "$(document).ready(function() {$('#preview_frame').css('height', $(window).height())});".html_safe
              }.merge(options)

              iframe_options[:sandbox] = "" if html_preview

              content_tag(:div,
                content_tag(:script, "$(document).ready(function() { $('#ajax-indicator').show()});".html_safe) +
                content_tag(
                  :iframe,
                  "",
                  iframe_options
                ),
                :id    => "preview_pane",
                :style => "position:relative;padding-top:141%;"
              )
            end #if
          end #def
          
        end #base
      end #self
    end #module
  end #module
end #module

unless ApplicationHelper.included_modules.include?(RedmineMorePreviews::Patches::ApplicationHelperPatch)
  ApplicationHelper.send(:include, RedmineMorePreviews::Patches::ApplicationHelperPatch)
end


