# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# A repository's cached conversion files must be deleted with the repository,
# without affecting any other repository or the shared preview storage root.
class RepositoryPreviewDestroyTest < ActiveSupport::TestCase
  fixtures :projects, :repositories, :enabled_modules

  def setup
    @old_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = (@old_scm + ['Filesystem']).uniq
    @source = Dir.mktmpdir('rmp-repo-source')
    @cache = Dir.mktmpdir('rmp-repo-cleanup')
    @old_cache = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @cache)

    EnabledModule.find_or_create_by!(project_id: 3, name: 'repository')
    @repository = Repository::Filesystem.create!(
      project: Project.find(3), url: @source, path_encoding: '', is_default: true
    )
  end

  def teardown
    Setting.enabled_scm = @old_scm
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_cache)
    FileUtils.rm_rf(@cache)
    FileUtils.rm_rf(@source)
  end

  def test_destroy_removes_only_this_repository_cache
    target = @repository.preview_storagepath
    cached = File.join(target, 'docs', 'digest', 'preview.html')
    FileUtils.mkdir_p(cached)
    File.write(File.join(cached, 'index.html'), 'private preview')
    File.write("#{cached}.converter", 'cliff:safe-debug-v1:normal')

    other_cache = File.join(@repository.previews_storagepath, '999999', 'keep.txt')
    FileUtils.mkdir_p(File.dirname(other_cache))
    File.write(other_cache, 'another repository')
    outside = File.join(@cache, 'keep.txt')
    File.write(outside, 'shared storage')

    @repository.destroy!
    # Transactional fixtures delay after_destroy_commit until the test's
    # outer transaction ends. Invoke the cleanup explicitly to test its effect.
    @repository.send(:remove_more_preview_cache_on_destroy)

    assert_not File.exist?(target)
    assert File.file?("#{target}.deleted")
    assert_equal 'another repository', File.read(other_cache)
    assert_equal 'shared storage', File.read(outside)
  end

  def test_destroy_does_not_follow_repository_cache_symlink_outside_root
    external = Dir.mktmpdir('rmp-outside')
    File.write(File.join(external, 'secret.txt'), 'keep')
    root = @repository.previews_storagepath
    FileUtils.mkdir_p(root)
    File.symlink(external, @repository.preview_storagepath)

    @repository.destroy!
    @repository.send(:remove_more_preview_cache_on_destroy)
    assert_equal 'keep', File.read(File.join(external, 'secret.txt'))
  ensure
    FileUtils.rm_rf(external) if external
  end

  def test_cache_cleanup_waits_for_an_inflight_preview
    target = @repository.preview_storagepath
    started = Queue.new
    cleanup = nil

    # Simulate conversion holding the repository-level lock while it writes.
    @repository.send(:with_repository_preview_lifecycle_lock) do
      cleanup = Thread.new do
        started << true
        @repository.send(:remove_more_preview_cache_on_destroy)
      end
      started.pop
      FileUtils.mkdir_p(target)
      File.write(File.join(target, 'private.txt'), 'late preview')
      assert File.file?(File.join(target, 'private.txt'))
    end

    assert cleanup.join(5), 'deletion should finish once conversion releases its lock'
    cleanup.value
    assert_not File.exist?(target), 'cleanup must remove a preview written during an active conversion'
    assert File.file?("#{target}.deleted")
  ensure
    cleanup&.kill if cleanup&.alive?
  end

  def test_destroyed_marker_blocks_a_delayed_preview_request
    @repository.send(:remove_more_preview_cache_on_destroy)
    @repository.expects(:entry).never

    assert_nil @repository.more_preview('a.zip', nil)
    assert_nil @repository.more_asset('a.zip', nil)
    assert_not File.exist?(@repository.preview_storagepath)
  end

  def test_failed_secure_removal_is_logged_and_does_not_reopen_cache
    target = @repository.preview_storagepath
    FileUtils.mkdir_p(target)
    FileUtils.expects(:remove_entry_secure).with(target).raises(ArgumentError, 'insecure directory')
    Rails.logger.expects(:error).with('Repository preview cache cleanup failed: ArgumentError: insecure directory')

    @repository.send(:remove_more_preview_cache_on_destroy)

    assert File.file?("#{target}.deleted"), 'even a failed cleanup must prevent new previews'
    assert File.directory?(target), 'the failed deletion must be visible for operator cleanup'
  end

  def test_cleanup_is_registered_only_after_committed_destroy
    callbacks = Repository._commit_callbacks.select do |callback|
      callback.kind == :after && callback.filter == :remove_more_preview_cache_on_destroy
    end
    assert_not_empty callbacks
  end

  def test_destroy_without_a_cache_directory_still_succeeds
    assert_not File.exist?(@repository.preview_storagepath)
    assert_difference('Repository.count', -1) { @repository.destroy! }
  end
end
