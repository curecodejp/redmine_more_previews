# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# A listing shown inline is part of the page of the attachment: its links must
# lead to the preview of the attachment, which serves the entries, and not to
# the page, which does not.
class ZippyInlineLinksTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests AttachmentsController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :issues, :trackers, :issue_statuses, :enumerations,
           :projects_trackers, :attachments

  ENTRIES = {
    'f.txt'          => 'entry',
    'Makefile'       => 'all: f',
    'dir/nested.txt' => 'nested',
    'a b&c+d.txt'    => 'encoded'
  }.freeze

  def setup
    set_tmp_attachments_directory
    @old_settings = Setting.plugin_redmine_more_previews
    use_format('inline')
    EnabledModule.create!(project_id: 1, name: 'redmine_more_previews')
    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @dir = Dir.mktmpdir('rmp-inline-links')
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

  def test_the_links_of_an_inline_listing_give_the_entries
    a = attach_zip
    get :show, params: {id: a.id}
    assert_response :success
    links = entry_links
    assert_equal ENTRIES.keys.map { |name| File.basename(name) }.sort, links.keys.sort

    ENTRIES.each do |name, content|
      href = links[File.basename(name)]
      assert_match %r{\A/attachments/more_preview/#{a.id}\?asset=}, href, name
      query = Rack::Utils.parse_query(URI(href).query)
      assert_equal({'asset' => name}, query, name)
      get :more_preview, params: {id: a.id, asset: query['asset']}
      assert_response :success, name
      assert_equal content, response.body, name
      assert_match /\Aattachment/, response.headers['Content-Disposition'], name
    end
  end

  # the listing is cached: its links do not depend on the URL of the page that
  # converted it first
  def test_the_links_do_not_depend_on_the_page
    a = attach_zip
    get :show, params: {id: a.id, filename: a.filename, format: 'html'}
    assert_response :success
    assert_equal "/attachments/more_preview/#{a.id}?asset=f.txt", entry_links['f.txt']
  end

  def test_the_links_honour_a_sub_uri
    a = attach_zip
    @request.env['SCRIPT_NAME'] = '/redmine'
    get :show, params: {id: a.id}
    assert_response :success
    assert_match %r{\A/redmine/attachments/more_preview/#{a.id}\?asset=f\.txt\z}, entry_links['f.txt']
  end

  # a listing in a frame of its own (html) linked to its own URL, as before
  def test_the_links_of_a_listing_in_a_frame_give_the_entries
    use_format('html')
    a = attach_zip
    get :more_preview, params: {id: a.id, format: 'html'}
    assert_response :success
    href = entry_links['f.txt']
    assert_match %r{\A/attachments/more_preview/#{a.id}(\.html)?\?asset=f\.txt\z}, href
    get :more_preview, params: {id: a.id, asset: 'f.txt'}
    assert_response :success
    assert_equal 'entry', response.body
  end

  # a listing cached by 6.1.9 or earlier, with the links to the page, is listed
  # again; the previews of the other converters keep their markers
  def test_a_listing_cached_before_is_listed_again
    a = attach_zip
    get :show, params: {id: a.id}
    assert_response :success
    index = a.preview_filepath
    File.write(index, %(<a download="f.txt" href="/attachments/#{a.id}?asset=f.txt">f.txt</a>))
    File.write("#{File.dirname(index)}.converter", "zippy:#{RedmineMorePreviews::Conversion::CACHE_FORMAT_VERSION}:normal")

    get :show, params: {id: a.id}
    assert_response :success
    assert_equal "/attachments/more_preview/#{a.id}?asset=f.txt", entry_links['f.txt']
    assert_equal RedmineMorePreviews::Conversion.cache_marker_for(:zippy), File.read("#{File.dirname(index)}.converter")
    assert_equal "teddie:#{RedmineMorePreviews::Conversion::CACHE_FORMAT_VERSION}:normal",
                 RedmineMorePreviews::Conversion.cache_marker_for(:teddie)
  end

  private

  def use_format(format)
    Setting.plugin_redmine_more_previews = {
      'embedding' => '0', 'cache_previews' => '1', 'debug' => '0', 'absolute' => '0',
      'converter' => {'zippy' => {'active' => '1', 'mime_types' => {
        'zip' => {'active' => '1', 'format' => format}}}}
    }
    Setting.clear_cache
  end

  def attach_zip
    path = build_zip(File.join(@dir, 'archive.zip'), ENTRIES)
    Attachment.create!(container: Issue.find(1), author: User.find(2),
                       file: Rack::Test::UploadedFile.new(path, 'application/zip', true))
  end

  # the links of the listing, by the name they show
  def entry_links
    Nokogiri::HTML(response.body).css('a[download]').to_h { |a| [a.text, a['href']] }
  end
end
