# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'nokogiri'

class InlinePreviewScrubberTest < ActiveSupport::TestCase
  def test_external_protocol_relative_and_backslash_sources_are_removed
    ['https://evil.example/t.png', '//evil.example/t.png', '/\evil.example/t.png'].each do |src|
      assert_nil img_src(src), src.inspect
    end
  end

  def test_protocol_relative_sources_with_url_ignored_characters_are_removed
    # Browsers remove tab, LF and CR before resolving URLs, turning these into
    # protocol-relative URLs even though the original bytes do not start //.
    ["/\t/evil.example/t.png", "/\n/evil.example/t.png", "/\r/evil.example/t.png", "/\t\\evil.example/t.png"].each do |src|
      assert_nil img_src(src), src.inspect
    end
  end

  def test_relative_path_source_is_removed
    # Inline previews have no base URL, and relative image paths already 404.
    assert_nil img_src('x.png')
  end

  def test_removing_source_preserves_image_node_and_alt_text
    image = img_node('https://evil.example/t.png')

    assert image, 'img must remain present'
    assert_nil image['src']
    assert_equal 'a', image['alt']
  end

  def test_same_origin_absolute_path_source_is_preserved
    src = '/plugin_assets/redmine_more_previews/converters/vince/images/logo.png'

    assert_equal src, img_src(src)
  end

  def test_data_image_source_is_preserved_with_or_without_newline
    assert_equal 'data:image/png;base64,iVBORw0KGgo=', img_src('data:image/png;base64,iVBORw0KGgo=')

    src = "data:image/png;base64,\niVBORw0KGgo="
    assert_equal src, img_src(src)
  end

  def test_non_image_data_source_is_removed
    # Loofah permits this value, so its removal proves the additional src
    # restriction is applied after Loofah's URI checks.
    assert_nil img_src('data:text/plain,hello')
  end

  def test_uppercase_data_image_source_is_preserved
    src = 'DATA:image/png;base64,iVBORw0KGgo='

    assert_equal src, img_src(src)
  end

  def test_svg_data_image_source_is_removed_by_loofah
    # This is Loofah's existing behavior, not additional protection provided
    # by this change; keep it visible so a future Loofah change is detected.
    assert_nil img_src('data:image/svg+xml,<svg/>')
  end

  def test_every_allowed_uri_attribute_is_explicitly_accounted_for
    # If poster, srcset, or another URI attribute becomes allowed, require an
    # explicit decision about whether it needs the same URL restriction.
    scrubber = RedmineMorePreviews::Patches::ApplicationHelperPatch::InlinePreviewScrubber
    uri_attributes = scrubber::ALLOWED_ATTRIBUTES.select do |attribute|
      Loofah::HTML5::SafeList::ATTR_VAL_IS_URI.include?(attribute)
    end

    assert_equal %w[cite href src], uri_attributes
  end

  private

  def sanitize(html)
    helper = Object.new
    helper.extend(ApplicationHelper)
    helper.sanitize_inline_preview(html)
  end

  def img_node(src)
    Nokogiri::HTML.fragment(sanitize(%Q{<img src="#{src}" alt="a">})).at_css('img')
  end

  def img_src(src)
    img_node(src)&.[]('src')
  end
end
