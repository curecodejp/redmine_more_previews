# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# vCard parsing and template rendering must be bounded by the same child-process
# deadline and memory cap as the other untrusted Ruby converters.
# Records the process that parses and renders, only while a test sets the log path.
module VinceIsolationPidRecorder
  def self.record(stage)
    path = Thread.current[:vince_isolation_pid_log]
    File.open(path, 'a') { |f| f.puts "#{stage} #{Process.pid}" } if path
  end

  module Reader
    def fileall(*args)
      VinceIsolationPidRecorder.record('reader')
      super
    end
  end

  module Erb
    def result(*args)
      VinceIsolationPidRecorder.record('erb')
      super
    end
  end
end
VinceLib::VObject::Reader.prepend(VinceIsolationPidRecorder::Reader)
ERB.prepend(VinceIsolationPidRecorder::Erb)

class VinceIsolationTest < ActiveSupport::TestCase
  def setup
    @tmp = Dir.mktmpdir('rmp-vince-isolation')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    @storage = File.join(@tmp, 'storage')
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)
    @src = File.join(@tmp, 'sample.vcf')
    File.binwrite(@src, "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Test Person\r\nN:Person;Test;;;\r\nEND:VCARD\r\n")
  end

  def teardown
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@tmp)
  end

  def test_html_inline_and_text_previews_are_rendered
    {'html' => 'Test Person', 'inline' => 'Test Person', 'txt' => 'Test Person'}.each do |format, expected|
      result = File.open(@src) { |io| worker(format).preview(io) }
      assert_includes result.to_s, expected, format
      if format != 'txt'
        assert_includes result.to_s, 'class="logo">'
        assert_not_includes result.to_s, 'class="logo" %>'
      end
    end
  end

  def test_parsing_and_rendering_run_inside_bounded_fork
    calls = []
    with_fork_spy(->(timeout, memory) { calls << [timeout, memory] }) do
      assert_includes File.open(@src) { |io| worker('html').preview(io) }, 'Test Person'
    end

    assert_equal 1, calls.length
    assert_operator calls.first.first, :>, 0
    assert_operator calls.first.first, :<=, RedmineMorePreviews::Converter.conversion_timeout
    assert_equal Vince::MAX_MEMORY, calls.first.last
    assert_nil Thread.current[:redmine_more_previews_vince_language], 'thread state must not leak'
  end

  def test_parsing_and_rendering_happen_in_the_child_process
    log = File.join(@tmp, 'pids.log')
    Thread.current[:vince_isolation_pid_log] = log
    %w(html txt).each do |format|
      assert_includes File.open(@src) { |io| worker(format).preview(io) }, 'Test Person', format
    end
    stages = File.readlines(log).map(&:split)
    %w(reader erb).each do |stage|
      pids = stages.select { |s, _| s == stage }.map { |_, pid| pid.to_i }
      assert_equal 2, pids.length, stage
      pids.each { |pid| assert_not_equal Process.pid, pid, "#{stage} ran in the request process" }
    end
  ensure
    Thread.current[:vince_isolation_pid_log] = nil
  end

  def test_photo_and_logo_do_not_read_settings_inside_the_child
    # A settings cache cleared by another request between the parent's read
    # and the fork would make Setting.default_language query the database.
    png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
    File.binwrite(@src, "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Test Person\r\nN:Person;Test;;;\r\n" \
                        "PHOTO:data:image/png;base64,#{png}\r\nLOGO:data:image/png;base64,#{png}\r\nEND:VCARD\r\n")
    html = with_fork_spy(->(_timeout, _memory) { Setting.expects(:default_language).never }) do
      File.open(@src) { |io| worker('html').preview(io) }
    end
    assert_includes html, 'vcard photo box'
    assert_includes html, 'vcard logo box'
  end

  def test_reader_that_blocks_cannot_hold_the_request_worker_indefinitely
    # A sleeping fake reader tests the actual child-process deadline without
    # allocating a huge hostile vCard or blocking a Redmine process.
    reader = Object.new
    reader.define_singleton_method(:fileall) { sleep 20 }
    VinceLib::VObject::Reader.stubs(:new).returns(reader)
    RedmineMorePreviews::Converter.stubs(:conversion_timeout).returns(1)

    started = RedmineMorePreviews::Lib::RmpProcess.now
    result = File.open(@src) { |io| worker('html').preview(io) }
    elapsed = RedmineMorePreviews::Lib::RmpProcess.now - started
    assert_nil result
    assert_operator elapsed, :<, 8
  end

  def test_cached_preview_is_served_without_forking
    w = worker('txt')
    assert_includes File.open(@src) { |io| w.preview(io) }, 'Test Person'
    RedmineMorePreviews::Lib::RmpProcess.expects(:fork).never
    assert_includes File.open(@src) { |io| worker('txt').preview(io) }, 'Test Person'
  end

  def test_error_in_the_child_is_logged
    log = File.join(@tmp, 'child.log')
    reader = Object.new
    reader.define_singleton_method(:fileall) { raise ArgumentError, 'broken vCard line' }
    VinceLib::VObject::Reader.stubs(:new).returns(reader)

    old_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    begin
      assert_nil File.open(@src) { |io| worker('html').preview(io) }
    ensure
      Rails.logger = old_logger
    end
    assert_match(/vCard sample\.vcf not previewed: ArgumentError: broken vCard line/, File.read(log))
  end

  def test_vcard_larger_than_the_limit_is_refused_before_forking
    File.open(@src, 'ab') { |f| f.truncate(Vince::MAX_SIZE + 1) }
    RedmineMorePreviews::Lib::RmpProcess.expects(:fork).never
    assert_raises(RedmineMorePreviews::Exceptions::ConverterTooLarge) do
      File.open(@src) { |io| worker('html').preview(io) }
    end
  end

  private

  # Runs the isolated block in this process so that expectations set by
  # before_block apply to the code that would run in the child.
  def with_fork_spy(before_block)
    original = RedmineMorePreviews::Lib::RmpProcess.method(:fork)
    RedmineMorePreviews::Lib::RmpProcess.define_singleton_method(:fork) do |timeout:, memory: nil, &block|
      before_block.call(timeout, memory)
      block.call
      true
    end
    yield
  ensure
    RedmineMorePreviews::Lib::RmpProcess.singleton_class.send(:remove_method, :fork)
    RedmineMorePreviews::Lib::RmpProcess.define_singleton_method(:fork, original)
  end

  def worker(format)
    RedmineMorePreviews::Converter.find(:vince).worker(
      :preview_format => format,
      :object => {},
      :target => File.join(@storage, "cached-#{format}", "index.#{format}")
    )
  end
end
