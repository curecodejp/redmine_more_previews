# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# NilText is for development and diagnostics: it is not registered in
# production, so it cannot be enabled there
class NilTextRegistrationTest < ActiveSupport::TestCase
  INIT = File.expand_path('../../converters/nil_text/init.rb', __dir__)

  def test_nil_text_is_registered_outside_production
    assert RedmineMorePreviews::Converter.installed?(:nil_text)
  end

  def test_nil_text_is_not_registered_in_production
    converters = RedmineMorePreviews::Converter.registered_converters
    registered = converters.delete(:nil_text)
    Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new('production'))
    load INIT
    assert_nil converters[:nil_text]
  ensure
    converters[:nil_text] = registered if registered
  end
end
