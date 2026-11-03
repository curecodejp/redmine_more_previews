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

  def test_oversized_cached_fragment_stays_local_to_attachment_preview
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    fields_path = @attachment.preview_assetpath(asset: 'fields.html')
    File.binwrite(fields_path, 'x' * (RedmineMorePreviews::Patches::ApplicationHelperPatch::MAX_INLINE_PREVIEW_HTML_BYTES + 1))

    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_equal 1, response.body.scan(I18n.t(:text_more_previews_inline_too_large)).length
    assert_includes response.body, 'cached-mail-subject'
    assert_select 'iframe[src*="more_preview"]'
    assert_select 'a[href*="download"]'

    get :more_asset, params: {id: @attachment.id, asset: 'fields', assetformat: 'html'}
    assert_response 413
  end

  # A fragment cached (and fetched) before the limit existed keeps its file
  # and mtime, hence its ETag: a browser revalidating it must still get 413.
  def test_conditional_get_of_an_oversized_cached_fragment_answers_413
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    fields_path = @attachment.preview_assetpath(asset: 'fields.html')
    mtime = File.mtime(fields_path)

    get :more_asset, params: {id: @attachment.id, asset: 'fields', assetformat: 'html'}
    assert_response :success
    etag = response.headers['ETag']
    assert etag.present?

    File.binwrite(fields_path, 'x' * (RedmineMorePreviews::Patches::ApplicationHelperPatch::MAX_INLINE_PREVIEW_HTML_BYTES + 1))
    File.utime(mtime, mtime, fields_path)
    @request.if_none_match = etag
    get :more_asset, params: {id: @attachment.id, asset: 'fields', assetformat: 'html'}
    assert_response 413
  end

  def test_conditional_get_of_a_regular_fragment_stays_not_modified
    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    get :more_asset, params: {id: @attachment.id, asset: 'fields', assetformat: 'html'}
    assert_response :success

    @request.if_none_match = response.headers['ETag']
    get :more_asset, params: {id: @attachment.id, asset: 'fields', assetformat: 'html'}
    assert_response :not_modified
  end

  def test_transient_fragment_marker_stays_local_to_attachment_preview
    settings = Setting.plugin_redmine_more_previews.deep_dup
    settings['cache_previews'] = '0'
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    marker = RedmineMorePreviews::Conversion::CLIFF_FRAGMENT_TOO_LARGE
    Attachment.any_instance.stubs(:more_asset).with(has_entries(assets: %w[headers.html fields.html attachments.html])).returns(
      ['<p>header visible</p>', marker, '<p>attachments visible</p>']
    )

    get :show, params: {id: @attachment.id, filename: @attachment.filename, format: 'html'}
    assert_response :success
    assert_equal 1, response.body.scan(I18n.t(:text_more_previews_inline_too_large)).length
    assert_includes response.body, 'header visible'
    assert_includes response.body, 'attachments visible'
    assert_select 'iframe[src*="more_preview"]'
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

  WITH_ATTACHMENT = "From: writer@example.test\r\nTo: reader@example.test\r\nSubject: slot-mail-subject\r\n" \
                    "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n" \
                    "--b\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nslot mail body\r\n" \
                    "--b\r\nContent-Type: text/plain; name=slot-attached.txt\r\n" \
                    "Content-Disposition: attachment; filename=slot-attached.txt\r\n\r\nattached\r\n--b--\r\n"

  # The transient conversion yields the body, the (absent) asset and then the
  # three fragments; each must land in its own box, as with a cached preview.
  def test_transient_fragments_keep_their_boxes
    settings = Setting.plugin_redmine_more_previews.deep_dup
    settings['cache_previews'] = '0'
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    attachment = upload_mail('slot.eml', WITH_ATTACHMENT)

    get :show, params: {id: attachment.id, filename: attachment.filename, format: 'html'}
    assert_response :success
    assert_fragment_boxes 'slot-attached.txt'
  end

  def test_cached_fragments_keep_their_boxes
    attachment = upload_mail('slot.eml', WITH_ATTACHMENT)

    get :show, params: {id: attachment.id, filename: attachment.filename, format: 'html'}
    assert_response :success
    assert_fragment_boxes 'slot-attached.txt'
  end

  # An email beyond the Cliff limits answers 413 in the body iframe only; the
  # attachment page itself stays, with its download link and a notice.
  # More MIME parts than Cliff's default max_parts (1,000).
  MANY_PARTS = "From: writer@example.test\r\nSubject: many parts\r\nMIME-Version: 1.0\r\n" \
               "Content-Type: multipart/mixed; boundary=b\r\n\r\n" +
               (1..1100).map { |i| "--b\r\nContent-Type: text/plain\r\n\r\npart #{i}\r\n" }.join +
               "--b--\r\n"

  def test_email_beyond_limits_keeps_the_attachment_page
    attachment = upload_mail('many-parts.eml', MANY_PARTS)

    2.times do # converted the first time, a remembered failure the second
      get :show, params: {id: attachment.id, filename: attachment.filename, format: 'html'}
      assert_response :success
      assert_equal 1, response.body.scan(I18n.t(:text_more_previews_inline_too_large)).length
      assert_select 'a[href*="download"]'
      assert_select 'iframe[src*="more_preview"]'
    end
  end

  # The transient branch (cache disabled, admin reload, other locale) gets the
  # limit from the conversion child rather than from a stored failure.
  def test_email_beyond_limits_keeps_the_attachment_page_without_cache
    settings = Setting.plugin_redmine_more_previews.deep_dup
    settings['cache_previews'] = '0'
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    attachment = upload_mail('many-parts.eml', MANY_PARTS)

    get :show, params: {id: attachment.id, filename: attachment.filename, format: 'html'}
    assert_response :success
    assert_equal 1, response.body.scan(I18n.t(:text_more_previews_inline_too_large)).length
    assert_select 'a[href*="download"]'
    assert_select 'iframe[src*="more_preview"]'
    assert_not File.file?(attachment.preview_filepath)
  end

  private

  def upload_mail(name, source)
    path = File.join(@tmp, name)
    File.binwrite(path, source)
    upload = Rack::Test::UploadedFile.new(path, 'message/rfc822', true)
    attachment = Attachment.new(container: Issue.find(1), file: upload, author: User.find(2))
    assert attachment.save
    attachment
  end

  def assert_fragment_boxes(attached_name)
    boxes = css_select('#preview_repository_entry_top div.box')
    assert_equal 3, boxes.size, response.body
    headers, fields, attachments = boxes
    assert headers.at_css('table.white'), 'headers.html belongs in the first box'
    assert_nil headers['id']
    assert fields.at_css('table.email.header_fields'), 'fields.html belongs in the collapsed box'
    assert_match(/display:\s*none/, fields['style'].to_s)
    assert_nil attachments.at_css('table.white')
    assert_nil attachments.at_css('table.email.header_fields')
    assert_includes attachments.text, attached_name
  end
end
