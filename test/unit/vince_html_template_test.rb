# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class VinceHtmlTemplateTest < ActiveSupport::TestCase
  TEMPLATE = File.expand_path('../../converters/vince/app/views/vince/vince.html.erb', __dir__)

  def test_full_html_template_uses_current_stable_redmine_styles_only
    source = File.read(TEMPLATE)

    assert_includes source, '<!DOCTYPE html>'
    assert_includes source, "stylesheet_link_tag 'application', 'responsive'"
    assert_not_includes source, 'jquery-ui-1.11.0'
    assert_not_includes source, 'tribute-3.7.3'
  end
end
