# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'erb'

class VinceHtmlTemplateTest < ActiveSupport::TestCase
  TEMPLATE = File.expand_path('../../converters/vince/app/views/vince/vince.html.erb', __dir__)

  def render(format)
    @preview_format = format
    @vcfs = []
    @converter = Struct.new(:public_web_directory).new('/plugin_assets/redmine_more_previews/converters/vince')
    ERB.new(File.read(TEMPLATE)).result(binding).squish
  end

  def test_full_html_output_is_self_contained_and_starts_with_doctype
    source = File.read(TEMPLATE)
    html = render('html')

    assert_match(/\A<!DOCTYPE html>/, html)
    assert_includes html, 'font-family: Arial, Helvetica, sans-serif'
    assert_includes html, '/plugin_assets/redmine_more_previews/converters/vince/stylesheets/redmine_more_previews_vince.css'
    assert_not_includes source, 'stylesheet_link_tag'
    assert_not_includes source, 'jquery-ui-1.11.0'
    assert_not_includes source, 'tribute-3.7.3'
    assert_not_includes source, 'heads_for_theme'
  end

  def test_inline_output_has_no_document_only_markup
    html = render('inline')

    assert_not_includes html, '<!DOCTYPE'
    assert_not_includes html, 'html, body {'
    assert_includes html, '/plugin_assets/redmine_more_previews/converters/vince/stylesheets/redmine_more_previews_vince.css'
  end
end
