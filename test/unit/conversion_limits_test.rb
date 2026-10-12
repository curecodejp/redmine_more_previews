# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# A conversion runs within a time limit, and a request waits no longer than the
# wait limit for the cache lock of its preview and the converter's semaphore,
# and not at all for a conversion slot (counted across processes): it gets
# ConverterLockTimeOut (503) instead of piling up behind a slow conversion.
class ConversionLimitsTest < ActiveSupport::TestCase
  ConverterLockTimeOut = RedmineMorePreviews::Exceptions::ConverterLockTimeOut
  ConverterTimeout = RedmineMorePreviews::Exceptions::ConverterTimeout

  def setup
    @dir = Dir.mktmpdir('rmp-limits')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, File.join(@dir, 'storage'))
    @source = File.join(@dir, 'source.txt')
    File.write(@source, 'plain text')
    @target = File.join(@dir, 'storage', 'cache', 'preview.txt', 'index.txt')
    RedmineMorePreviews::Converter.stubs(:lock_timeout).returns(1)
    RedmineMorePreviews::Converter.stubs(:max_conversions).returns(1)
    @held = []
  end

  def teardown
    @held.each(&:close)
    @holder&.kill&.join
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@dir)
  end

  def test_settings_fall_back_to_the_defaults
    RedmineMorePreviews::Converter.unstub(:lock_timeout)
    RedmineMorePreviews::Converter.unstub(:max_conversions)
    with_plugin_settings('conversion_timeout' => '0', 'lock_timeout' => '', 'max_conversions' => '-1') do
      assert_equal 60, RedmineMorePreviews::Converter.conversion_timeout
      assert_equal 5, RedmineMorePreviews::Converter.lock_timeout
      assert_equal 2, RedmineMorePreviews::Converter.max_conversions
    end
    with_plugin_settings('conversion_timeout' => '30', 'lock_timeout' => '2', 'max_conversions' => '4') do
      assert_equal 30, RedmineMorePreviews::Converter.conversion_timeout
      assert_equal 2, RedmineMorePreviews::Converter.lock_timeout
      assert_equal 4, RedmineMorePreviews::Converter.max_conversions
    end
  end

  def test_libre_gets_at_least_its_own_time_limit
    RedmineMorePreviews::Converter.stubs(:conversion_timeout).returns(60)
    assert_equal 120, libre_worker.conversion_timeout
    RedmineMorePreviews::Converter.stubs(:conversion_timeout).returns(300)
    assert_equal 300, libre_worker.conversion_timeout
    assert_equal 300, pass_worker.conversion_timeout
  end

  def test_command_is_stopped_at_the_time_limit
    RedmineMorePreviews::Converter.stubs(:conversion_timeout).returns(1)
    start = now
    assert_raises(ConverterTimeout) { pass_worker.command('sleep 30') }
    assert_operator now - start, :<, 5
  end

  def test_commands_of_one_conversion_share_the_time_limit
    worker = pass_worker
    worker.instance_variable_set(:@deadline, now - 1)
    Process.expects(:spawn).never
    assert_raises(ConverterTimeout) { worker.command('true') }
  end

  def test_a_timed_out_conversion_gives_no_preview
    RedmineMorePreviews::Converter.stubs(:conversion_timeout).returns(1)
    worker = pass_worker
    worker.define_singleton_method(:convert) { command('sleep 30') }
    assert_nil worker.preview(File.new(@source))
  end

  def test_a_preview_is_converted_and_cached
    assert_equal 'plain text', pass_worker.preview(File.new(@source))
    assert_equal 'plain text', File.read(@target)
  end

  def test_cached_preview_is_served_while_the_converter_is_busy
    assert_equal 'plain text', pass_worker.preview(File.new(@source))
    hold_semaphore
    start = now
    assert_equal 'plain text', pass_worker.preview(File.new(@source))
    assert_operator now - start, :<, 1
  end

  def test_conversion_waits_no_longer_than_the_wait_limit_for_the_converter
    hold_semaphore
    start = now
    assert_raises(ConverterLockTimeOut) { pass_worker.preview(File.new(@source)) }
    assert_operator now - start, :<, 3
    assert_not File.exist?(@target)
  end

  def test_conversion_does_not_wait_for_a_slot
    hold_slot(0)
    start = now
    assert_raises(ConverterLockTimeOut) { pass_worker.preview(File.new(@source)) }
    assert_operator now - start, :<, 0.5
    assert_raises(ConverterLockTimeOut) { pass_worker.preview(File.new(@source)) {|*| flunk} }
    assert_not File.exist?(@target)
  end

  def test_another_free_slot_is_used
    RedmineMorePreviews::Converter.stubs(:max_conversions).returns(2)
    hold_slot(0)
    assert_equal 'plain text', pass_worker.preview(File.new(@source))
  end

  def test_a_conversion_does_not_wait_for_a_second_slot
    worker = pass_worker
    assert_equal :inner, worker.send(:with_slot) { worker.send(:with_slot) { :inner } }
  end

  # a child forked by one request inherits the slot another request holds:
  # the slot is free once that request is done, not once the child is
  def test_slot_is_free_while_a_child_forked_meanwhile_runs
    worker = pass_worker
    forked = Queue.new
    child = nil
    worker.send(:with_slot) do
      child = Thread.new do
        RedmineMorePreviews::Lib::RmpProcess.fork(timeout: 10) { forked << true; sleep 5 } rescue nil
      end
      sleep 0.5 # the child has been forked
    end
    assert_equal :converted, pass_worker.send(:with_slot) { :converted }
  ensure
    child&.kill
    child&.join
  end

  def test_request_waits_no_longer_than_the_wait_limit_for_the_cache_lock
    FileUtils.mkdir_p(File.dirname(File.dirname(@target)))
    lock = File.open("#{File.dirname(@target)}.lock", File::RDWR | File::CREAT)
    @held << lock
    assert lock.flock(File::LOCK_EX | File::LOCK_NB)
    assert_raises(ConverterLockTimeOut) { pass_worker.preview(File.new(@source)) }
  end

  def test_preview_larger_than_the_output_limit_is_not_served
    RedmineMorePreviews::Converter.stubs(:max_output).returns(5)
    assert_raises(RedmineMorePreviews::Exceptions::ConverterTooLarge) { pass_worker.preview(File.new(@source)) }
    assert_raises(RedmineMorePreviews::Exceptions::ConverterTooLarge) { pass_worker.preview(File.new(@source)) {|*| flunk} }
  end

  def test_preview_larger_than_the_output_limit_is_not_stored
    RedmineMorePreviews::Converter.stubs(:max_output).returns(5)
    assert_raises(RedmineMorePreviews::Exceptions::ConverterTooLarge) { pass_worker.preview(File.new(@source)) }
    assert_not File.exist?(@target)
  end

  def test_full_cache_converts_without_storing
    RedmineMorePreviews::Lib::RmpCacheSize.stubs(:full?).returns(true)
    assert_equal 'plain text', pass_worker.preview(File.new(@source))
    assert_not File.exist?(@target)
  end

  def test_full_cache_still_serves_what_is_stored
    assert_equal 'plain text', pass_worker.preview(File.new(@source))
    RedmineMorePreviews::Lib::RmpCacheSize.stubs(:full?).returns(true)
    Pass.any_instance.expects(:convert).never
    assert_equal 'plain text', pass_worker.preview(File.new(@source))
  end

  def test_cache_size_is_added_up_at_intervals
    storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    FileUtils.mkdir_p(File.join(storage, 'a'))
    File.binwrite(File.join(storage, 'a', 'one'), 'x' * 100)
    size = RedmineMorePreviews::Lib::RmpCacheSize.size
    assert_operator size, :>=, 100
    File.binwrite(File.join(storage, 'a', 'two'), 'x' * 1000)
    assert_equal size, RedmineMorePreviews::Lib::RmpCacheSize.size
    File.utime(Time.now - 3600, Time.now - 3600, File.join(storage, 'cache_size'))
    assert_operator RedmineMorePreviews::Lib::RmpCacheSize.size, :>=, size + 1000
    RedmineMorePreviews::Converter.stubs(:max_cache).returns(size + 1000)
    assert RedmineMorePreviews::Lib::RmpCacheSize.full?
    RedmineMorePreviews::Converter.stubs(:max_cache).returns(10 * 1024 * 1024)
    assert_not RedmineMorePreviews::Lib::RmpCacheSize.full?
  end

  private

  def now
    RedmineMorePreviews::Lib::RmpProcess.now
  end

  def pass_worker
    RedmineMorePreviews::Converter.find(:pass).worker(preview_format: 'txt', object: {}, target: @target)
  end

  def libre_worker
    RedmineMorePreviews::Converter.find(:libre).worker(preview_format: 'pdf', object: {}, target: @target)
  end

  # another thread (a conversion of another file) holds the converter's semaphore
  def hold_semaphore
    semaphore = RedmineMorePreviews::Converter.find(:pass).semaphore
    locked = Queue.new
    @holder = Thread.new do
      semaphore.synchronize do
        locked << true
        sleep
      end
    end
    locked.pop
  end

  # another process runs a conversion in slot n (flock excludes separate opens
  # of the file in the same process as well)
  def hold_slot(n)
    slots = File.join(RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH, 'slots')
    FileUtils.mkdir_p(slots)
    slot = File.open(File.join(slots, "#{n}.lock"), File::RDWR | File::CREAT)
    @held << slot
    assert slot.flock(File::LOCK_EX | File::LOCK_NB)
  end

  def with_plugin_settings(values)
    saved = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = saved.to_h.merge(values)
    yield
  ensure
    Setting.plugin_redmine_more_previews = saved
    Setting.clear_cache # the writer caches the symbol key; the plugin reads the string key
  end
end
