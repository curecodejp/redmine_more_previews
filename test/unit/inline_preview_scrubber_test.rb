# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'cgi'
require 'nokogiri'

class InlinePreviewScrubberTest < ActiveSupport::TestCase
  def setup
    RedmineMorePreviews::Patches::ApplicationHelperPatch::INLINE_PREVIEW_CACHE.clear
    RedmineMorePreviews::Converter.stubs(:cache_previews?).returns(true)
  end

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

  def test_heading_id_is_preserved_with_namespace_prefix
    heading = Nokogiri::HTML.fragment(sanitize('<h1 id="t">T</h1>')).at_css('h1')

    assert_equal 'rmp-t', heading['id']
  end

  def test_footnote_round_trip_link_is_preserved
    fragment = Nokogiri::HTML.fragment(sanitize('<a href="#fn1">1</a><div id="fn1">note</div>'))

    assert_equal fragment.at_css('a')['href'].delete_prefix('#'), fragment.at_css('div')['id']
  end

  def test_redmine_element_ids_cannot_be_clobbered
    # Keep converter output from claiming ids looked up by Redmine's own JavaScript.
    output = sanitize('<div id="preview_frame">x</div><div id="ajax-indicator">y</div>')

    assert_not_includes output, 'id="preview_frame"'
    assert_not_includes output, 'id="ajax-indicator"'
  end

  def test_already_prefixed_id_is_prefixed_again
    # Otherwise converter input could preempt a name inside the namespace.
    div = Nokogiri::HTML.fragment(sanitize('<div id="rmp-preview_frame">x</div>')).at_css('div')

    assert_equal 'rmp-rmp-preview_frame', div['id']
  end

  def test_encoded_japanese_fragment_matches_raw_japanese_id
    html = '<a href="#%E6%97%A5%E6%9C%AC%E8%AA%9E">x</a><h2 id="日本語">h</h2>'
    fragment = Nokogiri::HTML.fragment(sanitize(html))
    href_id = CGI.unescape(fragment.at_css('a')['href']).delete_prefix('#')

    assert_equal href_id, fragment.at_css('h2')['id']
  end

  def test_empty_or_whitespace_containing_id_is_removed
    ['', 'a b'].each do |id|
      div = Nokogiri::HTML.fragment(sanitize(%Q{<div id="#{id}">x</div>})).at_css('div')

      assert_nil div['id'], id.inspect
    end
  end

  def test_bare_hash_href_is_not_rewritten
    link = Nokogiri::HTML.fragment(sanitize('<a href="#">top</a>')).at_css('a')

    assert_equal '#', link['href']
  end

  def test_path_with_fragment_href_is_not_rewritten
    link = Nokogiri::HTML.fragment(sanitize('<a href="/a#b">link</a>')).at_css('a')

    assert_equal '/a#b', link['href']
  end

  def test_id_cannot_escape_its_attribute
    output = sanitize('<div id="a&quot;&lt;script&gt;">x</div>')
    fragment = Nokogiri::HTML.fragment(output)

    assert_equal ['div'], fragment.element_children.map(&:name)
    assert_equal 'rmp-a"<script>', fragment.at_css('div')['id']
    assert_nil fragment.at_css('script')
  end

  def test_checkbox_is_preserved_disabled_and_unnamed
    input = Nokogiri::HTML.fragment(sanitize('<input type="checkbox" name="q" checked>')).at_css('input')

    assert input
    assert_equal 'disabled', input['disabled']
    assert_nil input['name']
    assert input.attribute('checked')
  end

  def test_non_checkbox_inputs_are_removed
    ['text', 'IMAGE', ' checkbox '].each do |type|
      # Browsers do not trim enumerated attributes, so the spaced value falls
      # back to text and must not be treated as a checkbox here either.
      assert_nil Nokogiri::HTML.fragment(sanitize(%Q{<input type="#{type}">})).at_css('input'), type.inspect
    end
  end

  def test_link_type_does_not_make_stylesheet_get_removed
    html = '<link rel="stylesheet" type="text/css" href="/plugin_assets/redmine_more_previews/converters/vince/stylesheets/vince.css">'
    link = Nokogiri::HTML.fragment(sanitize(html)).at_css('link')

    assert link
  end

  def test_inline_preview_accepts_input_at_byte_limit
    max = RedmineMorePreviews::Patches::ApplicationHelperPatch::MAX_INLINE_PREVIEW_HTML_BYTES
    html = '<p>' + ('a' * (max - 7)) + '</p>'

    output = sanitize(html)

    assert_equal html, output
  end

  def test_inline_preview_rejects_oversized_html_without_parsing_it
    max = RedmineMorePreviews::Patches::ApplicationHelperPatch::MAX_INLINE_PREVIEW_HTML_BYTES
    html = '<script>alert(1)</script>' + ('x' * max)
    [defined?(Rails::HTML5::SafeListSanitizer) && Rails::HTML5::SafeListSanitizer,
     Rails::HTML::SafeListSanitizer].compact.each { |klass| klass.expects(:new).never }

    output = sanitize(html)

    assert_includes output, I18n.t(:text_more_previews_inline_too_large)
    assert_not_includes output, 'alert(1)'
    assert_not_includes output, '<script>'
    assert output.html_safe?
  end

  def test_inline_preview_counts_bytes_not_characters
    max = RedmineMorePreviews::Patches::ApplicationHelperPatch::MAX_INLINE_PREVIEW_HTML_BYTES
    output = sanitize('あ' * ((max / 3) + 1))

    assert_includes output, I18n.t(:text_more_previews_inline_too_large)
  end

  # the parser refuses these with an exception; small input must not fail the page
  def test_inline_preview_shows_a_notice_for_nesting_over_the_parser_limit
    output = sanitize('<script>alert(1)</script>' + '<div>' * 500 + 'x' + '</div>' * 500)

    assert_equal ERB::Util.html_escape(I18n.t(:text_more_previews_inline_too_complex)), output
    assert output.html_safe?
  end

  def test_inline_preview_shows_a_notice_for_attributes_over_the_parser_limit
    attributes = (0...500).map { |i| %(a#{i}="1") }.join(' ')
    output = sanitize("<script>alert(1)</script><span #{attributes}>x</span>")

    assert_equal ERB::Util.html_escape(I18n.t(:text_more_previews_inline_too_complex)), output
    assert output.html_safe?
  end

  def test_inline_preview_still_sanitizes_nesting_below_the_parser_limit
    output = sanitize('<script>alert(1)</script>' + '<div>' * 300 + 'x' + '</div>' * 300)

    assert_includes output, '<div>'
    assert_not_includes output, '<script>'
    assert_not_includes output, I18n.t(:text_more_previews_inline_too_complex)
  end

  def test_inline_preview_sanitizes_identical_html_only_once
    html = '<p>cached</p><script>alert(1)</script>'
    first = with_real_sanitizer_count { sanitize(html) }
    second = with_real_sanitizer_count { sanitize(html) }

    assert_equal [1, 0], [first.last, second.last]
    assert_equal '<p>cached</p>', second.first
    assert second.first.html_safe?
  end

  def test_inline_preview_cache_does_not_mix_up_different_html
    assert_equal '<p>one</p>', sanitize('<p>one</p><script>alert(1)</script>')
    assert_equal '<p>two</p>', sanitize('<p>two</p><script>alert(2)</script>')
  end

  def test_inline_preview_cache_is_kept_apart_per_sub_uri
    html = '<link rel="stylesheet" href="/redmine/plugin_assets/redmine_more_previews/a.css">'

    Redmine::Utils.stubs(:relative_url_root).returns('/redmine')
    assert_includes sanitize(html), '<link'
    Redmine::Utils.stubs(:relative_url_root).returns('')
    assert_not_includes sanitize(html), '<link'
  end

  def test_inline_preview_is_not_cached_when_the_preview_cache_is_disabled
    RedmineMorePreviews::Converter.stubs(:cache_previews?).returns(false)
    html = '<p>never kept</p>'
    2.times { assert_equal [html, 1], with_real_sanitizer_count { sanitize(html) } }
  end

  def test_inline_preview_does_not_cache_parser_limit_failures
    html = '<div>' * 500 + 'x' + '</div>' * 500
    notice = ERB::Util.html_escape(I18n.t(:text_more_previews_inline_too_complex))
    2.times { assert_equal [notice, 1], with_real_sanitizer_count { sanitize(html) } }
  end

  def test_inline_preview_still_strips_scripts_below_limit
    output = sanitize('<p>safe</p><script>alert(1)</script>')

    assert_includes output, '<p>safe</p>'
    assert_not_includes output, '<script>'
    assert_not_includes output, 'alert(1)'
  end

  private

  def sanitize(html)
    helper = Object.new
    helper.extend(ApplicationHelper)
    helper.sanitize_inline_preview(html)
  end

  # [the block's result, how many times the html was really sanitized]
  def with_real_sanitizer_count
    scrubber = RedmineMorePreviews::Patches::ApplicationHelperPatch::InlinePreviewScrubber
    original = scrubber.method(:new)
    count = 0
    scrubber.define_singleton_method(:new) do |*args|
      count += 1
      original.call(*args)
    end
    [yield, count]
  ensure
    scrubber.singleton_class.send(:remove_method, :new)
  end

  def img_node(src)
    Nokogiri::HTML.fragment(sanitize(%Q{<img src="#{src}" alt="a">})).at_css('img')
  end

  def img_src(src)
    img_node(src)&.[]('src')
  end
end
