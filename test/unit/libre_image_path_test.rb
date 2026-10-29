# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class LibreImagePathTest < ActiveSupport::TestCase
  def rewrite_html(basename, image_prefix)
    Dir.mktmpdir('rmp-libre-image-path') do |dir|
      path = File.join(dir, "#{basename}.html")
      original = %(<html><body><img src="#{image_prefix}_html_image.png"></body></html>)
      File.write(path, original)

      worker = Libre.allocate
      worker.tmpdir = dir
      worker.fix_image_path

      return File.read(path)
    end
  end

  def test_non_ascii_basename_with_underscore_is_rewritten
    basename = '議事録_2026'
    html = rewrite_html(basename, 'source_2026')

    assert_includes html, %(img src="#{URI.encode_www_form_component(basename)}_html_image.png")
  end

  def test_non_ascii_basename_without_underscore_is_rewritten
    basename = '議事録2026'
    html = rewrite_html(basename, 'source2026')

    assert_includes html, %(img src="#{URI.encode_www_form_component(basename)}_html_image.png")
  end

  def test_non_ascii_basename_with_dots_and_dotted_image_prefix_is_rewritten
    basename = '議事録.v2.完成'
    html = rewrite_html(basename, 'source.v2-final')

    assert_includes html, %(img src="#{URI.encode_www_form_component(basename)}_html_image.png")
  end

  def test_image_sources_with_paths_or_external_urls_are_not_rewritten
    Dir.mktmpdir('rmp-libre-image-path') do |dir|
      path = File.join(dir, '議事録.v2.html')
      original = '<img src="assets/source_html_image.png">' \
                 '<img src="https://example.invalid/source_html_image.png">' \
                 '<img src="source.v2_html_image.png">'
      File.write(path, original)

      worker = Libre.allocate
      worker.tmpdir = dir
      worker.fix_image_path

      html = File.read(path)
      assert_includes html, 'src="assets/source_html_image.png"'
      assert_includes html, 'src="https://example.invalid/source_html_image.png"'
      assert_includes html, %(src="#{URI.encode_www_form_component('議事録.v2')}_html_image.png")
    end
  end

  def test_ascii_basename_is_not_rewritten
    basename = 'minutes_2026'
    html = rewrite_html(basename, 'source_2026')

    assert_includes html, 'img src="source_2026_html_image.png"'
  end
end
