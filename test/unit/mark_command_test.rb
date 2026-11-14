# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'

class MarkCommandTest < ActiveSupport::TestCase
  def setup
    @dir = Dir.mktmpdir('rmp-mark')
    @pandoc_version = Mark.pandoc_version
    Mark.pandoc_version = Gem::Version.new('2.0.6')
  end

  def teardown
    Mark.pandoc_version = @pandoc_version
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

  # with --sandbox pandoc reads no file but its input (pandoc 2.15 and later)
  def test_pandoc_that_takes_it_runs_in_its_sandbox
    worker = worker_for('example.md', "# heading\n")
    RedmineMorePreviews::Converter.stubs(:mime).returns({'mime' => 'text/markdown'})
    Mark.pandoc_version = Gem::Version.new('3.6.4')
    pandoc, = commands(worker)
    assert_equal [Mark::PANDOC_BIN, '--sandbox'], pandoc.first(2)
  end

  # pandoc before 2.15 refuses --sandbox: the conversion would fail
  def test_pandoc_before_the_sandbox_runs_without_it
    worker = worker_for('example.md', "# heading\n")
    RedmineMorePreviews::Converter.stubs(:mime).returns({'mime' => 'text/markdown'})
    pandoc, = commands(worker)
    assert_not_includes pandoc, '--sandbox'
  end

  # the version is asked once, and again while pandoc does not tell it
  def test_version_of_pandoc_is_asked_until_it_is_known
    worker = worker_for('example.md', "# heading\n")
    RedmineMorePreviews::Converter.stubs(:mime).returns({'mime' => 'text/markdown'})
    Mark.pandoc_version = nil
    worker.stubs(:run).returns(['', 'executable not found: "pandoc"', 127])
    pandoc, = commands(worker)
    assert_not_includes pandoc, '--sandbox'
    assert_nil Mark.pandoc_version

    worker.stubs(:run).returns(["pandoc 3.1.11.1\nFeatures: +server +lua\n", '', 0])
    pandoc, = commands(worker)
    assert_includes pandoc, '--sandbox'
    assert_equal Gem::Version.new('3.1.11.1'), Mark.pandoc_version

    worker.expects(:run).never
    pandoc, = commands(worker)
    assert_includes pandoc, '--sandbox'
  end

  # pandoc runs with a limit of its address space (see Mark::MAX_MEMORY)
  def test_pandoc_runs_with_a_memory_limit
    worker = worker_for('example.md', "# heading\n")
    RedmineMorePreviews::Converter.stubs(:mime).returns({'mime' => 'text/markdown'})
    commands(worker)
    assert_equal({:memory => Mark::MAX_MEMORY}, @options)
  end

  private

  def worker_for(filename, body)
    input = File.join(@dir, filename)
    File.write(input, body)
    worker = Mark.allocate
    worker.source = input
    worker.object = {}
    worker.preview_format = 'html'
    worker.tmpdir = Dir.mktmpdir('out', @dir)
    worker.tmptarget = File.join(worker.tmpdir, filename.sub(/\.[^.]+\z/, '.html'))
    worker.stubs(:converter_settings).returns({})
    worker
  end

  def commands(worker)
    command = nil
    worker.expects(:command).with {|value, options = {}| command = value; @options = options; true}.returns(true)
    worker.convert
    parts = command.split('; ').map {|part| Shellwords.split(part)}
    [parts.find {|args| args.first == Mark::PANDOC_BIN},
     parts.find {|args| args.first == 'mv'}]
  end
end
