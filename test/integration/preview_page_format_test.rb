# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The page of a file asks for its preview in the configured format, whatever
# the query of the page: the URL it generates is followed here, as a browser
# follows it, and must reach the preview.
class PreviewPageFormatTest < Redmine::IntegrationTest
  include RedmineMorePreviews::TestHelper

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :repositories, :issues, :trackers, :issue_statuses,
           :enumerations, :projects_trackers

  PRJ_ID = 1

  def setup
    super
    set_tmp_attachments_directory
    @old_enabled_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = (@old_enabled_scm + ['Filesystem']).uniq
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = {'cache_previews' => '1', 'converter' => {
      'teddie' => {'active' => '1', 'mime_types' => {'txt' => {'active' => '1', 'format' => 'txt'}}}}}
    Setting.clear_cache
    %w(repository redmine_more_previews).each { |name| EnabledModule.find_or_create_by!(project_id: PRJ_ID, name: name) }
    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @dir = Dir.mktmpdir('rmp-page-format')
    File.binwrite(File.join(@dir, 'notes.txt'), "plain text\n")
    log_user('admin', 'admin')
  end

  def teardown
    super
    Setting.enabled_scm = @old_enabled_scm
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@dir)
  end

  def test_attachment_page_with_a_format_in_its_query
    attachment = Attachment.create!(container: Issue.find(1), author: User.find(1),
                                    file: Rack::Test::UploadedFile.new(File.join(@dir, 'notes.txt'), 'text/plain', true))
    ["/attachments/#{attachment.id}", "/attachments/#{attachment.id}?format=html"].each do |page|
      get page
      assert_response :success, page
      follow_preview_url(page)
    end
  end

  def test_repository_page_with_a_format_in_its_query
    Repository.where(project_id: PRJ_ID).delete_all
    repository = Repository::Filesystem.create!(project: Project.find(PRJ_ID), url: @dir, path_encoding: '', identifier: 'notes')
    base = "/projects/#{Project.find(PRJ_ID).identifier}/repository/#{repository.identifier_param}/entry/notes.txt"
    [base, "#{base}?format=html"].each do |page|
      get page
      assert_response :success, page
      follow_preview_url(page)
    end
  end

  # the URL of the preview is built by the page: of the query of the page it
  # takes over reload and unsafe only, not an option of url_for or a part of
  # the route
  QUERY = 'only_path=0&host=elsewhere.example&protocol=ftp&port=81&path=other.txt' \
          '&id=2&repository_id=other&controller=x&action=y&shell_api=posix_spawn&reload=1'

  def test_attachment_page_takes_over_reload_only
    attachment = Attachment.create!(container: Issue.find(1), author: User.find(1),
                                    file: Rack::Test::UploadedFile.new(File.join(@dir, 'notes.txt'), 'text/plain', true))
    get "/attachments/#{attachment.id}?#{QUERY}"
    assert_response :success
    assert_equal "/attachments/more_preview/#{attachment.id}.txt?reload=1", preview_url
  end

  def test_repository_page_takes_over_reload_only
    Repository.where(project_id: PRJ_ID).delete_all
    repository = Repository::Filesystem.create!(project: Project.find(PRJ_ID), url: @dir, path_encoding: '', identifier: 'notes')
    File.binwrite(File.join(@dir, 'other.txt'), "other\n")
    project = Project.find(PRJ_ID).identifier
    get "/projects/#{project}/repository/notes/entry/notes.txt?#{QUERY}"
    assert_response :success
    assert_equal "/projects/#{project}/repository/notes/preview/notes.txt@/index.txt?reload=1", preview_url
  end

  # an inline preview is converted while the page is rendered: nothing of the
  # query but reload reaches the converter
  def test_inline_preview_takes_no_options_from_the_query
    Setting.plugin_redmine_more_previews = {'cache_previews' => '1', 'converter' => {
      'teddie' => {'active' => '1', 'mime_types' => {'txt' => {'active' => '1', 'format' => 'inline'}}}}}
    Setting.clear_cache
    attachment = Attachment.create!(container: Issue.find(1), author: User.find(1),
                                    file: Rack::Test::UploadedFile.new(File.join(@dir, 'notes.txt'), 'text/plain', true))
    options = []
    RedmineMorePreviews::Converter.stubs(:convert).with { |_file, _path, opts| options << opts }.returns(nil)
    get "/attachments/#{attachment.id}?#{QUERY}"
    assert_response :success
    assert_equal 1, options.size
    assert_equal %i(converter format object preview_format reload request), options.first.keys.sort
    assert_equal 'inline', options.first[:format]
    assert_equal true, options.first[:reload]
  end

  private

  def preview_url
    url = response.body[/(?:src|data)="([^"]*(?:more_preview|@\/index)[^"]*)"/, 1]
    assert url, 'no preview URL in the page'
    CGI.unescapeHTML(url)
  end

  # the URL of the preview in the page, requested as the frame requests it
  def follow_preview_url(page)
    url = response.body[/(?:src|data)="([^"]*(?:more_preview|@\/index)[^"]*)"/, 1]
    assert url, "#{page}: no preview URL in the page"
    assert_not_includes url, 'format=', "#{page}: the format of the page is not forwarded"
    get CGI.unescapeHTML(url)
    assert_response :success, "#{page} -> #{url}"
    assert_equal 'text/plain', response.media_type, url
    assert_equal "plain text\n", response.body, url
  end
end
