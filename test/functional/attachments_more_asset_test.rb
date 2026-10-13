# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# End to end: a crafted archive is attached to an issue and its entries are
# requested through the more_preview / more_asset actions.
class AttachmentsMoreAssetTest < Redmine::ControllerTest
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
    @request.session[:user_id] = 2 # jsmith, member of project 1
  end

  def teardown
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache # the writer caches the symbol key; the plugin reads the string key
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
  end

  def attach(archive_path)
    file = Rack::Test::UploadedFile.new(archive_path, 'application/zip', true)
    a = Attachment.new(container: Issue.find(1), file: file, author: User.find(2))
    assert a.save
    a
  end

  # the attachment page forwards its query string to the preview; a stray asset
  # parameter must not turn the inline listing into an asset request (it crashed
  # with "undefined method to_utf8 for nil" once the listing was cached)
  def test_show_page_ignores_an_asset_parameter
    Dir.mktmpdir do |dir|
      a = attach(build_tar(File.join(dir, 'a.tar'), 'safe.txt' => 'safe'))
      with_zippy_format('tar', 'inline') do
        get :show, params: {id: a.id, filename: a.filename, format: 'html'}
        assert_response :success
        assert_select 'a', text: 'safe.txt'
        # listing is cached now; the same page with ?asset= must still render it
        get :show, params: {id: a.id, filename: a.filename, format: 'html', asset: 'safe.txt'}
        assert_response :success
        assert_select 'a', text: 'safe.txt'
        assert_not_includes response.body, 'safe</'
      end
      with_zippy_format('tar', 'html') do
        get :show, params: {id: a.id, filename: a.filename, format: 'html', asset: 'safe.txt'}
        assert_response :success
        assert_select 'iframe[src*="more_preview"]'
        assert_select 'iframe[src*="asset"]', 0
      end
    end
  end

  def with_zippy_format(ext, format)
    settings = Setting.plugin_redmine_more_previews.to_h.deep_dup
    settings['converter']['zippy']['mime_types'][ext]['format'] = format
    Setting.plugin_redmine_more_previews = settings
    # The Setting writer and plugin reader can use symbol/string cache keys.
    # Clear both when changing formats in the same test request session.
    Setting.clear_cache
    yield
  ensure
    Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS
    Setting.clear_cache
  end

  # Turning off the project module must disable direct URLs as well as the UI.
  # Keep the normal attachment authorization path in place.
  def test_disabled_project_module_blocks_previews_and_assets
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'module.zip'), 'file.txt' => 'hello'))
      EnabledModule.where(project_id: 1, name: 'redmine_more_previews').delete_all

      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :not_found
      get :more_preview, params: {id: a.id, format: 'html', asset: 'file.txt'}
      assert_response :not_found
      get :more_asset, params: {id: a.id, asset: 'file', assetformat: 'txt'}
      assert_response :not_found

      EnabledModule.create!(project_id: 1, name: 'redmine_more_previews')
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success
      assert_includes response.body, 'file.txt'
      get :more_asset, params: {id: a.id, asset: 'file', assetformat: 'txt'}
      assert_response :success
      assert_equal 'hello', response.body
    end
  end

  def test_regular_entry_is_served_as_attachment
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'ok.zip'), 'dir/file.txt' => 'hello'))
      get :more_preview, params: {id: a.id, format: 'html', asset: 'dir/file.txt'}
      assert_response :success
      assert_equal 'hello', response.body
      assert_match(/attachment/, response.headers['Content-Disposition'])
    end
  end

  def test_toc_link_of_a_nested_entry_resolves_to_the_entry
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'nested.zip'), 'dir/' => '', 'dir/file.txt' => 'nested'))
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success
      href = response.body[/href="([^"]*asset=[^"]*)"/, 1]
      assert href, "no link in #{response.body}"
      query = Rack::Utils.parse_query(URI.parse(CGI.unescapeHTML(href)).query)
      get :more_preview, params: {id: a.id, format: 'html'}.merge(query.symbolize_keys)
      assert_response :success
      assert_equal 'nested', response.body
    end
  end

  # a nested asset is stored at its own path below the preview, and served from
  # there afterwards, not extracted again for each request
  def test_nested_asset_is_extracted_once
    Dir.mktmpdir do |dir|
      a = attach(build_tar(File.join(dir, 'nested.tar'), 'dir/file.txt' => 'nested'))
      get :more_preview, params: {id: a.id, format: 'html'}
      get :more_asset, params: {id: a.id, asset: 'dir/file', assetformat: 'txt'}
      assert_response :success
      assert_equal 'nested', File.read(File.join(a.preview_dirname(format: 'html'), 'dir', 'file.txt'))
      Zippy.any_instance.expects(:convert).never
      get :more_asset, params: {id: a.id, asset: 'dir/file', assetformat: 'txt'}
      assert_response :success
      assert_equal 'nested', response.body
    end
  end

  # the links of the stored listing lead to entries whose names are not ASCII,
  # in UTF-8 or in the code page of Windows: the list of the assets has them by
  # the name of the link
  def test_toc_links_of_entries_with_non_ascii_names_resolve_to_the_entries
    Dir.mktmpdir do |dir|
      cp932 = "日本語/資料.txt".encode('CP932').b
      a = attach(build_tar(File.join(dir, 'names.tar'), 'ディレクトリ/ファイル.txt' => 'utf-8', cp932 => 'cp932'))
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success
      hrefs = response.body.scan(/href="([^"]*asset=[^"]*)"/).flatten
      assert_equal 2, hrefs.size, "links in #{response.body}"
      bodies = hrefs.map do |href|
        query = Rack::Utils.parse_query(URI.parse(CGI.unescapeHTML(href)).query)
        get :more_preview, params: {id: a.id, format: 'html'}.merge(query.symbolize_keys)
        assert_response :success
        response.body
      end
      assert_equal %w(cp932 utf-8), bodies.sort
    end
  end

  def test_asset_escaping_the_preview_directory_is_rejected
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'bad.zip'), '../../escaped.txt' => 'owned'))
      ['../../escaped.txt', '/etc/hostname', 'dir/../../x.txt'].each do |asset|
        get :more_preview, params: {id: a.id, format: 'html', asset: asset}
        assert_response :not_found, asset
      end
      assert_empty Dir.glob(File.join(@storage, '**', 'escaped.txt'))
      assert_empty Dir.glob(File.join(@storage, 'escaped.txt'))
    end
  end

  def test_more_asset_route_rejects_traversal
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'bad.zip'), 'ok.txt' => 'x'))
      get :more_asset, params: {id: a.id, asset: '../../etc/hostname', assetformat: 'txt'}
      assert_response :not_found
      get :more_asset, params: {id: a.id, asset: '../..', assetformat: 'txt'}
      assert_response :not_found
    end
  end

  # Same behavior as Redmine's show/download actions when the disk file has
  # disappeared after the attachment record was created.
  def test_missing_disk_file_is_rejected_by_all_preview_endpoints
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'missing.zip'), 'ok.txt' => 'hello'))
      assert a.readable?
      File.delete(a.diskfile)
      assert_not a.readable?

      # No converter should run, including in the uncached path.
      Zippy.any_instance.expects(:convert).never
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :not_found

      get :more_preview, params: {id: a.id, format: 'html', asset: 'ok.txt'}
      assert_response :not_found

      get :more_asset, params: {id: a.id, asset: 'ok', assetformat: 'txt'}
      assert_response :not_found

      # unsafe/reload bypasses the normal cache only for admins.
      @request.session[:user_id] = 1
      User.current = nil
      get :more_preview, params: {id: a.id, format: 'html', unsafe: '1'}
      assert_response :not_found

      get :more_asset, params: {id: a.id, asset: 'ok', assetformat: 'txt', unsafe: '1'}
      assert_response :not_found

      # The native attachment action already uses this readable? check.
      get :show, params: {id: a.id, filename: a.filename, format: 'html'}
      assert_response :not_found
    end
  end

  def test_missing_entry_is_answered_with_404
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'ok.zip'), 'ok.txt' => 'x'))
      get :more_preview, params: {id: a.id, format: 'html', asset: 'nope.txt'}
      assert_response :not_found
      get :more_asset, params: {id: a.id, asset: 'nope', assetformat: 'txt'}
      assert_response :not_found
      # uncached (transient) branch
      get :more_preview, params: {id: a.id, format: 'html', asset: 'nope.txt', unsafe: '1'}
      assert_response :not_found
    end
  end

  def test_entry_exceeding_its_declared_size_is_answered_with_404
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'lie.zip'), 'big.txt' => 'x' * 20_000))
      Zip::Entry.any_instance.stubs(:size).returns(10)
      get :more_preview, params: {id: a.id, format: 'html', asset: 'big.txt'}
      assert_response :not_found
      get :more_preview, params: {id: a.id, format: 'html', asset: 'big.txt', unsafe: '1'}
      assert_response :not_found
    end
  end
end
