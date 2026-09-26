# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The repository previews show the content of a file, so they must be guarded by
# :browse_repository, as the entry and raw actions of Redmine are, and not by
# :view_changesets, which only allows the list of revisions.
class RepositoriesPreviewPermissionTest < Redmine::ControllerTest
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
    @project = Project.find(PRJ_ID)
    @project.update_column(:is_public, false) # no non member or anonymous permissions
    EnabledModule.create!(project_id: PRJ_ID, name: 'redmine_more_previews')

    @repo_dir = Dir.mktmpdir('rmp-fs-repo')
    build_zip(File.join(@repo_dir, 'a.zip'), 'dir/' => '', 'dir/file.txt' => 'hello')
    @repository = Repository::Filesystem.create!(project: @project, url: @repo_dir, path_encoding: '')

    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)

    @user = User.generate!
    @request.session[:user_id] = @user.id
  end

  def teardown
    super
    Setting.enabled_scm = @old_enabled_scm
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache # the writer caches the symbol key; the plugin reads the string key
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@repo_dir)
  end

  def test_view_changesets_alone_does_not_allow_the_preview
    grant(:view_changesets)
    get :more_preview, params: preview_params
    assert_response :forbidden
  end

  def test_view_changesets_alone_does_not_allow_the_asset
    grant(:view_changesets)
    get :more_asset, params: asset_params
    assert_response :forbidden
  end

  def test_browse_repository_allows_the_preview
    grant(:browse_repository)
    get :more_preview, params: preview_params
    assert_response :success
    assert_includes response.body, 'file.txt'
  end

  def test_browse_repository_allows_the_asset
    grant(:browse_repository)
    get :more_asset, params: asset_params
    assert_response :success
    assert_equal 'hello', response.body
  end

  def test_actions_are_registered_under_browse_repository_only
    %w(repositories/more_preview repositories/more_asset).each do |action|
      assert_includes Redmine::AccessControl.permission(:browse_repository).actions, action
      assert_not_includes Redmine::AccessControl.permission(:view_changesets).actions, action
    end
  end

  private

  def grant(permission)
    role = Role.generate!(permissions: [permission, :use_redmine_more_previews])
    Member.create!(project: @project, principal: @user, role_ids: [role.id])
  end

  def preview_params
    {id: PRJ_ID, repository_id: @repository.id, path: 'a.zip', format: 'html'}
  end

  def asset_params
    {id: PRJ_ID, repository_id: @repository.id, path: 'a', baseformat: 'zip',
     asset: 'dir/file', assetformat: 'txt'}
  end
end
