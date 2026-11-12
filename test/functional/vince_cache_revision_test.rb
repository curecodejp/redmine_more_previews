# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Vince 1.1.4 reads and shows a contact otherwise (whole lines, groups, units,
# types): a preview stored by an earlier release is converted again when it is
# first viewed, and its ETag changes. The previews of the other converters keep
# their markers.
class VinceCacheRevisionTest < Redmine::ControllerTest
  include RedmineMorePreviews::TestHelper
  tests AttachmentsController

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :issues, :trackers, :issue_statuses, :enumerations,
           :projects_trackers, :attachments

  def setup
    set_tmp_attachments_directory
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = {
      'embedding' => '0', 'cache_previews' => '1', 'debug' => '0', 'absolute' => '0',
      'converter' => {'vince' => {'active' => '1', 'mime_types' => {
        'vcf' => {'active' => '1', 'format' => 'inline'}}}}
    }
    Setting.clear_cache
    EnabledModule.create!(project_id: 1, name: 'redmine_more_previews')
    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @dir = Dir.mktmpdir('rmp-vince-cache')
    @request.session[:user_id] = 2 # jsmith, member of project 1
  end

  def teardown
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf([@storage, @dir])
  end

  def test_a_preview_stored_before_is_converted_again
    a = attach_vcf("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Stored Before\r\nORG:Example Corp.;Sales\r\nEND:VCARD\r\n")
    get :show, params: {id: a.id}
    assert_response :success
    index = a.preview_filepath
    marker = "#{File.dirname(index)}.converter"
    assert_equal RedmineMorePreviews::Conversion.cache_marker_for(:vince), File.read(marker)
    assert_includes File.read(marker), Vince.cache_revision

    # as 6.1.9 stored it
    File.write(index, '<p>old preview of Vince 1.1.3</p>')
    File.write(marker, "vince:#{RedmineMorePreviews::Conversion::CACHE_FORMAT_VERSION}:normal")
    get :show, params: {id: a.id}
    assert_response :success
    assert_not_includes response.body, 'old preview of Vince 1.1.3'
    assert_includes response.body, '>Sales</span>'
    assert_equal RedmineMorePreviews::Conversion.cache_marker_for(:vince), File.read(marker)
    # the other converters keep their markers
    assert_equal "teddie:#{RedmineMorePreviews::Conversion::CACHE_FORMAT_VERSION}:normal",
                 RedmineMorePreviews::Conversion.cache_marker_for(:teddie)
  end

  def test_the_etag_of_a_vince_preview_has_its_revision
    helper = Object.new.extend(RedmineMorePreviews::ControllerHelper)
    RedmineMorePreviews::Converter.stubs(:responsible).returns(RedmineMorePreviews::Converter.find(:vince))
    assert_equal [Time.at(0), RedmineMorePreviews::Converter.find(:vince).id,
                  RedmineMorePreviews::Conversion::CACHE_FORMAT_VERSION, Vince.cache_revision, false],
                 helper.send(:preview_etag, Time.at(0), File.join(@dir, 'card.vcf'))
  end

  private

  def attach_vcf(content)
    path = File.join(@dir, 'card.vcf')
    File.binwrite(path, content)
    Attachment.create!(container: Issue.find(1), author: User.find(2),
                       file: Rack::Test::UploadedFile.new(path, 'text/vcard', true))
  end
end
