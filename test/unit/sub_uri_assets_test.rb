# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Redmine can be mounted below a sub-URI (RAILS_RELATIVE_URL_ROOT=/redmine).
# The converters' static assets are served from that root as well, so both the
# urls the converters emit and the allow-list the inline sanitizer matches them
# against have to carry it.
class SubUriAssetsTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  def setup
    @original_root = Redmine::Utils.relative_url_root
  end

  def teardown
    Redmine::Utils.relative_url_root = @original_root
  end

  def helper
    Object.new.extend(ApplicationHelper)
  end

  def stylesheet_link(href)
    %(<link rel="stylesheet" media="all" href="#{href}">)
  end

  def vince_stylesheet_path
    '/plugin_assets/redmine_more_previews/converters/vince/stylesheets/redmine_more_previews_vince.css'
  end

  # --- the urls the converters emit -------------------------------------------------

  def test_public_web_directory_has_no_prefix_without_a_sub_uri
    Redmine::Utils.relative_url_root = ''
    assert_equal '/plugin_assets/redmine_more_previews/converters/zippy',
                 RedmineMorePreviews::Converter.find(:zippy).public_web_directory
  end

  def test_public_web_directory_honours_the_sub_uri
    Redmine::Utils.relative_url_root = '/redmine'
    assert_equal '/redmine/plugin_assets/redmine_more_previews/converters/zippy',
                 RedmineMorePreviews::Converter.find(:zippy).public_web_directory
  end

  # Rails swallows a trailing slash when it builds urls (asset_url_helper joins
  # the paths, url.rb chomps the script name), so a root written that way works
  # for Redmine itself; emitting "//plugin_assets/..." here would both address a
  # host named plugin_assets and miss the sanitizer's allow-list below
  def test_public_web_directory_normalizes_a_trailing_slash
    ['/redmine/', '/'].each do |root|
      Redmine::Utils.relative_url_root = root
      assert_equal "#{root.chomp('/')}/plugin_assets/redmine_more_previews/converters/zippy",
                   RedmineMorePreviews::Converter.find(:zippy).public_web_directory,
                   "relative_url_root #{root.inspect} must not produce a doubled slash"
    end
  end

  # --- the allow-list the inline sanitizer matches them against ----------------------

  def test_inline_sanitizer_keeps_the_plugin_stylesheet_without_a_sub_uri
    Redmine::Utils.relative_url_root = ''
    out = helper.sanitize_inline_preview(stylesheet_link(vince_stylesheet_path)).to_s
    assert_includes out, vince_stylesheet_path
  end

  def test_inline_sanitizer_keeps_the_plugin_stylesheet_under_a_sub_uri
    Redmine::Utils.relative_url_root = '/redmine'
    href = "/redmine#{vince_stylesheet_path}"
    out = helper.sanitize_inline_preview(stylesheet_link(href)).to_s
    assert_includes out, href, 'the converter\'s own stylesheet must survive under a sub-URI'
  end

  # the url a converter emits and the allow-list it is matched against must
  # normalize the root the same way, whatever it is set to
  def test_inline_sanitizer_keeps_the_stylesheet_a_converter_emits_for_any_root
    ['', '/', '/redmine', '/redmine/'].each do |root|
      Redmine::Utils.relative_url_root = root
      href = "#{RedmineMorePreviews::Converter.find(:vince).public_web_directory}/stylesheets/redmine_more_previews_vince.css"
      out = helper.sanitize_inline_preview(stylesheet_link(href)).to_s
      assert_includes out, href, "the stylesheet emitted for relative_url_root #{root.inspect} must survive"
    end
  end

  # everything the allow-list rejected without a sub-URI must stay rejected
  def test_inline_sanitizer_drops_foreign_stylesheets_under_a_sub_uri
    Redmine::Utils.relative_url_root = '/redmine'
    [
      'https://example.invalid/x.css',
      '/attachments/download/1/evil.css',
      '/redmine/attachments/download/1/evil.css',
      '/redmine/plugin_assets/redmine_more_previews/../../x.css',
      '/redmine/plugin_assets/other_plugin/x.css',
      # not served below the sub-URI: this is some other application's path
      vince_stylesheet_path
    ].each do |href|
      out = helper.sanitize_inline_preview(stylesheet_link(href)).to_s
      assert_not_includes out, '<link', "#{href} must not be kept"
    end
  end
end
