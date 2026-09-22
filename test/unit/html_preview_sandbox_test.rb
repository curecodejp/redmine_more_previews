# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The full HTML preview is rendered in a sandboxed iframe (GHSA-j23w-wwfh-gwfp).
# A bare sandbox also blocks downloads started inside the frame, which made the
# Zippy listing links unusable in html mode; allow-downloads permits exactly
# that (user-initiated downloads) and nothing else.
class HtmlPreviewSandboxTest < ActiveSupport::TestCase
  def helper
    ApplicationController.helpers
  end

  def test_html_preview_iframe_is_sandboxed_with_downloads_allowed
    html = helper.more_previews_tag('/attachments/more_preview/1.html', 'preview.html', type: 'text/html').to_s
    assert_includes html, '<iframe'
    assert_not_includes html, '<object'
    sandbox = html[/<iframe[^>]*\ssandbox="([^"]*)"/, 1]
    assert_equal ['allow-downloads'], sandbox.to_s.split, 'sandbox must contain allow-downloads and nothing else'
  end

  def test_non_html_preview_iframe_is_not_sandboxed
    html = helper.more_previews_tag('/attachments/more_preview/1.pdf', 'preview.pdf', type: 'application/pdf').to_s
    assert_not_includes html, 'sandbox='
  end
end
