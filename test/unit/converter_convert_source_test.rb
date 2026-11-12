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

  def test_a_missing_file_is_not_converted
    File.delete(@source)
    Pass.any_instance.expects(:preview).never
    assert_raises(Errno::ENOENT) { convert }
  end

  # a repository entry is given by its content: it is written when it is
  # converted, an entry without content as an empty file
  def test_a_file_given_by_its_content_is_written_to_be_converted
    File.delete(@source)
    { 'entry' => 'entry', nil => '' }.each_with_index do |(content, written), i|
      seen = nil
      Pass.any_instance.stubs(:convert).with { seen = File.binread(@source); true }
      # a target of its own: the failure of the one before (no output) is remembered
      convert(:source_content => -> { content }, :unsafe => true, :target => "preview#{i}")
      assert_equal written, seen
      File.delete(@source)
    end
  end

  private

  def convert(options = {})
    target = options.delete(:target) || 'preview'
    RedmineMorePreviews::Converter.convert(
      @source, File.join(@dir, target, 'index.txt'),
      {:converter => 'pass', :preview_format => 'txt', :format => 'txt',
       :object => {:type => :attachment, :object => Struct.new(:project, :id).new(nil, 1)}}.merge(options)
    )
  end
end
