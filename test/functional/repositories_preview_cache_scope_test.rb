# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The cached preview of a repository entry must belong to that repository and to
# that content: two projects with a file at the same path, or the same file at two
# revisions, must not share a cached conversion.
class RepositoriesPreviewCacheScopeTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests RepositoriesController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :repositories

  PRJ_A = 3
  PRJ_B = 5

  def setup
    super
    User.current = nil
    @old_enabled_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = @old_enabled_scm + ['Filesystem'] unless @old_enabled_scm.include?('Filesystem')
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS

    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)

    # both are the default repository of their project (blank identifier), with
    # an entry at the same path
    @dir_a, @repo_a = default_repository(PRJ_A, 'dir/secret.txt' => 'secret')
    @dir_b, @repo_b = default_repository(PRJ_B, 'dir/public.txt' => 'public')
    @request.session[:user_id] = 1 # admin
  end

  def teardown
    super
    Setting.enabled_scm = @old_enabled_scm
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache # the writer caches the symbol key; the plugin reads the string key
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@dir_a)
    FileUtils.rm_rf(@dir_b)
  end

  def test_preview_of_another_project_is_not_served_from_the_cache
    get :more_preview, params: preview_params(PRJ_A, @repo_a)
    assert_response :success
    assert_includes response.body, 'secret.txt'

    get :more_preview, params: preview_params(PRJ_B, @repo_b)
    assert_response :success
    assert_includes response.body, 'public.txt'
    assert_not_includes response.body, 'secret.txt'
  end

  def test_asset_of_another_project_is_not_served_from_the_cache
    get :more_asset, params: asset_params(PRJ_A, @repo_a, 'dir/secret', 'txt')
    assert_response :success
    assert_equal 'secret', response.body

    # the same asset name, extracted from project A's archive, must not exist for B
    get :more_asset, params: asset_params(PRJ_B, @repo_b, 'dir/secret', 'txt')
    assert_response :not_found
  end

  def test_changed_content_is_not_served_from_the_cache
    get :more_preview, params: preview_params(PRJ_A, @repo_a)
    assert_response :success
    assert_includes response.body, 'secret.txt'

    File.delete(File.join(@dir_a, 'a.zip'))
    build_zip(File.join(@dir_a, 'a.zip'), 'dir/' => '', 'dir/changed.txt' => 'changed')
    get :more_preview, params: preview_params(PRJ_A, @repo_a)
    assert_response :success
    assert_includes response.body, 'changed.txt'
    assert_not_includes response.body, 'secret.txt'
  end

  def test_the_cache_is_kept_below_the_repository_id
    get :more_preview, params: preview_params(PRJ_A, @repo_a)
    assert_response :success
    path = @repo_a.preview_filepath('a.zip', nil, format: 'html')
    assert File.file?(path)
    assert RedmineMorePreviews::Lib::RmpFile.within_directory?(
      File.join(@storage, 'repository_previews', @repo_a.id.to_s), path
    )
  end

  # the previous layout (per repository identifier only) is removed on start
  def test_legacy_cache_is_removed
    legacy = File.join(@storage, 'repository', 'filesystems', 'a.zip', 'preview.html')
    FileUtils.mkdir_p(legacy)
    File.write(File.join(legacy, 'index.html'), 'stale')
    current = File.join(@storage, 'repository_previews', '1')
    FileUtils.mkdir_p(current)

    RedmineMorePreviews::Patches::RepositoryPatch.remove_legacy_cache
    assert_not File.exist?(File.join(@storage, 'repository'))
    assert File.directory?(current)
  end

  private

  def default_repository(project_id, entries)
    %w(repository redmine_more_previews).each do |name|
      EnabledModule.find_or_create_by!(project_id: project_id, name: name)
    end
    dir = Dir.mktmpdir('rmp-fs-repo')
    build_zip(File.join(dir, 'a.zip'), {'dir/' => ''}.merge(entries))
    repository = Repository::Filesystem.create!(project: Project.find(project_id), url: dir,
                                                path_encoding: '', is_default: true)
    [dir, repository]
  end

  def preview_params(project_id, repository)
    {id: project_id, repository_id: repository.identifier_param, path: 'a.zip', format: 'html'}
  end

  def asset_params(project_id, repository, asset, assetformat)
    {id: project_id, repository_id: repository.identifier_param, path: 'a', baseformat: 'zip',
     asset: asset, assetformat: assetformat}
  end
end
