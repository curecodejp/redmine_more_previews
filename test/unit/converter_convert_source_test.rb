# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Converter.convert gives the worker the file to convert. It left a file open
# for each preview until it was collected; the worker needs its path only.
class ConverterConvertSourceTest < ActiveSupport::TestCase
  def setup
    @dir = Dir.mktmpdir('rmp-convert-source')
    @source = File.join(@dir, 'a.txt')
    File.write(@source, 'text')
    # the failures a conversion remembers are kept in the storage
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, File.join(@dir, 'storage'))
  end

  def teardown
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@dir)
  end

  def test_no_file_is_left_open
    given = nil
    Pass.any_instance.stubs(:preview).with { |file| given = file; true }.returns('text')
    assert_equal 'text', convert
    assert_equal @source, given.respond_to?(:path) ? given.path : given
    assert_not (given.is_a?(IO) && !given.closed?), 'the file of the conversion is left open'
  end

  # the file of an attachment deleted since it was found: no preview, and no
  # error (it was Errno::ENOENT, an error of the server)
  def test_a_missing_file_is_not_converted
    File.delete(@source)
    Pass.any_instance.expects(:preview).never
    assert_nil convert
    yielded = false
    assert_nil convert { |*| yielded = true }
    assert_not yielded
  end

  # a file that is there and cannot be looked at (no permission to search its
  # directory) is not a file that is gone: an error, as before
  def test_a_file_that_cannot_be_looked_at_is_an_error
    skip 'the superuser may search any directory' if Process.uid.zero?
    locked  = File.join(@dir, 'locked')
    FileUtils.mkdir_p(locked)
    @source = File.join(locked, 'a.txt')
    File.write(@source, 'text')
    File.chmod(0o000, locked)
    Pass.any_instance.expects(:preview).never
    assert_raises(Errno::EACCES) { convert }
  ensure
    File.chmod(0o700, locked) if locked && File.directory?(locked)
  end

  # the file goes after it was looked for, before it is opened
  def test_a_file_removed_before_it_is_opened_is_not_converted
    converter = RedmineMorePreviews::Converter.find(:pass)
    worker    = converter.worker(:preview_format => 'txt', :object => {}, :target => File.join(@dir, 'preview', 'index.txt'))
    converter.stubs(:worker).with { File.delete(@source); true }.returns(worker)
    Pass.any_instance.expects(:preview).never
    assert_nil convert
    assert_empty Dir.glob(File.join(@dir, 'storage', 'failures', '*')), 'no failure of the file is remembered'
  end

  # a repository entry is given by its content: it is written when it is
  # converted, an entry without content as an empty file
  def test_a_file_given_by_its_content_is_written_to_be_converted
    File.delete(@source)
    { 'entry' => 'entry', nil => '' }.each_with_index do |(content, written), i|
      seen = nil
      Pass.any_instance.stubs(:convert).with { seen = File.binread(@source); true }
      # a target of its own: the failure of the one before (no output) is remembered
      convert(:source_content => -> { content }, :target => "preview#{i}") { |*| }
      assert_equal written, seen
      File.delete(@source)
    end
  end

  private

  # with a block, converted without the cache, as a request without the cache is
  def convert(options = {}, &block)
    target = options.delete(:target) || 'preview'
    RedmineMorePreviews::Converter.convert(
      @source, File.join(@dir, target, 'index.txt'),
      {:converter => 'pass', :preview_format => 'txt', :format => 'txt',
       :object => {:type => :attachment, :object => Struct.new(:project, :id).new(nil, 1)}}.merge(options),
      &block
    )
  end
end
