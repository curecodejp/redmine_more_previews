# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The full HTML preview is rendered in a sandboxed iframe (GHSA-j23w-wwfh-gwfp).
# A bare sandbox also blocks downloads started inside the frame, which made the
# Zippy listing links unusable in html mode. allow-downloads removes the
# sandboxed-downloads flag altogether -- clicks and automatic starts such as a
# <meta refresh> alike -- so it is granted only to previews whose HTML the
# plugin generates itself; scripts, forms, navigation and same-origin access
# stay disabled.
class HtmlPreviewSandboxTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  def setup
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS
    Setting.clear_cache # the plugin reads the string key, the writer caches the symbol key
  end

  def teardown
    super
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache # the writer caches the symbol key; the plugin reads the string key
  end

  def helper
    ApplicationController.helpers
  end

  def sandbox_of(html)
    html[/<iframe[^>]*\ssandbox="([^"]*)"/, 1]
  end

  def test_html_preview_iframe_is_fully_sandboxed_by_default
    html = helper.more_previews_tag('/attachments/more_preview/1.html', 'preview.html', type: 'text/html').to_s
    assert_includes html, '<iframe'
    assert_not_includes html, '<object'
    assert_equal '', sandbox_of(html)
  end

  def test_html_preview_iframe_allows_downloads_only_when_asked
    html = helper.more_previews_tag('/attachments/more_preview/1.html', 'preview.html', type: 'text/html', allow_downloads: true).to_s
    assert_equal ['allow-downloads'], sandbox_of(html).to_s.split, 'sandbox must contain allow-downloads and nothing else'
    assert_not_includes html, 'allow_downloads', 'the option must not leak into the markup'
  end

  def test_non_html_preview_is_not_sandboxed
    html = helper.more_previews_tag('/attachments/more_preview/1.pdf', 'preview.pdf', type: 'application/pdf').to_s
    assert_not_includes html, 'sandbox='
  end

  def test_only_listed_converters_allow_downloads
    helper_module = RedmineMorePreviews::ControllerHelper
    Dir.mktmpdir do |dir|
      zip = build_zip(File.join(dir, 'archive.zip'), 'file.txt' => 'x')
      tgz = build_tgz(File.join(dir, 'archive.tgz'), 'file.txt' => 'x')
      assert helper_module.preview_allows_downloads?(zip)
      assert helper_module.preview_allows_downloads?(tgz)
      assert_match(/\Asandbox allow-downloads; default-src 'none'/, helper_module.html_preview_csp(zip))
    end
    assert_not helper_module.preview_allows_downloads?('page.html', :pathonly => true)
    assert_not helper_module.preview_allows_downloads?('notes.md', :pathonly => true)
    assert_not helper_module.preview_allows_downloads?(nil)
    assert_not helper_module.preview_allows_downloads?(''), 'blank file must not raise'
    assert_not helper_module.preview_allows_downloads?('/nonexistent/archive.zip'), 'unreadable file must fail closed'
    assert_match(/\Asandbox; default-src 'none'/, helper_module.html_preview_csp('page.html', :pathonly => true))
  end

  # the converter is chosen by content first (Converter.mime), so the decision
  # must be too: HTML named archive.zip is rendered by Pass, not Zippy
  def test_content_detection_wins_over_the_extension
    helper_module = RedmineMorePreviews::ControllerHelper
    Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS.deep_merge(
      'converter' => {'pass' => {'active' => '1', 'mime_types' => {'html' => {'active' => '1', 'format' => 'html'}}}}
    )
    Setting.clear_cache
    html = '<!DOCTYPE html><html><body><meta http-equiv="refresh" content="0;url=/x"></body></html>'
    Dir.mktmpdir do |dir|
      spoofed = File.join(dir, 'archive.zip')
      File.write(spoofed, html)
      assert_not helper_module.preview_allows_downloads?(spoofed)
      assert_match(/\Asandbox; /, helper_module.html_preview_csp(spoofed))
      assert helper_module.preview_allows_downloads?(build_zip(File.join(dir, 'real.zip'), 'file.txt' => 'x'))
    end
    # repository entries are not on disk: the same decision from the bytes
    Dir.mktmpdir do |dir|
      zip_bytes = File.binread(build_zip(File.join(dir, 'r.zip'), 'file.txt' => 'x'))
      assert_not helper_module.preview_allows_downloads?('archive.zip', :content => html)
      assert helper_module.preview_allows_downloads?('archive.zip', :content => zip_bytes)
      assert_not helper_module.preview_allows_downloads?('archive.zip', :content => nil), 'missing content must fail closed'
    end
  end
end
