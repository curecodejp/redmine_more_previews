# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The top-of-page Cliff hook must reuse the stored email conversion instead of
# running a fresh transient conversion whenever somebody opens the page.
class CliffCachedFragmentsTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests AttachmentsController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :issues, :trackers, :issue_statuses, :enumerations,
           :projects_trackers, :attachments

  SOURCE = "From: writer@example.test\r\nTo: reader@example.test\r\nSubject: cached-mail-subject\r\n" \
           "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\ncached mail body\r\n"

  def setup
    set_tmp_attachments_directory
    @old_settings = Setting.plugin_redmine_more_previews
    settings = ZIPPY_SETTINGS.deep_dup
    settings['converter']['cliff'] = {
      'active' => '1', 'mime_types' => {'eml' => {'active' => '1', 'format' => 'html'}}
    }
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    EnabledModule.find_or_create_by!(project_id: 1, name: 'redmine_more_previews')
    @request.session[:user_id] = 2
    @tmp = Dir.mktmpdir('rmp-cliff-cache')
    @storage = Dir.mktmpdir('rmp-cliff-cache-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    path = File.join(@tmp, 'cached.eml')
    File.binwrite(path, SOURCE)
    upload = Rack::Test::UploadedFile.new(path, 'message/rfc822', true)
    @attachment = Attachment.new(container: Issue.find(1), file: upload, author: User.find(2))
    assert @attachment.save
  end

  def teardown
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@tmp)
  end

  def test_repeat_attachment_page_reuses_cached_header_and_fields
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_includes response.body, 'cached-mail-subject'
    assert File.file?(@attachment.preview_filepath)
    assert File.file?(@attachment.preview_assetpath(asset: 'headers.html'))

    # If a second visit tries to run a fresh converter, the child will fail;
    # a successful header proves it is now read from the cache.
    Cliff.any_instance.stubs(:convert).raises('unexpected second conversion')
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_includes response.body, 'cached-mail-subject'
  end

  def test_disabling_cache_keeps_transient_header_rendering
    settings = Setting.plugin_redmine_more_previews.deep_dup
    settings['cache_previews'] = '0'
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache

    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_includes response.body, 'cached-mail-subject'
    assert_not File.file?(@attachment.preview_filepath)
    assert_select '#preview_repository_entry_top table.white'
    assert_select '#preview_repository_entry_top table.email.header_fields'
  end

  def test_full_cache_still_renders_headers_without_repeated_conversions
    RedmineMorePreviews::Lib::RmpCacheSize.stubs(:full?).returns(true)
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_includes response.body, 'cached-mail-subject'
    assert_not File.file?(@attachment.preview_filepath)
    assert_select '#preview_repository_entry_top table.white'
    assert_select '#preview_repository_entry_top table.email.header_fields'
  end

  def test_full_cache_reuses_an_existing_preview_without_reconversion
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert File.file?(@attachment.preview_assetpath(asset: 'headers.html'))

    RedmineMorePreviews::Lib::RmpCacheSize.stubs(:full?).returns(true)
    Cliff.any_instance.stubs(:convert).raises('cached preview must not be reconverted')
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_includes response.body, 'cached-mail-subject'
  end

  def test_admin_reload_does_not_display_stale_cached_headers
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    File.write(@attachment.preview_assetpath(asset: 'headers.html'), 'stale cache header')

    @request.session[:user_id] = 1 # administrator
    User.current = nil
    get :show, params: {id: @attachment.id, filename: @attachment.filename,
                        format: 'html', reload: '1'}
    assert_response :success
    assert_includes response.body, 'cached-mail-subject'
    assert_not_includes response.body, 'stale cache header'
    assert_select '#preview_repository_entry_top table.white'
    assert_select '#preview_repository_entry_top table.email.header_fields'
  end

  def test_full_cache_does_not_accept_an_older_marker
    cache_dir = @attachment.preview_dirname
    FileUtils.mkdir_p(cache_dir)
    File.write(@attachment.preview_filepath, 'old cached mail body')
    File.write(@attachment.preview_assetpath(asset: 'headers.html'), 'old header')
    File.write("#{cache_dir}.converter", 'cliff:maintenance-6.1.4-v1:normal')
    assert_not RedmineMorePreviews::Conversion.current_cached_preview?(@attachment.preview_filepath, :cliff)

    RedmineMorePreviews::Lib::RmpCacheSize.stubs(:full?).returns(true)
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_includes response.body, 'cached-mail-subject'
    assert_not_includes response.body, 'old header'
    assert_select '#preview_repository_entry_top table.white'
    assert_select '#preview_repository_entry_top table.email.header_fields'
    # Cache is full: the transient conversion must not overwrite the old marker.
    assert_equal 'cliff:maintenance-6.1.4-v1:normal', File.read("#{cache_dir}.converter")
  end

  def test_locale_mismatch_does_not_reuse_cached_headers
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    locale_file = "#{@attachment.preview_dirname}#{Cliff::LOCALE_MARKER}"
    assert_equal I18n.locale.to_s, File.read(locale_file)
    assert_not File.exist?(File.join(@attachment.preview_dirname, Cliff::LOCALE_MARKER)),
               'locale metadata must not appear in extracted mail assets'

    # The cached representation came from a different language. Even when the
    # index and version marker are valid, show the current viewer's headers.
    File.write(locale_file, 'other-locale')
    File.write(@attachment.preview_assetpath(asset: 'headers.html'), 'wrong-language-header')
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_includes response.body, 'cached-mail-subject'
    assert_not_includes response.body, 'wrong-language-header'
    assert_equal 'other-locale', File.read(locale_file), 'the fallback must not overwrite shared cache'
  end

  def test_older_cliff_cache_marker_is_invalidated
    cache_dir = @attachment.preview_dirname
    FileUtils.mkdir_p(cache_dir)
    File.write(@attachment.preview_filepath, 'old cached mail body')
    File.write(@attachment.preview_assetpath(asset: 'headers.html'), 'old header')
    File.write("#{cache_dir}.converter", 'cliff:maintenance-6.1.4-v1:normal')

    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_includes response.body, 'cached-mail-subject'
    assert_not_includes response.body, 'old header'
    assert_equal 'cliff:maintenance-6.1.5-v1:normal', File.read("#{cache_dir}.converter")
  end
end
