# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class HtmlPreviewCspTest < ActiveSupport::TestCase
  def test_html_preview_response_allows_same_origin_styles_and_images_without_restoring_same_origin
    csp = headers_for('html')['Content-Security-Policy'].to_s

    assert_includes csp, 'sandbox;'
    assert_not_includes csp, 'allow-same-origin'
    assert_includes csp, "default-src 'none'"
    assert_includes csp, "style-src 'self' 'unsafe-inline'"
    assert_includes csp, "img-src 'self' data:"
    assert_not_includes csp, 'font-src'
    assert_not_includes csp, 'allow-scripts'
  end

  def test_all_preview_formats_receive_non_rendering_security_headers
    %w(html xml pdf png).push('').each do |format|
      headers = headers_for(format)

      assert_equal 'nosniff', headers['X-Content-Type-Options'], format.inspect
      assert_equal 'no-referrer', headers['Referrer-Policy'], format.inspect
    end
  end

  def test_unlisted_formats_receive_csp
    # Keep new preview formats from shipping without protection by default.
    ['', 'json', 'svg', 'wat', 'html', 'xml', 'text', 'txt'].each do |format|
      assert_not_nil headers_for(format)['Content-Security-Policy'], format.inspect
    end
  end

  def test_csp_exempt_format_matching_is_case_insensitive
    %w(HTML Xml).each do |format|
      assert_not_nil headers_for(format)['Content-Security-Policy'], format
    end
    %w(PDF PNG).each do |format|
      assert_nil headers_for(format)['Content-Security-Policy'], format
    end
  end

  def test_browser_viewer_formats_do_not_receive_csp
    %w(pdf png jpg jpeg gif).each do |format|
      assert_nil headers_for(format)['Content-Security-Policy'], format
    end
  end

  private

  def headers_for(format)
    controller = Class.new do
      include RedmineMorePreviews::ControllerHelper

      attr_reader :params, :response

      def initialize(format)
        @params = ActionController::Parameters.new(format: format)
        @response = ActionDispatch::TestResponse.new
      end

      public :apply_preview_security_headers
    end.new(format)

    controller.apply_preview_security_headers
    controller.response.headers
  end
end
