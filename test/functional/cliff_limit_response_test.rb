# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Exercise the HTTP response: Cliff parses email in a child process, so a
# child-side limit exception must reach the controller as HTTP 413.
class CliffLimitResponseTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests AttachmentsController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :issues, :trackers, :issue_statuses, :enumerations,
           :projects_trackers, :attachments

  def setup
    set_tmp_attachments_directory
    @old_settings = Setting.plugin_redmine_more_previews
    settings = ZIPPY_SETTINGS.deep_dup
    settings['converter']['cliff'] = {
      'active' => '1',
      'max_size' => '1',
      'max_parts' => '1',
      'mime_types' => {'eml' => {'active' => '1', 'format' => 'html'}}
    }
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    EnabledModule.find_or_create_by!(project_id: 1, name: 'redmine_more_previews')
    @request.session[:user_id] = 2
    @dir = Dir.mktmpdir('rmp-cliff-http')
  end

  def teardown
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    FileUtils.rm_rf(@dir)
  end

  def test_mime_part_limit_is_returned_as_413_not_cached_as_html
    source = "Subject: big\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b\"\r\n\r\n" +
             "--b\r\nContent-Type: text/plain\r\n\r\nfirst\r\n" +
             "--b\r\nContent-Type: text/plain\r\n\r\nsecond\r\n--b--\r\n"
    attachment = attach(source, 'too-many.eml')

    get :more_preview, params: {id: attachment.id, format: 'html'}
    assert_response 413
    assert_not File.file?(attachment.preview_filepath(format: 'html'))

    # The recorded failed conversion must also be a 413 on repeat requests.
    get :more_preview, params: {id: attachment.id, format: 'html'}
    assert_response 413
  end

  def test_email_within_limits_is_still_previewed
    attachment = attach("From: a@example.test\r\nSubject: short\r\n\r\nhello\r\n", 'ok.eml')

    get :more_preview, params: {id: attachment.id, format: 'html'}
    assert_response :success
    assert_includes response.body, 'hello'
  end

  private

  def attach(content, name)
    path = File.join(@dir, name)
    File.binwrite(path, content)
    upload = Rack::Test::UploadedFile.new(path, 'message/rfc822', true)
    attachment = Attachment.new(container: Issue.find(1), file: upload, author: User.find(2))
    assert attachment.save
    attachment
  end
end
