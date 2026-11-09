# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# HEIC/HEIF and TIFF previews need a coder ImageMagick may lack (f.i. without
# libheif): enabling them for Maggie is refused there, so they do not fail on
# every preview. Turning Maggie off, or any other setting, is still saved.
class PluginSettingsImageFormatsTest < Redmine::ControllerTest
  tests SettingsController
  fixtures :users, :email_addresses

  def setup
    @request.session[:user_id] = 1 # administrator
    @previous = Setting.plugin_redmine_more_previews
    @settings = {
      'converter' => {
        'maggie' => {
          'active' => '1',
          'mime_types' => {
            'png' => {'active' => '1', 'format' => 'png'},
            'heic' => {'active' => '0', 'format' => 'png'},
            'tif' => {'active' => '0', 'format' => 'png'}
          }
        }
      }
    }
    Setting.plugin_redmine_more_previews = @settings
    Setting.clear_cache
    RedmineMorePreviews.stubs(:imagemagick_reads?).returns(false)
  end

  def teardown
    Setting.plugin_redmine_more_previews = @previous
    Setting.clear_cache
  end

  def test_enabling_heic_without_the_coder_is_not_saved
    updated = enable('heic')
    post :plugin, params: {id: 'redmine_more_previews', settings: updated}
    assert_response :redirect
    assert_equal I18n.t(:error_more_previews_unreadable_image_format, formats: 'HEIC/HEIF', locale: :en), flash[:error]
    assert_equal @settings, Setting.plugin_redmine_more_previews
  end

  def test_enabling_tiff_without_the_coder_is_not_saved
    post :plugin, params: {id: 'redmine_more_previews', settings: enable('tif')}
    assert_includes flash[:error].to_s, 'TIFF'
    assert_equal @settings, Setting.plugin_redmine_more_previews
  end

  def test_error_names_each_unreadable_format_in_the_user_language
    User.find(1).update!(language: 'ja')
    post :plugin, params: {id: 'redmine_more_previews', settings: enable('heic', 'tif')}
    assert_equal I18n.t(:error_more_previews_unreadable_image_format, formats: 'HEIC/HEIF, TIFF', locale: :ja), flash[:error]
  end

  # true and 1, which a JSON body keeps as they are, enable a converter as
  # "1" does (Converter.select_active): the settings are not saved with them
  def test_enabling_heic_with_json_values_is_not_saved
    [[true, true], ['1', true], [true, '1'], [1, 1]].each do |maggie, heic|
      updated = enable('heic')
      updated['converter']['maggie']['active'] = maggie
      updated['converter']['maggie']['mime_types']['heic']['active'] = heic
      @request.headers['Content-Type'] = 'application/json'
      post :plugin, params: {id: 'redmine_more_previews'}, body: {settings: updated}.to_json
      assert_response :redirect, [maggie, heic].inspect
      assert_includes flash[:error].to_s, 'HEIC/HEIF', [maggie, heic].inspect
      assert_equal @settings, Setting.plugin_redmine_more_previews, [maggie, heic].inspect
    end
  end

  def test_enabling_with_the_coder_is_saved
    RedmineMorePreviews.stubs(:imagemagick_reads?).with('HEIC').returns(true)
    RedmineMorePreviews.stubs(:imagemagick_reads?).with('TIFF').returns(true)
    updated = enable('heic', 'tif')
    post :plugin, params: {id: 'redmine_more_previews', settings: updated}
    assert flash[:error].blank?
    assert_equal updated, Setting.plugin_redmine_more_previews
  end

  # the form sends the hidden format checkboxes of a converter that is off
  def test_turning_maggie_off_is_saved_with_heic_still_checked
    updated = enable('heic')
    updated['converter']['maggie']['active'] = '0'
    post :plugin, params: {id: 'redmine_more_previews', settings: updated}
    assert flash[:error].blank?
    assert_equal updated, Setting.plugin_redmine_more_previews
  end

  def test_other_formats_are_saved_without_the_coder
    updated = @settings.deep_dup
    updated['converter']['maggie']['mime_types']['png']['format'] = 'jpg'
    post :plugin, params: {id: 'redmine_more_previews', settings: updated}
    assert flash[:error].blank?
    assert_equal updated, Setting.plugin_redmine_more_previews
  end

  def test_libre_formats_are_still_checked
    updated = @settings.deep_dup
    updated['converter']['libre'] = {'mime_types' => {'docx' => {'active' => '1', 'format' => 'xml'}}}
    post :plugin, params: {id: 'redmine_more_previews', settings: updated}
    assert_equal I18n.t(:error_more_previews_invalid_libre_format, locale: :en), flash[:error]
    assert_equal @settings, Setting.plugin_redmine_more_previews
  end

  # a string where a hash belongs answers [] as well: no TypeError (500)
  def test_malformed_maggie_settings_do_not_fail
    [{'active' => '1', 'mime_types' => 'x'},
     {'active' => '1', 'mime_types' => {'heic' => 'x'}}].each do |maggie|
      post :plugin, params: {id: 'redmine_more_previews', settings: {'converter' => {'maggie' => maggie}}}
      assert_response :redirect, maggie.inspect
    end
  end

  # the program Redmine runs, and whether it reads each format
  def test_settings_show_whether_imagemagick_reads_each_format
    RedmineMorePreviews.stubs(:imagemagick_reads?).with('HEIC').returns(false)
    RedmineMorePreviews.stubs(:imagemagick_reads?).with('TIFF').returns(true)
    RedmineMorePreviews.stubs(:convert_bin).returns('/usr/local/bin/magick')
    get :plugin, params: {id: 'redmine_more_previews'}
    assert_response :success
    assert_select '#converter_settings_maggie p', text: /HEIC\/HEIF \(magick\)/ do
      assert_select 'span.icon-error'
    end
    assert_select '#converter_settings_maggie p', text: /TIFF \(magick\)/ do
      assert_select 'span.icon-ok'
    end
  end

  # the largest HEIC or TIFF image: the default until it is set, then saved
  def test_the_largest_image_is_a_setting
    get :plugin, params: {id: 'redmine_more_previews'}
    assert_select 'input[type=number][name=?][value=?]', 'settings[converter][maggie][max_megapixels]', '64'

    updated = @settings.deep_dup
    updated['converter']['maggie']['max_megapixels'] = '100'
    post :plugin, params: {id: 'redmine_more_previews', settings: updated}
    assert flash[:error].blank?
    assert_equal '100', Setting.plugin_redmine_more_previews.dig('converter', 'maggie', 'max_megapixels')

    get :plugin, params: {id: 'redmine_more_previews'}
    assert_select 'input[name=?][value=?]', 'settings[converter][maggie][max_megapixels]', '100'

    # a value that is not used shows the default that is
    updated['converter']['maggie']['max_megapixels'] = '1.5'
    Setting.plugin_redmine_more_previews = updated
    get :plugin, params: {id: 'redmine_more_previews'}
    assert_select 'input[name=?][value=?]', 'settings[converter][maggie][max_megapixels]', '64'
  end

  private

  def enable(*extensions)
    updated = @settings.deep_dup
    extensions.each {|ext| updated['converter']['maggie']['mime_types'][ext]['active'] = '1'}
    updated
  end
end
