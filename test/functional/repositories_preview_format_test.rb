# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# As PreviewFormatSelectionTest, for repository entries: the converter and the
# format are decided on the bytes of the entry, and a request for another
# format is answered with 404 before anything is converted or stored.
class RepositoriesPreviewFormatTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests RepositoriesController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :repositories

  PRJ_ID = 3
  SETTINGS = {
    'embedding' => '0', 'cache_previews' => '1', 'debug' => '0', 'absolute' => '0',
    'converter' => {
      'zippy'  => {'active' => '1', 'mime_types' => {
        'zip' => {'active' => '1', 'format' => 'html'},
        'tar' => {'active' => '1', 'format' => 'html'}}},
      'teddie' => {'active' => '1', 'mime_types' => {'txt' => {'active' => '1', 'format' => 'txt'}}},
      'pass'   => {'active' => '1', 'mime_types' => {'html' => {'active' => '1', 'format' => 'html'}}}
    }
  }.freeze

  HTML = '<!DOCTYPE html><html><body><p id="marker">html in a text file</p></body></html>'
  MAIL = "Message-ID: <1@example.test>\r\nFrom: a@example.test\r\nTo: b@example.test\r\n" \
         "Subject: a mail saved as text\r\nMIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\nthe body\r\n"

  def setup
    super
    User.current = nil
    @old_enabled_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = @old_enabled_scm + ['Filesystem'] unless @old_enabled_scm.include?('Filesystem')
    @old_settings = Setting.plugin_redmine_more_previews
    use_settings(SETTINGS)
    EnabledModule.create!(project_id: PRJ_ID, name: 'redmine_more_previews')

    @repo_dir = Dir.mktmpdir('rmp-fs-repo')
    build_zip(File.join(@repo_dir, 'a.zip'), 'f.txt' => 'entry')
    build_zip(File.join(@repo_dir, 'archive.txt'), 'f.txt' => 'entry')
    File.binwrite(File.join(@repo_dir, 'page.txt'), HTML)
    File.binwrite(File.join(@repo_dir, 'notes.txt'), "plain text\n")
    File.binwrite(File.join(@repo_dir, 'mail.txt'), MAIL)
    @repository = Repository::Filesystem.create!(project: Project.find(PRJ_ID), url: @repo_dir, path_encoding: '')

    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @request.session[:user_id] = 2 # jsmith, a member (manager) of the project's parent tree
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

  OTHER_FORMATS = %w(txt pdf png gif xml jpeg).freeze

  def test_another_format_is_not_converted_or_stored
    Zippy.any_instance.expects(:convert).never
    OTHER_FORMATS.each do |format|
      get :more_preview, params: entry_params('a.zip', format: format)
      assert_response :not_found, format
    end
    assert_empty stored, 'no directory, lock or remembered failure'
  end

  def test_another_format_is_not_converted_without_the_cache
    use_settings(SETTINGS.merge('cache_previews' => '0'))
    Zippy.any_instance.expects(:convert).never
    OTHER_FORMATS.each do |format|
      get :more_preview, params: entry_params('a.zip', format: format)
      assert_response :not_found, format
    end
    assert_empty stored
  end

  def test_the_configured_format_is_served_and_stored_under_its_name
    get :more_preview, params: entry_params('a.zip', format: 'html')
    assert_response :success
    assert_select 'a', text: 'f.txt'
    assert_equal ['preview.html'], preview_directories
  end

  # the page asks for the format the conversion gives: both are decided on the
  # content of the entry, which was the extension for the page
  def test_html_content_in_a_text_file_is_previewed_as_html
    get :entry, params: entry_params('page.txt', format: 'html')
    assert_response :success
    assert_select 'iframe[src$=?]', '/preview/page.txt@/index.html'

    get :more_preview, params: entry_params('page.txt', format: 'html')
    assert_response :success
    assert_includes response.body, 'html in a text file'
    assert_includes response.headers['Content-Security-Policy'].to_s, 'sandbox'
    assert_equal ['preview.html'], preview_directories

    Pass.any_instance.expects(:convert).never
    get :more_preview, params: entry_params('page.txt', format: 'txt')
    assert_response :not_found
  end

  def test_a_zip_archive_under_another_name_is_listed
    get :more_preview, params: entry_params('archive.txt', format: 'html')
    assert_response :success
    assert_select 'a', text: 'f.txt'
  end

  def test_a_plain_text_file_is_still_previewed_as_text
    get :entry, params: entry_params('notes.txt', format: 'html')
    assert_response :success
    assert_select '[src$=?], [data$=?]', '/preview/notes.txt@/index.txt', '/preview/notes.txt@/index.txt'

    get :more_preview, params: entry_params('notes.txt', format: 'txt')
    assert_response :success
    assert_equal "plain text\n", response.body
  end

  # an email whose content tells that it is one is converted by Cliff under a
  # text name as well: the page shows its header boxes and asks for html
  def test_an_email_in_a_text_file_is_previewed_by_cliff
    settings = SETTINGS.deep_dup
    settings['converter']['cliff'] = {'active' => '1', 'mime_types' => {'eml' => {'active' => '1', 'format' => 'html'}}}
    use_settings(settings)
    assert_equal 'message/rfc822', Marcel::MimeType.for(StringIO.new(MAIL), name: 'mail.txt')

    # the subject is in the header box of the page: the body is in the frame
    get :entry, params: entry_params('mail.txt', format: 'html')
    assert_response :success
    assert_select 'iframe[src$=?]', '/preview/mail.txt@/index.html'
    assert_includes response.body, 'a mail saved as text'

    get :more_preview, params: entry_params('mail.txt', format: 'html')
    assert_response :success
    assert_includes response.body, 'the body'
  end

  # an entry the SCM gives no content for is decided as the empty file it is
  # converted as: by its name, never on a file of that name on the server
  def test_an_entry_without_content_is_decided_by_its_name
    Repository::Filesystem.any_instance.stubs(:cat).returns(nil)
    Dir.chdir(@repo_dir) do # a file named page.txt lies in the working directory
      get :entry, params: entry_params('page.txt', format: 'html')
      assert_response :success
      assert_select '[src$=?], [data$=?]', '/preview/page.txt@/index.txt', '/preview/page.txt@/index.txt'

      get :more_preview, params: entry_params('page.txt', format: 'txt')
      assert_includes [200, 404], response.status
      get :more_preview, params: entry_params('a.zip', format: 'html')
      assert_response :not_found
    end
  end

  # the page reads the entry once: for the format, the download decision and
  # the name of the cache directory
  def test_the_entry_page_reads_the_entry_once
    bytes = File.binread(File.join(@repo_dir, 'page.txt'))
    Repository::Filesystem.any_instance.expects(:cat).once.returns(bytes)
    get :entry, params: entry_params('page.txt', format: 'html')
    assert_response :success
  end

  private

  def use_settings(settings)
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
  end

  def entry_params(name, extra = {})
    {id: PRJ_ID, repository_id: @repository.id, path: repository_path_hash([name])[:param]}.merge(extra)
  end

  def stored
    Dir.glob(File.join(@storage, '**', '*'), File::FNM_DOTMATCH).reject { |f| File.directory?(f) }
  end

  def preview_directories
    Dir.glob(File.join(@storage, '**', 'preview.*')).select { |f| File.directory?(f) }.map { |f| File.basename(f) }.sort
  end
end
