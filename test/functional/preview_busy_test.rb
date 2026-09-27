# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# A preview that cannot be converted within the wait limit (all conversion slots
# taken, see Conversion#with_slot) is answered with 503 and Retry-After, not
# with 404 and not after an unbounded wait.
class PreviewBusyTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests AttachmentsController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :issues, :trackers, :issue_statuses, :enumerations,
           :projects_trackers, :attachments, :repositories

  def setup
    set_tmp_attachments_directory
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS
    EnabledModule.create!(project_id: 1, name: 'redmine_more_previews')
    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    RedmineMorePreviews::Converter.stubs(:lock_timeout).returns(1)
    RedmineMorePreviews::Converter.stubs(:max_conversions).returns(1)
    @request.session[:user_id] = 2 # jsmith, member of project 1
    @dir = Dir.mktmpdir('rmp-busy')
  end

  def teardown
    @slot&.close
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache # the writer caches the symbol key; the plugin reads the string key
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@dir)
  end

  def test_preview_is_busy_while_all_slots_are_taken
    a = attach(build_tar(File.join(@dir, 'a.tar'), 'safe.txt' => 'safe'))
    take_all_slots
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_busy
  end

  def test_asset_is_busy_while_all_slots_are_taken
    a = attach(build_tar(File.join(@dir, 'a.tar'), 'safe.txt' => 'safe'))
    take_all_slots
    get :more_asset, params: {id: a.id, asset: 'safe', assetformat: 'txt'}
    assert_busy
  end

  def test_unsafe_preview_is_busy_while_all_slots_are_taken
    a = attach(build_tar(File.join(@dir, 'a.tar'), 'safe.txt' => 'safe'))
    take_all_slots
    get :more_preview, params: {id: a.id, format: 'html', unsafe: '1'}
    assert_busy
  end

  # an inline preview is converted while the attachment page is rendered: the
  # page is answered with 503 as well, not with an error
  def test_page_with_an_inline_preview_is_busy_while_all_slots_are_taken
    a = attach(build_tar(File.join(@dir, 'a.tar'), 'safe.txt' => 'safe'))
    settings = ZIPPY_SETTINGS.deep_dup
    settings['converter']['zippy']['mime_types']['tar']['format'] = 'inline'
    Setting.plugin_redmine_more_previews = settings
    take_all_slots
    get :show, params: {id: a.id, filename: a.filename, format: 'html'}
    assert_busy
  end

  # a conversion that failed or timed out gives no preview: 404, not an empty
  # 200 response (cached) or no response at all (not cached)
  def test_timed_out_preview_is_not_found
    a = attach(build_tar(File.join(@dir, 'a.tar'), 'safe.txt' => 'safe'))
    Zippy.any_instance.stubs(:convert).raises(RedmineMorePreviews::Exceptions::ConverterTimeout)
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response 404
    get :more_preview, params: {id: a.id, format: 'html', unsafe: '1'}
    assert_response 404
  end

  def test_preview_is_served_once_a_slot_is_free
    a = attach(build_tar(File.join(@dir, 'a.tar'), 'safe.txt' => 'safe'))
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :success
    assert_select 'a', text: 'safe.txt'
  end

  private

  def attach(archive_path)
    file = Rack::Test::UploadedFile.new(archive_path, 'application/x-tar', true)
    a = Attachment.new(container: Issue.find(1), file: file, author: User.find(2))
    assert a.save
    a
  end

  # as another Redmine process converting a preview
  def take_all_slots
    slots = File.join(@storage, 'slots')
    FileUtils.mkdir_p(slots)
    @slot = File.open(File.join(slots, '0.lock'), File::RDWR | File::CREAT)
    assert @slot.flock(File::LOCK_EX | File::LOCK_NB)
  end

  def assert_busy
    assert_response 503
    assert_equal RedmineMorePreviews::ControllerHelper::BUSY_RETRY_AFTER.to_s, response.headers['Retry-After']
    assert_equal 'text/plain', response.media_type
    assert response.body.present?
  end
end

class RepositoriesPreviewBusyTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests RepositoriesController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :repositories

  PRJ_ID = 3

  def setup
    super
    User.current = nil
    @old_enabled_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = @old_enabled_scm + ['Filesystem'] unless @old_enabled_scm.include?('Filesystem')
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS
    EnabledModule.create!(project_id: PRJ_ID, name: 'redmine_more_previews')
    @repo_dir = Dir.mktmpdir('rmp-fs-repo')
    build_zip(File.join(@repo_dir, 'a.zip'), 'file.txt' => 'hello')
    @repository = Repository::Filesystem.create!(project: Project.find(PRJ_ID), url: @repo_dir, path_encoding: '')
    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    RedmineMorePreviews::Converter.stubs(:lock_timeout).returns(1)
    RedmineMorePreviews::Converter.stubs(:max_conversions).returns(1)
    @request.session[:user_id] = 1 # admin
  end

  def teardown
    super
    @slot&.close
    Setting.enabled_scm = @old_enabled_scm
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache # the writer caches the symbol key; the plugin reads the string key
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@repo_dir)
  end

  def test_repository_preview_is_busy_while_all_slots_are_taken
    slots = File.join(@storage, 'slots')
    FileUtils.mkdir_p(slots)
    @slot = File.open(File.join(slots, '0.lock'), File::RDWR | File::CREAT)
    assert @slot.flock(File::LOCK_EX | File::LOCK_NB)
    get :more_preview, params: {id: PRJ_ID, repository_id: @repository.id,
                                path: repository_path_hash(['a.zip'])[:param], format: 'html'}
    assert_response 503
    assert_equal RedmineMorePreviews::ControllerHelper::BUSY_RETRY_AFTER.to_s, response.headers['Retry-After']
  end

  def test_timed_out_repository_preview_is_not_found
    Zippy.any_instance.stubs(:convert).raises(RedmineMorePreviews::Exceptions::ConverterTimeout)
    params = {id: PRJ_ID, repository_id: @repository.id, path: repository_path_hash(['a.zip'])[:param], format: 'html'}
    get :more_preview, params: params
    assert_response 404
    get :more_preview, params: params.merge(unsafe: '1')
    assert_response 404
  end
end
