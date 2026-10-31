# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'mail'
require 'nokogiri'

# An extensionless attachment once caused asset URL generation to raise while
# Cliff was rendering the list, and the whole email was cached as an error page.
class CliffAttachmentLinksTest < Redmine::ControllerTest
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
      'active' => '1', 'mime_types' => {'eml' => {'active' => '1', 'format' => 'html'}}
    }
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    EnabledModule.find_or_create_by!(project_id: 1, name: 'redmine_more_previews')
    @request.session[:user_id] = 2
    @upload_dir = Dir.mktmpdir('rmp-cliff-links')
    @storage = Dir.mktmpdir('rmp-cliff-links-cache')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
  end

  def teardown
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@upload_dir)
  end

  def test_extensionless_mail_attachment_does_not_break_or_poison_the_preview
    mail = Mail.new do
      from 'author@example.test'
      to 'reader@example.test'
      subject 'mail attachments'
      text_part { body 'attachment mail body survives' }
    end
    mail.add_file(filename: 'Makefile', content: 'all: test')
    mail.add_file(filename: 'notes.txt', content: 'attachment note')
    attachment = attach(mail.to_s)

    get :more_preview, params: {id: attachment.id, format: 'html'}
    assert_response :success
    assert_includes response.body, 'attachment mail body survives'

    # The first (not a second, warmed) conversion must link its newly extracted
    # .txt asset, while the extensionless name is still visible without a link.
    get :more_asset, params: {id: attachment.id, asset: 'attachments', assetformat: 'html'}
    assert_response :success
    document = Nokogiri::HTML.fragment(response.body)
    assert_includes document.text, 'Makefile'
    assert_not_includes document.css('a').map(&:text), 'Makefile'
    assert_includes document.css('a').map(&:text), 'notes.txt'

    get :more_asset, params: {id: attachment.id, asset: 'notes', assetformat: 'txt'}
    assert_response :success
    assert_equal 'attachment note', response.body

    get :more_preview, params: {id: attachment.id, format: 'html'}
    assert_response :success
    assert_includes response.body, 'attachment mail body survives'

    # No route generation is attempted for extensionless names, and a text
    # fallback must never embed arbitrary filename markup in the HTML.
    assert_equal 'README&lt;script&gt;', attachment.asset_link('README<script>', true)
  end

  private

  def attach(content)
    path = File.join(@upload_dir, 'attachments.eml')
    File.binwrite(path, content)
    upload = Rack::Test::UploadedFile.new(path, 'message/rfc822', true)
    attachment = Attachment.new(container: Issue.find(1), file: upload, author: User.find(2))
    assert attachment.save
    attachment
  end
end
