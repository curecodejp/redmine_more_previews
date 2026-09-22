# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Downloads from the sandboxed HTML preview (GHSA-j23w-wwfh-gwfp keeps scripts,
# forms, navigation and same-origin access disabled) are allowed only for
# Zippy's archive listing, whose HTML the plugin generates itself. Both the
# iframe attribute and the response's CSP sandbox directive have to agree:
# the browser applies the union of the two flag sets.
class HtmlPreviewDownloadsTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests AttachmentsController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :issues, :trackers, :issue_statuses, :enumerations,
           :projects_trackers, :attachments

  SETTINGS = ZIPPY_SETTINGS.deep_merge(
    'converter' => {'pass' => {'active' => '1', 'mime_types' => {'html' => {'active' => '1', 'format' => 'html'}}}}
  ).freeze

  def setup
    set_tmp_attachments_directory
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = SETTINGS
    Setting.clear_cache
    EnabledModule.create!(project_id: 1, name: 'redmine_more_previews')
    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @request.session[:user_id] = 2
  end

  def teardown
    super
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache # the writer caches the symbol key; the plugin reads the string key
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
  end

  def attach(path, content_type)
    a = Attachment.new(container: Issue.find(1), file: Rack::Test::UploadedFile.new(path, content_type, true), author: User.find(2))
    assert a.save
    a
  end

  def csp
    response.headers['Content-Security-Policy'].to_s
  end

  def test_zippy_listing_allows_downloads_in_iframe_and_csp
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'a.zip'), 'dir/' => '', 'dir/file.txt' => 'x'), 'application/zip')
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success
      assert_match(/\Asandbox allow-downloads; /, csp)
      assert_no_match(/allow-(scripts|forms|same-origin|top-navigation|popups)/, csp)
      assert_includes csp, "style-src 'self' 'unsafe-inline'", 'same-origin CSS stays allowed (#19139)'
      get :show, params: {id: a.id, filename: a.filename, format: 'html'}
      assert_select 'iframe[sandbox="allow-downloads"]'
    end
  end

  # Converter.mime detects on content first, so this upload is rendered by Pass:
  # the extension alone must not grant downloads (allow-downloads would let the
  # meta refresh start one without a click)
  def test_html_uploaded_as_zip_stays_fully_sandboxed
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'archive.zip')
      File.write(path, '<!DOCTYPE html><html><body><meta http-equiv="refresh" content="0;url=/attachments/download/1/x.bin"></body></html>')
      a = attach(path, 'application/zip')
      assert_equal 'pass', RedmineMorePreviews::Converter.responsible(a.diskfile).id.to_s
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success
      assert_match(/\Asandbox; /, csp)
      get :show, params: {id: a.id, filename: a.filename, format: 'html'}
      assert_select 'iframe[sandbox=""]'
    end
  end

  # the cache directory is shared by all converters producing the same format:
  # a preview produced by Pass must not be served under Zippy's policy once
  # Zippy becomes the selected converter (here: Pass disabled afterwards)
  def test_cached_preview_from_another_converter_is_not_served_with_downloads
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'archive.zip')
      refresh = '<meta http-equiv="refresh" content="0;url=/attachments/download/1/x.bin">'
      File.write(path, "<!DOCTYPE html><html><body>#{refresh}</body></html>")
      a = attach(path, 'application/zip')
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success
      assert_match(/\Asandbox; /, csp)
      assert_includes response.body, refresh, 'Pass caches the uploaded HTML'

      etag = response.headers['ETag']
      assert etag.present?, 'cached previews are served with an ETag'

      Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS # Pass disabled: the extension now selects Zippy
      Setting.clear_cache
      # a conditional request must not be answered 304 from the Pass cache: the
      # browser would keep the Pass body and apply the new (allow-downloads) headers
      @request.headers['If-None-Match'] = etag
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_not_equal 304, response.status, 'the old ETag must not validate once another converter is selected'
      assert_not_includes response.body.to_s, refresh, 'the Pass output must not be served as a Zippy preview'
    end
  end

  # the cache directory also holds extracted assets: an asset request must not
  # leave another converter's index behind and then mark it as this converter's
  def test_asset_request_discards_another_converters_cached_preview
    Dir.mktmpdir do |dir|
      a = attach(build_zip(File.join(dir, 'a.zip'), 'file.txt' => 'x'), 'application/zip')
      # what an earlier Pass rendering of the same attachment would have left
      refresh = '<meta http-equiv="refresh" content="0;url=/attachments/download/1/x.bin">'
      cache_dir = a.preview_dirname(format: 'html')
      FileUtils.mkdir_p(cache_dir)
      File.write(File.join(cache_dir, 'index.html'), "<html><body>#{refresh}</body></html>")
      File.write("#{cache_dir}.converter", 'pass')

      get :more_preview, params: {id: a.id, format: 'html', asset: 'file.txt'}
      assert_response :success
      assert_equal 'x', response.body

      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success
      assert_not_includes response.body.to_s, refresh, 'the foreign index must not survive the asset conversion'
      assert_includes response.body.to_s, 'file.txt', 'the listing is rendered by Zippy'
    end
  end

  def test_other_html_previews_stay_fully_sandboxed
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'page.html')
      File.write(path, '<html><body><meta http-equiv="refresh" content="0;url=/attachments/download/1/x.bin"></body></html>')
      a = attach(path, 'text/html')
      assert a.preview_convertible?, 'pass converter must handle .html for this test'
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success
      assert_match(/\Asandbox; /, csp)
      get :show, params: {id: a.id, filename: a.filename, format: 'html'}
      assert_select 'iframe[sandbox=""]'
    end
  end
end
