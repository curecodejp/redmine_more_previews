# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Converter.convert gives the worker the file to convert. It left a file open
# for each preview until it was collected; the worker needs its path only.
class ConverterConvertSourceTest < ActiveSupport::TestCase
  def setup
    @dir = Dir.mktmpdir('rmp-convert-source')
    @source = File.join(@dir, 'a.txt')
    File.write(@source, 'text')
  end

  def teardown
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

  private

  def convert
    RedmineMorePreviews::Converter.convert(
      @source, File.join(@dir, 'preview', 'index.txt'),
      :converter => 'pass', :preview_format => 'txt', :format => 'txt',
      :object => {:type => :attachment, :object => Struct.new(:project, :id).new(nil, 1)}
    )
  end
end
