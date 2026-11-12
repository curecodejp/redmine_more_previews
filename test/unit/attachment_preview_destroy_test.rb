# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The previews of an attachment are kept by its id: they go with the attachment,
# also when its file stays because another attachment shares it. Redmine removes
# the file and the thumbnails as it does without the plugin.
class AttachmentPreviewDestroyTest < ActiveSupport::TestCase
  fixtures :users, :projects, :issues, :trackers, :issue_statuses, :enumerations

  def setup
    set_tmp_attachments_directory
    @cache = Dir.mktmpdir('rmp-attachment-cleanup')
    @old_cache = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @cache)
    @dir = Dir.mktmpdir('rmp-attachment-source')
  end

  def teardown
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_cache)
    FileUtils.rm_rf([@cache, @dir])
  end

  def test_destroy_removes_the_previews_and_the_file
    attachment = attach('a.txt', 'content')
    preview = cache_of(attachment)
    diskfile = attachment.diskfile

    attachment.destroy!

    assert_not File.exist?(preview)
    assert_not File.exist?(diskfile)
  end

  # Redmine keeps a file that another attachment shares (Attachment#delete_from_disk)
  def test_destroy_removes_the_previews_of_an_attachment_sharing_its_file
    kept, gone = attachments_sharing_a_file
    kept_preview = cache_of(kept)
    gone_preview = cache_of(gone)

    gone.destroy!

    assert_not File.exist?(gone_preview), 'the previews of the destroyed attachment are left'
    assert_equal 'preview', File.read(File.join(kept_preview, 'preview.txt', 'index.txt'))
    assert File.file?(kept.diskfile), 'the shared file is removed'
  end

  def test_a_rolled_back_destroy_keeps_the_previews
    attachment = attach('a.txt', 'content')
    preview = cache_of(attachment)
    Attachment.transaction(requires_new: true) do
      attachment.destroy!
      raise ActiveRecord::Rollback
    end
    assert File.directory?(preview)
    assert File.file?(attachment.diskfile)
  end

  # a symbolic link in place of the previews is removed; what it points to is kept
  def test_destroy_removes_a_link_in_place_of_the_previews
    attachment = attach('a.txt', 'content')
    external = Dir.mktmpdir('rmp-outside')
    File.write(File.join(external, 'secret.txt'), 'keep')
    FileUtils.mkdir_p(attachment.previews_storagepath)
    File.symlink(external, attachment.preview_storagepath)

    attachment.destroy!

    assert_not File.symlink?(attachment.preview_storagepath)
    assert_equal 'keep', File.read(File.join(external, 'secret.txt'))
  ensure
    FileUtils.rm_rf(external) if external
  end

  # a conversion may outlive the request that deletes the attachment: the
  # preview it writes is removed when it ends (two attachments share the file,
  # so that the source stays)
  def test_a_conversion_during_the_destroy_leaves_no_preview
    kept, gone = attachments_sharing_a_file
    waited = nil
    converter = proc do |_input, output, *_args, &_block|
      Attachment.find(gone.id).destroy!
      waited = File.file?("#{gone.preview_storagepath}.cleanup_pending")
      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, 'preview')
      'converted'
    end

    with_stubbed_conversion(converter) { gone.more_preview }

    assert waited, 'the removal did not wait for the conversion'

    assert_not File.exist?(gone.preview_storagepath), 'the conversion left its preview'
    assert_not File.exist?("#{gone.preview_storagepath}.cleanup_pending")
    assert_not File.exist?("#{gone.preview_storagepath}.lifecycle.lock")
    assert File.file?(kept.diskfile)
  end

  # a request that loaded the attachment before it was deleted converts nothing
  def test_a_request_after_the_destroy_converts_nothing
    _kept, gone = attachments_sharing_a_file
    loaded = Attachment.find(gone.id)
    gone.destroy!
    converted = false
    converter = proc { |*_args, &_block| converted = true; 'converted' }

    with_stubbed_conversion(converter) do
      assert_nil loaded.more_preview
      assert_nil loaded.more_asset(:asset => 'a.png')
    end
    assert_not converted, 'a deleted attachment was converted'
    assert_not File.exist?(gone.preview_storagepath)
  end

  private

  def attach(name, content)
    path = File.join(@dir, name)
    File.write(path, content)
    Attachment.create!(container: Issue.find(1), author: User.find(2),
                       file: Rack::Test::UploadedFile.new(path, 'text/plain'))
  end

  # a stored preview, as a conversion leaves it
  def cache_of(attachment)
    dir = attachment.preview_storagepath
    FileUtils.mkdir_p(File.join(dir, 'preview.txt'))
    File.write(File.join(dir, 'preview.txt', 'index.txt'), 'preview')
    dir
  end

  # two attachments of one file on disk
  def attachments_sharing_a_file
    kept = attach('a.txt', 'shared content')
    gone = attach('b.txt', 'other content')
    gone.update_columns(disk_directory: kept.disk_directory, disk_filename: kept.disk_filename)
    [kept, gone.reload]
  end

  def with_stubbed_conversion(handler)
    converter = RedmineMorePreviews::Converter
    original = converter.method(:convert)
    converter.define_singleton_method(:convert, &handler)
    yield
  ensure
    converter.define_singleton_method(:convert, original) if original
  end
end
