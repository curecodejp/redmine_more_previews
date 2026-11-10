# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'open3'

# The images of an email shown as an HTML preview. The preview is shown in a
# sandboxed frame: the browser sends no session cookie with the requests of its
# document, so an image it links to is refused in a project that is not public.
# The images are embedded instead. The routes are taken as a browser takes them,
# from the URL a link relative to the preview resolves to.
class HtmlPreviewImagesTest < Redmine::IntegrationTest
  include RedmineMorePreviews::TestHelper

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :repositories, :issues, :trackers, :issue_statuses,
           :enumerations, :projects_trackers

  PRJ_ID = 2 # not public
  PNG = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
  PNG_URI = "data:image/png;base64,#{Base64.strict_encode64(PNG)}"

  def setup
    super
    set_tmp_attachments_directory
    @old_enabled_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = (@old_enabled_scm + ['Git']).uniq
    @old_settings = Setting.plugin_redmine_more_previews
    settings = ZIPPY_SETTINGS.deep_dup
    settings['converter']['cliff'] = {
      'active' => '1', 'mime_types' => {'eml' => {'active' => '1', 'format' => 'html'}}
    }
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    %w(repository redmine_more_previews).each do |name|
      EnabledModule.find_or_create_by!(project_id: PRJ_ID, name: name)
    end

    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @dir = Dir.mktmpdir('rmp-git-repo')
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

  def test_attachment_preview_embeds_the_inline_image
    eml = File.join(@dir, 'mail.eml')
    File.binwrite(eml, EML)
    attachment = Attachment.create!(container: Issue.find(4), author: User.find(1),
                                    file: Rack::Test::UploadedFile.new(eml, 'message/rfc822', true))
    get "/attachments/more_preview/#{attachment.id}.html"
    assert_response :success
    assert_includes response.body, %(src="#{PNG_URI}")
    assert_not_includes response.body, 'src="image001.png"'
  end

  def test_repository_preview_embeds_the_inline_image_and_its_asset_route_serves_it
    repository = git_repository_with('mail.eml' => EML)
    base = "/projects/#{PRJ_ID}/repository/#{repository.id}/preview/mail.eml@"
    get "#{base}/index.html"
    assert_response :success
    assert_includes response.body, %(src="#{PNG_URI}")

    # a link relative to the preview resolves to ".../mail.eml@/image001.png":
    # the route takes "/image001" as the asset name
    get "#{base}/image001.png"
    assert_response :success
    assert_equal PNG, response.body.b
  end

  def test_repository_asset_route_still_refuses_unsafe_names
    repository = git_repository_with('mail.eml' => EML)
    base = "/projects/#{PRJ_ID}/repository/#{repository.id}/preview/mail.eml@"
    get "#{base}/index.html"
    assert_response :success
    get "#{base}//etc/hostname.png"
    assert_response :not_found
    get "#{base}/../../mail.png"
    assert_response :not_found
  end

  EML = <<~MAIL.gsub("\n", "\r\n")
    From: a@example.test
    To: b@example.test
    Subject: inline image
    MIME-Version: 1.0
    Content-Type: multipart/related; boundary="b1"

    --b1
    Content-Type: text/html; charset=UTF-8

    <html><body><p>body</p><img src="cid:img1@x"></body></html>
    --b1
    Content-Type: image/png; name="image001.png"
    Content-Transfer-Encoding: base64
    Content-ID: <img1@x>
    Content-Disposition: inline; filename="image001.png"

    #{Base64.encode64(PNG).strip}
    --b1--
  MAIL

  private

  def git_repository_with(files)
    git('init', '-q', '-b', 'master')
    files.each { |name, content| File.binwrite(File.join(@dir, name), content) }
    git('add', *files.keys)
    git('-c', 'user.name=test', '-c', 'user.email=test@example.net', 'commit', '-q', '-m', 'files')
    Repository::Git.create!(project: Project.find(PRJ_ID), url: File.join(@dir, '.git'),
                            path_encoding: '', identifier: 'mails')
  end

  def git(*args)
    out, status = Open3.capture2e('git', '-C', @dir, *args)
    assert status.success?, out
    out
  end
end
