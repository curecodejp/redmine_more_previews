# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# reload and unsafe convert again, bypassing the cache and the remembered
# failures: they take effect for administrators only. A failed conversion is
# remembered for a while and not tried again until an administrator reloads.
class PreviewReloadFailuresTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests AttachmentsController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :issues, :trackers, :issue_statuses, :enumerations,
           :projects_trackers, :attachments

  def setup
    set_tmp_attachments_directory
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS
    EnabledModule.create!(project_id: 1, name: 'redmine_more_previews')
    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @dir = Dir.mktmpdir('rmp-reload')
    @attachment = attach(build_tar(File.join(@dir, 'a.tar'), 'safe.txt' => 'safe'))
  end

  def teardown
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@dir)
  end

  # --- reload and unsafe --------------------------------------------------------------

  def test_reload_by_a_member_is_served_from_the_cache
    as_user(2) # jsmith, member
    get_preview
    Zippy.any_instance.expects(:convert).never
    get_preview(reload: '1')
    assert_response :success
    assert_select 'a', text: 'safe.txt'
  end

  def test_reload_by_an_administrator_converts_again
    as_user(1) # admin
    get_preview
    Zippy.any_instance.expects(:convert).once
    get_preview(reload: '1')
  end

  def test_unsafe_by_a_member_uses_the_cache
    as_user(2)
    get_preview(unsafe: '1')
    assert_response :success
    assert File.exist?(cached_listing), 'converted into the cache, as without unsafe'
  end

  def test_unsafe_by_an_administrator_bypasses_the_cache
    as_user(1)
    get_preview(unsafe: '1')
    assert_response :success
    assert_not File.exist?(cached_listing)
  end

  def test_reload_link_is_shown_to_administrators_only
    as_user(2)
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_select 'a.icon-reload', 0
    as_user(1)
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_select 'a.icon-reload', 1
  end

  # an inline preview is converted while the attachment page is rendered, from
  # the page's query parameters
  def test_inline_reload_by_a_member_is_served_from_the_cache
    inline_tar
    as_user(2)
    get_page
    Zippy.any_instance.expects(:convert).never
    get_page(reload: '1')
    assert_response :success
    assert_select 'a', text: 'safe.txt'
  end

  def test_inline_reload_by_an_administrator_converts_again
    inline_tar
    as_user(1)
    get_page
    Zippy.any_instance.expects(:convert).once
    get_page(reload: '1')
  end

  # unsafe converts without the cache, which the inline view cannot serve: it
  # is ignored there, for administrators as well
  def test_inline_unsafe_is_ignored
    inline_tar
    [2, 1].each do |user|
      as_user(user)
      get_page(unsafe: '1')
      assert_response :success
      assert_select 'a', text: 'safe.txt'
      assert_empty Dir.glob(File.join(@storage, 'failures', '*')), "user #{user}"
    end
  end

  # --- assets -------------------------------------------------------------------------------

  # the preview is stored as index.<format> next to its assets: an asset of that
  # name would be the preview, and its failure the preview's
  def test_asset_named_as_the_preview_is_not_found
    as_user(2)
    get :more_asset, params: {id: @attachment.id, asset: 'index', assetformat: 'html'}
    assert_response 404
    assert_empty Dir.glob(File.join(@storage, 'failures', '*'))
    get_preview
    assert_response :success
    assert_select 'a', text: 'safe.txt'
  end

  # --- failures ---------------------------------------------------------------------------

  def test_preview_without_output_is_not_found_without_the_cache
    as_user(1)
    Zippy.any_instance.stubs(:convert)
    get_preview(unsafe: '1')
    assert_response 404
  end

  def test_failed_conversion_is_not_tried_again
    as_user(2)
    Zippy.any_instance.expects(:convert).once.raises(RuntimeError, 'broken')
    get_preview
    assert_response 404
    get_preview
    assert_response 404
  end

  def test_failure_is_tried_again_after_its_time
    as_user(2)
    Zippy.any_instance.stubs(:convert).raises(RuntimeError, 'broken')
    get_preview
    Zippy.any_instance.unstub(:convert)
    age_failures(RedmineMorePreviews::Converter.failure_ttl + 60)
    get_preview
    assert_response :success
  end

  def test_reload_by_an_administrator_forgets_a_failure
    as_user(2)
    Zippy.any_instance.stubs(:convert).raises(RuntimeError, 'broken')
    get_preview
    Zippy.any_instance.unstub(:convert)
    get_preview(reload: '1')
    assert_response 404, 'a member cannot make it try again'
    as_user(1)
    get_preview(reload: '1')
    assert_response :success
  end

  def test_too_large_is_remembered_as_too_large
    as_user(2)
    Zippy.any_instance.expects(:convert).once.raises(RedmineMorePreviews::Exceptions::ConverterTooLarge, 'large')
    get_preview
    assert_response 413
    get_preview
    assert_response 413
  end

  def test_missing_asset_is_remembered_and_does_not_stop_the_others
    as_user(2)
    get :more_asset, params: {id: @attachment.id, asset: 'missing', assetformat: 'txt'}
    assert_response 404
    Zippy.any_instance.expects(:convert).never
    get :more_asset, params: {id: @attachment.id, asset: 'missing', assetformat: 'txt'}
    assert_response 404
    Zippy.any_instance.unstub(:convert)
    get :more_asset, params: {id: @attachment.id, asset: 'safe', assetformat: 'txt'}
    assert_response :success
    assert_equal 'safe', response.body
    get_preview
    assert_response :success
  end

  def test_busy_is_not_remembered
    as_user(2)
    RedmineMorePreviews::Converter.stubs(:max_conversions).returns(1)
    slots = File.join(@storage, 'slots')
    FileUtils.mkdir_p(slots)
    File.open(File.join(slots, '0.lock'), File::RDWR | File::CREAT) do |slot|
      slot.flock(File::LOCK_EX)
      get_preview
      assert_response 503
    end
    get_preview
    assert_response :success
  end

  private

  def as_user(id)
    @request.session[:user_id] = id
  end

  def get_preview(extra = {})
    get :more_preview, params: {id: @attachment.id, format: 'html'}.merge(extra)
  end

  def get_page(extra = {})
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}.merge(extra)
  end

  def inline_tar
    settings = ZIPPY_SETTINGS.deep_dup
    settings['converter']['zippy']['mime_types']['tar']['format'] = 'inline'
    Setting.plugin_redmine_more_previews = settings
  end

  def cached_listing
    @attachment.preview_filepath(format: 'html')
  end

  def age_failures(seconds)
    Dir.glob(File.join(@storage, 'failures', '*')).each do |path|
      File.utime(Time.now - seconds, Time.now - seconds, path)
    end
  end

  def attach(archive_path)
    file = Rack::Test::UploadedFile.new(archive_path, 'application/x-tar', true)
    a = Attachment.new(container: Issue.find(1), file: file, author: User.find(2))
    assert a.save
    a
  end
end
