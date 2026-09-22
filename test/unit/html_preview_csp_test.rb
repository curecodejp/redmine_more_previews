# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class HtmlPreviewCspTest < ActiveSupport::TestCase
  def test_html_preview_response_allows_same_origin_styles_and_images_without_restoring_same_origin
    controller = Class.new do
      include RedmineMorePreviews::ControllerHelper

      attr_reader :params, :response

      def initialize(format)
        @params = ActionController::Parameters.new(format: format)
        @response = ActionDispatch::TestResponse.new
      end

      public :apply_preview_security_headers
    end.new('html')

    controller.apply_preview_security_headers
    csp = controller.response.headers['Content-Security-Policy'].to_s

    assert_includes csp, 'sandbox;'
    assert_not_includes csp, 'allow-same-origin'
    assert_includes csp, "default-src 'none'"
    assert_includes csp, "style-src 'self' 'unsafe-inline'"
    assert_includes csp, "img-src 'self' data:"
    assert_not_includes csp, 'allow-scripts'
  end
end
