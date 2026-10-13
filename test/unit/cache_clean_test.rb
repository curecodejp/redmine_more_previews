# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'rake'

# The cached previews older than a number of days are removed by a rake task,
# under their cache lock; the lock files stay.
class CacheCleanTest < ActiveSupport::TestCase
  RmpCacheClean = RedmineMorePreviews::Lib::RmpCacheClean
  DAY = 24 * 60 * 60

  def setup
    @storage = Dir.mktmpdir('rmp-clean')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
  end

  def teardown
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
  end

  def test_previews_older_than_the_days_are_removed
    old = preview('attachments/1/preview.html', 31)
    recent = preview('attachments/2/preview.html', 29)
    repository = preview('repository_previews/3/doc/abc/preview.pdf', 40)
    assert_equal 2, RmpCacheClean.run(30)
    assert_not File.exist?(old)
    assert_not File.exist?("#{old}.converter")
    assert_not File.exist?("#{old}.assets"), 'the list of its assets goes with it'
    assert File.exist?("#{old}.lock"), 'lock files stay'
    assert File.exist?(File.join(recent, 'index.html'))
    assert_not File.exist?(repository)
  end

  def test_preview_in_use_is_skipped
    old = preview('attachments/1/preview.html', 31)
    File.open("#{old}.lock", File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      assert_equal 0, RmpCacheClean.run(30)
    end
    assert File.exist?(File.join(old, 'index.html'))
    assert_equal 1, RmpCacheClean.run(30)
  end

  # an archive entry or email attachment named *.converter is stored inside the
  # preview: it is an asset, not the marker of a preview
  def test_asset_named_like_a_marker_is_not_taken_for_one
    recent = preview('attachments/1/preview.html', 1)
    FileUtils.mkdir_p(File.join(recent, 'evil'))
    File.write(File.join(recent, 'evil', 'b.txt'), 'entry')
    File.write(File.join(recent, 'evil.converter'), 'entry')
    age(File.join(recent, 'evil.converter'), 31 * DAY)
    assert_equal 0, RmpCacheClean.run(30)
    assert File.exist?(File.join(recent, 'evil', 'b.txt'))
    assert_not File.exist?(File.join(recent, 'evil.lock'))
  end

  def test_disappeared_repository_marker_does_not_abort_other_cleanup
    vanished = preview('repository_previews/3/a/old/preview.html', 31)
    other = preview('attachments/5/preview.html', 31)
    original = File.method(:open)
    begin
      File.define_singleton_method(:open) do |path, *args, &block|
        raise Errno::ENOENT, path if path.to_s == "#{vanished}.lock"
        original.call(path, *args, &block)
      end
      assert_equal 1, RmpCacheClean.run(30)
    ensure
      File.define_singleton_method(:open, original)
    end
    assert_not File.exist?(other)
    assert File.exist?(vanished)
  end

  def test_deferred_repository_cleanup_is_retried_by_cache_clean
    orphan = File.join(@storage, 'repository_previews', '99999999')
    FileUtils.mkdir_p(orphan)
    File.write(File.join(orphan, 'private.txt'), 'previously cached content')
    File.write("#{orphan}.cleanup_pending", 'pending')

    assert_equal 0, RmpCacheClean.run(30)
    assert_not File.exist?(orphan)
    assert_not File.exist?("#{orphan}.cleanup_pending")
  end

  def test_old_failures_are_removed
    failures = File.join(@storage, 'failures')
    FileUtils.mkdir_p(failures)
    File.write(File.join(failures, 'old'), 'error')
    File.write(File.join(failures, 'new'), 'error')
    age(File.join(failures, 'old'), RedmineMorePreviews::Converter.failure_ttl + 60)
    RmpCacheClean.run(30)
    assert_equal %w(new), Dir.children(failures)
  end

  def test_rake_task_runs_the_clean
    rake = Rake::Application.new
    Rake.application = rake
    rake.define_task(Rake::Task, :environment)
    load File.expand_path('../../../lib/tasks/redmine_more_previews.rake', __FILE__)
    RmpCacheClean.expects(:run).with(7).returns(0)
    ENV['DAYS'] = '7'
    assert_output(/0 cached previews removed/) { rake['redmine_more_previews:cache:clean'].invoke }
  ensure
    ENV.delete('DAYS')
    Rake.application = Rake::Application.new
  end

  private

  # a stored preview, its marker written days ago
  def preview(relative, days)
    dir = File.join(@storage, relative)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'index.html'), 'preview')
    File.write("#{dir}.converter", 'zippy')
    File.write("#{dir}.assets", "complete\n")
    File.write("#{dir}.lock", '')
    age("#{dir}.converter", days * DAY)
    dir
  end

  def age(path, seconds)
    File.utime(Time.now - seconds, Time.now - seconds, path)
  end
end
