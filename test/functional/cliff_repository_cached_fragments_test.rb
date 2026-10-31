# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Repository entry pages use the same Cliff top hook as attachment pages.
class CliffRepositoryCachedFragmentsTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests RepositoriesController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :repositories

  PROJECT_ID = 3

  def setup
    super
    User.current = nil
    @old_enabled_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = @old_enabled_scm + ['Filesystem'] unless @old_enabled_scm.include?('Filesystem')
    @old_settings = Setting.plugin_redmine_more_previews
    settings = ZIPPY_SETTINGS.deep_dup
    settings['converter']['cliff'] = {
      'active' => '1', 'mime_types' => {'eml' => {'active' => '1', 'format' => 'html'}}
    }
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    EnabledModule.find_or_create_by!(project_id: PROJECT_ID, name: 'redmine_more_previews')
    @repo_dir = Dir.mktmpdir('rmp-cliff-repo')
    File.binwrite(File.join(@repo_dir, 'cached.eml'),
      "From: writer@example.test\r\nTo: reader@example.test\r\nSubject: repo-cache-subject\r\n" \
      "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nrepository body\r\n")
    @repository = Repository::Filesystem.create!(project: Project.find(PROJECT_ID), url: @repo_dir, path_encoding: '')
    @storage = Dir.mktmpdir('rmp-cliff-repo-cache')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @request.session[:user_id] = 1
  end

  def teardown
    super
    Setting.enabled_scm = @old_enabled_scm
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@repo_dir)
  end

  def test_repeat_repository_entry_page_uses_cached_header
    entry = {id: PROJECT_ID, repository_id: @repository.id,
             path: repository_path_hash(['cached.eml'])[:param]}
    get :entry, params: entry
    assert_response :success
    assert_includes response.body, 'repo-cache-subject'
    assert File.file?(@repository.preview_filepath('cached.eml', nil))
    assert File.file?(@repository.preview_assetpath('cached.eml', nil, asset: 'headers.html'))

    Cliff.any_instance.stubs(:convert).raises('unexpected repository conversion')
    get :entry, params: entry
    assert_response :success
    assert_includes response.body, 'repo-cache-subject'
  end
end
