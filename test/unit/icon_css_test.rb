# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'erb'

class IconCssTest < ActiveSupport::TestCase
  TEMPLATE = File.expand_path('../../app/views/hooks/redmine_more_previews/_icon_css.html.erb', __dir__)

  def test_redmine_6_does_not_emit_legacy_background_image_css
    assert_operator Redmine::VERSION::MAJOR, :>=, 6

    css = ERB.new(File.read(TEMPLATE)).result(binding)

    assert_not_includes css, 'background-image'
    assert_match(/<style>\s*<\/style>/m, css)
  end
end
