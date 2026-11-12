# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# A request for the preview of a repository entry asks the SCM for the entry
# once (git starts git ls-tree for each), and writes the entry to a file only
# when it is converted: a stored preview is served without it.
class RepositoryPreviewQueriesTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests RepositoriesController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :repositories

  PROJECT_ID = 3

  # counts the calls of the SCM adapter while a block runs
  module CountedAdapter
    def entries(*args, **options)
      calls = Thread.current[:rmp_scm_calls]
      calls[:entries] += 1 if calls
      super
    end

    def cat(*args, **options)
      calls = Thread.current[:rmp_scm_calls]
      calls[:cat] += 1 if calls
      super
    end
  end
  Redmine::Scm::Adapters::FilesystemAdapter.prepend(CountedAdapter)

  # records whether the file a conversion is given exists when it is done (on the
  # conversion: Converter.convert is stubbed by other tests)
  module WrittenSource
    def preview(*args, **options, &block)
      super
    ensure
      written = Thread.current[:rmp_written_sources]
      written << File.exist?(source.to_s) if written
    end
  end
  RedmineMorePreviews::Conversion.prepend(WrittenSource)

  def setup
    super
    User.current = nil
    @old_enabled_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = (@old_enabled_scm + ['Filesystem']).uniq
    @old_settings = Setting.plugin_redmine_more_previews
    settings = ZIPPY_SETTINGS.deep_dup
    settings['converter']['cliff'] = {
      'active' => '1', 'mime_types' => {'eml' => {'active' => '1', 'format' => 'html'}}
    }
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    %w(repository redmine_more_previews).each do |name|
      EnabledModule.find_or_create_by!(project_id: PROJECT_ID, name: name)
    end
    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @dir = Dir.mktmpdir('rmp-fs-repo')
    build_zip(File.join(@dir, 'a.zip'), 'f.txt' => 'entry')
    File.binwrite(File.join(@dir, 'm.eml'),
      "From: writer@example.test\r\nTo: reader@example.test\r\nSubject: queries-subject\r\n" \
      "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nbody\r\n")
    @repository = Repository::Filesystem.create!(project: Project.find(PROJECT_ID), url: @dir,
                                                 path_encoding: '', is_default: true)
    @request.session[:user_id] = 1 # admin
  end

  def teardown
    super
    Setting.enabled_scm = @old_enabled_scm
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf([@storage, @dir])
  end

  def test_a_preview_asks_for_the_entry_once
    assert_equal({entries: 1, cat: 1}, scm_calls { get :more_preview, params: preview_params })
    assert_response :success
    assert_includes response.body, 'f.txt'
    # stored
    assert_equal({entries: 1, cat: 1}, scm_calls { get :more_preview, params: preview_params })
    assert_response :success
    @request.headers['If-None-Match'] = response.headers['ETag']
    assert_equal({entries: 1, cat: 1}, scm_calls { get :more_preview, params: preview_params })
    assert_response :not_modified
  end

  def test_an_asset_asks_for_the_entry_once
    get :more_preview, params: preview_params
    assert_response :success
    assert_equal({entries: 1, cat: 1}, scm_calls { get :more_asset, params: asset_params })
    assert_response :success
    assert_equal 'entry', response.body
  end

  # the entry, and the directory it is in for the pagination
  def test_the_page_of_an_entry_asks_for_the_entry_once
    assert_equal({entries: 2, cat: 1}, scm_calls { get :entry, params: entry_params('a.zip') })
    assert_response :success
  end

  # Cliff shows the headers, fields and attachments of an email on its page: each
  # is an asset of its preview
  def test_the_page_of_an_email_asks_for_the_entry_once
    assert_equal({entries: 2, cat: 1}, scm_calls { get :entry, params: entry_params('m.eml') })
    assert_response :success
    assert_includes response.body, 'queries-subject'
    assert_equal({entries: 2, cat: 1}, scm_calls { get :entry, params: entry_params('m.eml') })
    assert_response :success
    assert_includes response.body, 'queries-subject'
  end

  def test_a_stored_preview_is_served_without_writing_the_entry
    assert_equal [true], written_sources { get :more_preview, params: preview_params }
    assert_response :success
    assert_equal [false], written_sources { get :more_preview, params: preview_params }
    assert_response :success
    assert_includes response.body, 'f.txt'
    # an asset that is not stored yet is extracted from the entry
    assert_equal [true], written_sources { get :more_asset, params: asset_params }
    assert_equal 'entry', response.body
    assert_equal [false], written_sources { get :more_asset, params: asset_params }
    assert_equal 'entry', response.body
  end

  def test_a_stored_email_page_is_served_without_writing_the_entry
    get :entry, params: entry_params('m.eml')
    assert_response :success
    written = written_sources { get :entry, params: entry_params('m.eml') }
    assert_response :success
    assert_includes response.body, 'queries-subject'
    assert_not_empty written
    assert written.none?, "the entry was written for #{written.count(true)} of #{written.size} stored previews"
  end

  # a reload converts the entry again: it is written
  def test_a_reload_writes_the_entry
    get :more_preview, params: preview_params
    assert_equal [true], written_sources { get :more_preview, params: preview_params.merge(reload: '1') }
    assert_response :success
    assert_includes response.body, 'f.txt'
  end

  # without the cache (unsafe), the entry is converted each time
  def test_an_unsafe_preview_writes_the_entry
    assert_equal [true], written_sources { get :more_preview, params: preview_params.merge(unsafe: '1') }
    assert_response :success
    assert_includes response.body, 'f.txt'
  end

  private

  def scm_calls
    Thread.current[:rmp_scm_calls] = Hash.new(0)
    yield
    {entries: Thread.current[:rmp_scm_calls][:entries], cat: Thread.current[:rmp_scm_calls][:cat]}
  ensure
    Thread.current[:rmp_scm_calls] = nil
  end

  def written_sources
    Thread.current[:rmp_written_sources] = []
    yield
    Thread.current[:rmp_written_sources]
  ensure
    Thread.current[:rmp_written_sources] = nil
  end

  def preview_params
    {id: PROJECT_ID, repository_id: @repository.identifier_param, path: 'a.zip', format: 'html'}
  end

  def asset_params
    {id: PROJECT_ID, repository_id: @repository.identifier_param, path: 'a', baseformat: 'zip',
     asset: 'f', assetformat: 'txt'}
  end

  # the format of the page: the extension of the path is no format
  def entry_params(path)
    {id: PROJECT_ID, repository_id: @repository.identifier_param, path: path, format: 'html'}
  end
end
