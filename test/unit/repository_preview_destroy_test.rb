# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'timeout'

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

    assert_not File.exist?(target)
    assert_not File.exist?("#{target}.deleted")
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
    assert_equal 'keep', File.read(File.join(external, 'secret.txt'))
  ensure
    FileUtils.rm_rf(external) if external
  end
  def test_cache_cleanup_waits_for_an_inflight_preview
    target = @repository.preview_storagepath
    File.write(File.join(@source, 'readme.txt'), 'private source')
    entered = Queue.new
    release = Queue.new
    preview_thread = cleanup_thread = nil

    converter = proc do |_input, output, *_args, &_block|
      entered << :converting
      release.pop
      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, 'private preview')
      'converted'
    end

    RedmineMorePreviews::Converter.stub(:convert, converter) do
      # The real model entry point must own the shared lock.
      preview_thread = Thread.new { @repository.more_preview('readme.txt', nil) }
      assert_equal :converting, Timeout.timeout(5) { entered.pop }
      cleanup_thread = Thread.new { @repository.send(:remove_more_preview_cache_on_destroy) }
      sleep 0.1
      assert cleanup_thread.alive?, 'cleanup waits while conversion owns a shared lock'
      release << true
      assert preview_thread.join(5), 'conversion must finish'
      assert cleanup_thread.join(5), 'cleanup must finish after conversion'
      preview_thread.value
      cleanup_thread.value
    end

    assert_not File.exist?(target), 'cleanup removes an in-flight converted preview'
  ensure
    release << true if release && preview_thread&.alive?
    preview_thread&.kill if preview_thread&.alive?
    cleanup_thread&.kill if cleanup_thread&.alive?
  end
  def test_deleted_record_blocks_a_delayed_preview_request
    @repository.destroy!
    @repository.expects(:entry).never

    assert_nil @repository.more_preview('a.zip', nil)
    assert_nil @repository.more_asset('a.zip', nil)
    assert_not File.exist?(@repository.preview_storagepath)
  end

  def test_an_old_tombstone_does_not_block_restored_repository_id
    # Previously generated markers might outlive a database restore.
    File.write(File.join(@source, 'readme.txt'), 'present')
    FileUtils.mkdir_p(@repository.previews_storagepath)
    File.write("#{@repository.preview_storagepath}.deleted", 'old tombstone')

    RedmineMorePreviews::Converter.stubs(:convert).returns('ok')
    assert_equal 'ok', @repository.more_preview('readme.txt', nil)
  end

  def test_previews_of_the_same_repository_run_concurrently
    %w(a.txt b.txt).each { |name| File.write(File.join(@source, name), name) }
    entered = Queue.new
    release = Queue.new
    threads = []
    converter = proc do |*_args, &_block|
      entered << true
      release.pop
      'ok'
    end

    RedmineMorePreviews::Converter.stub(:convert, converter) do
      %w(a.txt b.txt).each { |path| threads << Thread.new { @repository.more_preview(path, nil) } }
      2.times { assert Timeout.timeout(5) { entered.pop } }
      2.times { release << true }
      threads.each { |thr| assert thr.join(5); assert_equal 'ok', thr.value }
    end
  ensure
    2.times { release << true } if release
    threads.each { |thr| thr.kill if thr.alive? } if threads
  end
  def test_failed_secure_removal_is_logged_and_does_not_reopen_cache
    target = @repository.preview_storagepath
    FileUtils.mkdir_p(target)
    FileUtils.expects(:remove_entry_secure).with(target).raises(ArgumentError, 'insecure directory')
    Rails.logger.expects(:error).with('Repository preview cache cleanup failed: ArgumentError: insecure directory')

    @repository.destroy!

    assert File.directory?(target), 'failed cleanup must remain visible to the operator'
    assert_nil @repository.more_preview('a.zip', nil), 'deleted repository must not recreate previews'
  end

  def test_partial_cleanup_error_is_logged
    target = @repository.preview_storagepath
    FileUtils.mkdir_p(target)
    FileUtils.expects(:remove_entry_secure).with(target).raises(Errno::ENOENT)
    Rails.logger.expects(:error).with(regexp_matches(/Repository preview cache cleanup failed: Errno::ENOENT/))
    @repository.destroy!
  end

  def test_rolled_back_destroy_keeps_the_cache
    target = @repository.preview_storagepath
    FileUtils.mkdir_p(target)
    Repository.transaction(requires_new: true) do
      @repository.destroy!
      raise ActiveRecord::Rollback
    end
    assert File.directory?(target)
    assert Repository.exists?(@repository.id)
    assert_not File.exist?("#{target}.deleted")
  end

  def test_shared_lock_respects_converter_timeout
    FileUtils.mkdir_p(@repository.previews_storagepath)
    lock = File.open("#{@repository.preview_storagepath}.lifecycle.lock", File::RDWR | File::CREAT, 0644)
    lock.flock(File::LOCK_EX)
    RedmineMorePreviews::Converter.stubs(:lock_timeout).returns(0.05)
    assert_raises(RedmineMorePreviews::Exceptions::ConverterLockTimeOut) do
      @repository.send(:with_repository_preview_lifecycle_lock) { flunk 'unexpected lock acquisition' }
    end
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
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
