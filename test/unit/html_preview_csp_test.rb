# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class HtmlPreviewCspTest < ActiveSupport::TestCase
  def test_same_origin_styles_and_images_are_allowed_without_restoring_same_origin
    csp = RedmineMorePreviews::ControllerHelper::HTML_PREVIEW_CSP

    assert_includes csp, 'sandbox;'
    assert_not_includes csp, 'allow-same-origin'
    assert_includes csp, "default-src 'none'"
    assert_includes csp, "style-src 'self' 'unsafe-inline'"
    assert_includes csp, "img-src 'self' data:"
    assert_not_includes csp, 'allow-scripts'
  end
end
