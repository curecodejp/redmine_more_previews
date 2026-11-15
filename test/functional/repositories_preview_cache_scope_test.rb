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
    Setting.enabled_scm = (@old_enabled_scm + ['Filesystem']).uniq
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

  # Cliff uses Repository#asset_link when rendering extracted email attachments.
  # A cached asset previously raised ArgumentError because preview_assetpath was
  # called without the entry path and revision, causing Cliff to show an error page.
  def test_cached_repository_asset_has_a_working_download_link
    get :more_asset, params: asset_params(PRJ_A, @repo_a, 'dir/secret', 'txt')
    assert_response :success
    assert_equal 'secret', response.body

    cached_file = @repo_a.preview_assetpath('a.zip', nil, asset: 'dir/secret.txt')
    assert File.file?(cached_file), 'the requested asset is cached'

    link = @repo_a.asset_link('a.zip', nil, 'dir/secret.txt')
    assert_includes link, 'dir/secret.txt'
    # The label can look correct while the URL silently drops "dir/". Check
    # the actual encoded href, not just the visible link text.
    href = Nokogiri::HTML.fragment(link).at_css('a')['href']
    assert_includes CGI.unescapeHTML(CGI.unescape(href)), 'dir/secret.txt'
    assert_equal 'dir/secret', Rails.application.routes.recognize_path(href, method: :get)[:asset].then { |a| Array(a).join('/') }

    assert_includes link, 'icon-file'
    assert_includes link, 'text-plain'
  end

  def test_uncached_repository_asset_link_is_hidden
    assert_equal '', @repo_a.asset_link('a.zip', nil, 'dir/missing.txt')
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

  # an SCM that gives an entry for a path with ".." (git and Filesystem refuse
  # one) gets no preview of it: the path names the directory of its preview
  def test_a_path_that_would_leave_the_repository_directory_is_not_previewed
    path = 'dir/../../../escape.zip'
    zip  = File.binread(File.join(@dir_a, 'a.zip'))
    entry = Redmine::Scm::Adapters::Entry.new(name: 'escape.zip', path: path, kind: 'file', size: zip.bytesize)
    Repository::Filesystem.any_instance.stubs(:entry).with(path, anything).returns(entry)
    Repository::Filesystem.any_instance.stubs(:cat).with(path, anything).returns(zip)
    params = {id: PRJ_A, repository_id: @repo_a.identifier_param, path: repository_path_hash(path.split('/'))[:param]}

    get :more_preview, params: params.merge(format: 'html')
    assert_response :not_found
    get :more_asset, params: params.merge(path: 'dir/../../../escape', baseformat: 'zip', asset: 'dir/secret', assetformat: 'txt')
    assert_response :not_found
    # the page of the entry is Redmine's own
    get :entry, params: params
    assert_response :success
    assert_select 'iframe', 0
    assert_empty Dir.glob(File.join(@storage, '**', '*escape*'))
    assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) { @repo_a.preview_dirname(path, nil) }
  end

  # the page of an entry adds the base format of an asset request to the path
  def test_an_asset_base_format_that_would_leave_the_directory_is_not_found
    get :entry, params: {id: PRJ_A, repository_id: @repo_a.identifier_param, path: 'a.zip',
                         asset: 'dir/secret', assetformat: 'txt', baseformat: '/../../x.zip'}
    assert_response :not_found
    assert_empty Dir.glob(File.join(@storage, '**', 'x.zip*'))
  end

  # the preview of no path (the root of the repository) is not found
  def test_the_preview_of_no_path_is_not_found
    get :more_preview, params: {id: PRJ_A, repository_id: @repo_a.identifier_param, format: 'html'}
    assert_response :not_found
  end

  # the directory of a preview is named by the path as it is normalized
  def test_the_directory_is_named_by_the_normalized_path
    assert_equal @repo_a.preview_dirname('a.zip', nil), @repo_a.preview_dirname('./a.zip', nil)
    assert_equal @repo_a.preview_dirname('a.zip', nil), @repo_a.preview_dirname('/a.zip', nil)
  end

  # Zippy builds the listing itself, so on the page of an entry too it keeps
  # Redmine's classes (the converter is looked up by the path and revision)
  def test_an_inline_listing_keeps_the_classes_of_zippy
    settings = ZIPPY_SETTINGS.deep_dup
    settings['converter']['zippy']['mime_types']['zip']['format'] = 'inline'
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    get :entry, params: {id: PRJ_A, repository_id: @repo_a.identifier_param, path: 'a.zip', format: 'html'}
    assert_response :success
    assert_select 'table.list', text: /secret\.txt/
  end

  # the previous layout (per repository class and identifier) is removed on start
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

  # only the directories of the former layout (repository/<scm>s) are removed
  def test_legacy_cache_removal_keeps_other_directories
    FileUtils.mkdir_p(File.join(@storage, 'repository', 'gits', 'a.zip'))
    other = File.join(@storage, 'repository', 'other', 'keep.txt')
    FileUtils.mkdir_p(File.dirname(other))
    File.write(other, 'keep')

    RedmineMorePreviews::Patches::RepositoryPatch.remove_legacy_cache
    assert_not File.exist?(File.join(@storage, 'repository', 'gits'))
    assert File.file?(other)
  end

  def test_legacy_cache_is_removed_after_initialize
    legacy = File.join(@storage, 'repository', 'filesystems', 'a.zip')
    FileUtils.mkdir_p(legacy)
    init = File.expand_path('../../../init.rb', __FILE__)
    hooks = ActiveSupport.instance_variable_get(:@load_hooks)[:after_initialize].
      select {|block, _| block.source_location&.first == init}
    assert_not_empty hooks
    hooks.each {|block, _| block.call(Rails.application)}
    assert_not File.exist?(legacy)
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
