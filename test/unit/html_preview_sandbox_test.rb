# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The full HTML preview is rendered in a sandboxed iframe (GHSA-j23w-wwfh-gwfp).
# A bare sandbox also blocks downloads started inside the frame, which made the
# Zippy listing links unusable in html mode; allow-downloads permits exactly
# that (user-initiated downloads) and nothing else.
class HtmlPreviewSandboxTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  def setup
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS
  end

  def teardown
    super
    Setting.plugin_redmine_more_previews = @old_settings
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
    assert helper_module.preview_allows_downloads?('archive.zip')
    assert helper_module.preview_allows_downloads?('archive.tgz')
    assert_not helper_module.preview_allows_downloads?('page.html')
    assert_not helper_module.preview_allows_downloads?('notes.md')
    assert_not helper_module.preview_allows_downloads?(nil)
    assert_match(/\Asandbox allow-downloads; default-src 'none'/, helper_module.html_preview_csp('archive.zip'))
    assert_match(/\Asandbox; default-src 'none'/, helper_module.html_preview_csp('page.html'))
  end
end
