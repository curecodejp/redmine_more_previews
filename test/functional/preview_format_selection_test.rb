# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The output format of a preview is the one configured for the converter that
# converts the file, chosen by the file's content as the conversion chooses it.
# A request names the format only to be compared with it: a request for another
# format is answered with 404 before anything is converted or stored.
class PreviewFormatSelectionTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests AttachmentsController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :issues, :trackers, :issue_statuses, :enumerations,
           :projects_trackers, :attachments

  SETTINGS = {
    'embedding' => '0', 'cache_previews' => '1', 'debug' => '0', 'absolute' => '0',
    'converter' => {
      'zippy'  => {'active' => '1', 'mime_types' => {
        'zip' => {'active' => '1', 'format' => 'html'},
        'tar' => {'active' => '1', 'format' => 'html'},
        'tgz' => {'active' => '1', 'format' => 'html'}}},
      'teddie' => {'active' => '1', 'mime_types' => {'txt' => {'active' => '1', 'format' => 'txt'}}},
      'pass'   => {'active' => '1', 'mime_types' => {'html' => {'active' => '1', 'format' => 'html'}}}
    }
  }.freeze

  HTML = '<!DOCTYPE html><html><body><p id="marker">html in a text file</p></body></html>'

  def setup
    set_tmp_attachments_directory
    @old_settings = Setting.plugin_redmine_more_previews
    use_settings(SETTINGS)
    EnabledModule.create!(project_id: 1, name: 'redmine_more_previews')
    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @dir = Dir.mktmpdir('rmp-format')
    @request.session[:user_id] = 2 # jsmith, member of project 1
  end

  def teardown
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@dir)
  end

  # --- a format that is not the configured one ----------------------------------------

  OTHER_FORMATS = %w(txt pdf png gif xml jpeg).freeze

  def test_another_format_is_not_converted_or_stored
    a = attach_zip
    Zippy.any_instance.expects(:convert).never
    OTHER_FORMATS.each do |format|
      get :more_preview, params: {id: a.id, format: format}
      assert_response :not_found, format
    end
    assert_empty stored, 'no directory, lock or remembered failure'
  end

  def test_another_format_is_not_converted_without_the_cache
    use_settings(SETTINGS.merge('cache_previews' => '0'))
    a = attach_zip
    Zippy.any_instance.expects(:convert).never
    OTHER_FORMATS.each do |format|
      get :more_preview, params: {id: a.id, format: format}
      assert_response :not_found, format
    end
    assert_empty stored
  end

  def test_another_format_is_not_converted_for_an_unsafe_request_of_an_administrator
    @request.session[:user_id] = 1
    a = attach_zip
    Zippy.any_instance.expects(:convert).never
    OTHER_FORMATS.each do |format|
      get :more_preview, params: {id: a.id, format: format, unsafe: '1'}
      assert_response :not_found, format
    end
    assert_empty stored
  end

  def test_the_configured_format_is_served_and_stored_under_its_name
    a = attach_zip
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :success
    assert_select 'a', text: 'f.txt'
    assert_equal ['preview.html'], preview_directories(a)
  end

  # the page of an inline preview converts with the format "inline"; a request
  # for the html of that file is one for another format
  def test_html_of_an_inline_preview_is_another_format
    settings = SETTINGS.deep_dup
    settings['converter']['zippy']['mime_types']['zip']['format'] = 'inline'
    use_settings(settings)
    a = attach_zip
    get :show, params: {id: a.id}
    assert_response :success
    assert_select 'a', text: 'f.txt'
    assert_equal ['preview.inline'], preview_directories(a)

    Zippy.any_instance.expects(:convert).never
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :not_found
    assert_equal ['preview.inline'], preview_directories(a)
  end

  # --- content and extension that disagree --------------------------------------------

  # Pass converts a file of HTML content, whatever its name: the format is the
  # one configured for html, not the one of the extension (txt)
  def test_html_content_in_a_text_file_is_previewed_as_html
    a = attach(write('page.txt', HTML), 'text/plain')
    assert_equal 'text/html', Marcel::MimeType.for(Pathname.new(a.diskfile), name: a.filename)

    get :show, params: {id: a.id}
    assert_response :success
    assert_select 'iframe[src=?]', "/attachments/more_preview/#{a.id}.html"

    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :success
    assert_includes response.body, 'html in a text file'
    assert_includes response.headers['Content-Security-Policy'].to_s, 'sandbox'
    assert_equal ['preview.html'], preview_directories(a)

    # the format of the extension is not the format of this file
    Pass.any_instance.expects(:convert).never
    get :more_preview, params: {id: a.id, format: 'txt'}
    assert_response :not_found
  end

  # an email whose content tells that it is one is converted by Cliff under a
  # text name as well: the page shows its header boxes and asks for html
  def test_an_email_in_a_text_file_is_previewed_by_cliff
    settings = SETTINGS.deep_dup
    settings['converter']['cliff'] = {'active' => '1', 'mime_types' => {'eml' => {'active' => '1', 'format' => 'html'}}}
    use_settings(settings)
    mail = "Message-ID: <1@example.test>\r\nFrom: a@example.test\r\nTo: b@example.test\r\n" \
           "Subject: a mail saved as text\r\nMIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\nthe body\r\n"
    a = attach(write('mail.txt', mail), 'text/plain')
    assert_equal 'message/rfc822', Marcel::MimeType.for(Pathname.new(a.diskfile), name: a.filename)

    # the subject is in the header box of the page: the body is in the frame
    get :show, params: {id: a.id}
    assert_response :success
    assert_select 'iframe[src=?]', "/attachments/more_preview/#{a.id}.html"
    assert_includes response.body, 'a mail saved as text'

    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :success
    assert_includes response.body, 'the body'

    # a header fragment beyond its limit is one of Cliff's under this name too
    File.binwrite(a.preview_assetpath(asset: 'fields.html'),
                  'x' * (RedmineMorePreviews::Patches::ApplicationHelperPatch::MAX_INLINE_PREVIEW_HTML_BYTES + 1))
    get :more_asset, params: {id: a.id, asset: 'fields', assetformat: 'html'}
    assert_response 413

    Cliff.any_instance.expects(:convert).never
    get :more_preview, params: {id: a.id, format: 'txt'}
    assert_response :not_found
  end

  # Zippy converts a zip archive, whatever its name: it lists it as a zip
  # archive, not by the extension of the name
  def test_a_zip_archive_under_another_name_is_listed
    {'archive.txt' => 'text/plain', 'archive.tar' => 'application/x-tar'}.each do |name, type|
      a = attach(build_zip(File.join(@dir, name), 'f.txt' => 'entry'), type)
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success, name
      assert_select 'a', {text: 'f.txt'}, name
      assert_equal ['preview.html'], preview_directories(a), name
    end
  end

  # an archive is listed as what it is where its content tells: Zippy is chosen
  # by the extension here (tar and gzip have other type names in its settings)
  def test_tar_and_tgz_archives_under_each_others_name_are_listed
    tar = attach(build_tgz(File.join(@dir, 'gz.tar'), 'f.txt' => 'entry'), 'application/x-tar')
    tgz = attach(build_tar(File.join(@dir, 'plain.tgz'), 'f.txt' => 'entry'), 'application/gzip')
    [tar, tgz].each do |a|
      get :more_preview, params: {id: a.id, format: 'html'}
      assert_response :success, a.filename
      assert_select 'a', {text: 'f.txt'}, a.filename
    end
  end

  # `tar cf` writes the GNU format, which Marcel names application/x-gtar
  def test_a_gnu_tar_archive_under_another_name_is_listed
    File.binwrite(File.join(@dir, 'f.txt'), 'entry')
    path = File.join(@dir, 'gnu.tgz')
    skip 'tar is not installed' unless system('tar', '-C', @dir, '-cf', path, 'f.txt', err: File::NULL)
    assert_equal 'application/x-gtar', Marcel::MimeType.for(Pathname.new(path), name: 'gnu.tgz')
    a = attach(path, 'application/gzip')
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :success
    assert_select 'a', text: 'f.txt'
  end

  # a kind of archive that is turned off is not listed under the name of another
  def test_an_archive_of_a_kind_turned_off_is_not_listed_under_another_name
    settings = SETTINGS.deep_dup
    settings['converter']['zippy']['mime_types']['zip']['active'] = '0'
    use_settings(settings)
    a = attach(build_zip(File.join(@dir, 'archive.tar'), 'f.txt' => 'entry'), 'application/x-tar')
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :not_found
  end

  # --- requests that name no format -----------------------------------------------------

  # a request without a format is one for the configured format: it is stored
  # where the request with the format is
  def test_a_request_without_a_format_is_served_from_the_same_directory
    a = attach_zip
    get :more_preview, params: {id: a.id}
    assert_response :success
    assert_select 'a', text: 'f.txt'
    assert_equal ['preview.html'], preview_directories(a)
    # as before: under the sandbox of an HTML preview, with no type of its own
    assert_equal 'application/octet-stream', response.media_type
    assert_includes response.headers['Content-Security-Policy'].to_s, 'sandbox'
    assert_equal 'nosniff', response.headers['X-Content-Type-Options']

    Zippy.any_instance.expects(:convert).never
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :success
    assert_equal ['preview.html'], preview_directories(a)
  end

  def test_routes_with_a_format_reach_the_check
    assert_routing '/attachments/more_preview/5.png', controller: 'attachments', action: 'more_preview', id: '5', format: 'png'
    assert_recognizes({controller: 'attachments', action: 'more_preview', id: '5', format: 'png'}, '/attachments/more_preview/5/index.png')
  end

  # --- images -------------------------------------------------------------------------

  # the page asks for the format as it is configured ("jpg"), and only that
  # name is the configured format
  def test_an_image_is_served_in_the_configured_format_only
    skip 'ImageMagick reads no TIFF' unless RedmineMorePreviews.imagemagick_reads?('TIFF')
    settings = SETTINGS.deep_dup
    settings['converter']['maggie'] = {'active' => '1', 'mime_types' => {'tif' => {'active' => '1', 'format' => 'jpg'}}}
    use_settings(settings)
    fixture = File.expand_path('../fixtures/maggie/rotated.tif', __dir__)
    a = attach(write('photo.tif', File.binread(fixture)), 'image/tiff')

    get :show, params: {id: a.id}
    assert_response :success
    assert_select 'img[src=?]', "/attachments/more_preview/#{a.id}.jpg"

    get :more_preview, params: {id: a.id, format: 'jpg'}
    assert_response :success
    assert_equal 'image/jpeg', response.media_type
    assert_equal "\xFF\xD8".b, response.body.b[0, 2]

    Maggie.any_instance.expects(:convert).never
    %w(jpeg png html).each do |format|
      get :more_preview, params: {id: a.id, format: format}
      assert_response :not_found, format
    end
    assert_equal ['preview.jpg'], preview_directories(a)
  end

  # --- Mark ---------------------------------------------------------------------------

  # Mark took the format of the request, where every other converter takes the
  # configured one: converted here with the real pandoc
  def test_mark_converts_to_the_configured_format
    skip 'pandoc is not installed' unless pandoc?
    settings = SETTINGS.deep_dup
    settings['converter']['mark'] = {'active' => '1', 'mime_types' => {'md' => {'active' => '1', 'format' => 'html'}}}
    use_settings(settings)
    a = attach(write('notes.md', "# A heading\n\nsome *text*\n"), 'text/markdown')

    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :success
    assert_select 'h1', text: 'A heading'
    assert_select 'em', text: 'text'
    assert_includes response.body, '<base href='

    Mark.any_instance.expects(:convert).never
    get :more_preview, params: {id: a.id, format: 'txt'}
    assert_response :not_found
    assert_equal ['preview.html'], preview_directories(a)
  end

  def test_mark_converts_inline_in_the_page
    skip 'pandoc is not installed' unless pandoc?
    settings = SETTINGS.deep_dup
    settings['converter']['mark'] = {'active' => '1', 'mime_types' => {'md' => {'active' => '1', 'format' => 'inline'}}}
    use_settings(settings)
    a = attach(write('notes.md', "# A heading\n\nsome *text*\n"), 'text/markdown')

    get :show, params: {id: a.id}
    assert_response :success
    assert_select 'h1', text: 'A heading'
    assert_equal ['preview.inline'], preview_directories(a)
  end

  def test_a_plain_text_file_is_still_previewed_as_text
    a = attach(write('notes.txt', "plain text\n"), 'text/plain')
    get :more_preview, params: {id: a.id, format: 'txt'}
    assert_response :success
    assert_equal "plain text\n", response.body
    Teddie.any_instance.expects(:convert).never
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :not_found
  end

  private

  def pandoc?
    system(Mark::PANDOC_BIN, '--version', out: File::NULL, err: File::NULL)
  rescue SystemCallError
    false
  end

  def use_settings(settings)
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
  end

  def write(name, content)
    path = File.join(@dir, name)
    File.binwrite(path, content)
    path
  end

  def attach_zip
    attach(build_zip(File.join(@dir, 'a.zip'), 'f.txt' => 'entry'), 'application/zip')
  end

  def attach(path, type)
    a = Attachment.new(container: Issue.find(1), author: User.find(2),
                       file: Rack::Test::UploadedFile.new(path, type, true))
    assert a.save
    a
  end

  # everything below the storage path: preview directories, locks, failures
  def stored
    Dir.glob(File.join(@storage, '**', '*'), File::FNM_DOTMATCH).reject { |f| File.directory?(f) }
  end

  def preview_directories(attachment)
    Dir.children(attachment.preview_storagepath).select { |name| File.directory?(File.join(attachment.preview_storagepath, name)) }.sort
  end
end
