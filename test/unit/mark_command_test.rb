# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'

class MarkCommandTest < ActiveSupport::TestCase
  def setup
    @dir = Dir.mktmpdir('rmp-mark')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_leading_dash_output_is_a_relative_path
    worker = worker_for('-draft.md', "# heading\n")
    RedmineMorePreviews::Converter.stubs(:mime).returns({'mime' => 'text/markdown'})
    _, move = commands(worker)
    assert_equal 'mv', move.first
    assert_equal './-draft.html', move[1]
  end

  def test_textile_uses_pandoc_textile_reader
    worker = worker_for('example.textile', "h1. Heading\n")
    RedmineMorePreviews::Converter.stubs(:mime).returns({'mime' => 'text/x-web-textile'})
    pandoc, = commands(worker)
    assert_equal 'textile', pandoc[pandoc.index('-f') + 1]
  end

  private

  def worker_for(filename, body)
    input = File.join(@dir, filename)
    File.write(input, body)
    worker = Mark.allocate
    worker.source = input
    worker.format = 'inline'
    worker.preview_format = 'html'
    worker.tmpdir = Dir.mktmpdir('out', @dir)
    worker.tmptarget = File.join(worker.tmpdir, filename.sub(/\.[^.]+\z/, '.html'))
    worker.stubs(:converter_settings).returns({})
    worker
  end

  def commands(worker)
    command = nil
    worker.expects(:command).with {|value| command = value; true}.returns(true)
    worker.convert
    parts = command.split('; ').map {|part| Shellwords.split(part)}
    [parts.find {|args| args.first == Mark::PANDOC_BIN},
     parts.find {|args| args.first == 'mv'}]
  end
end
