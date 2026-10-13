# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'

class LibreCommandTest < ActiveSupport::TestCase
  def setup
    @worker = Libre.allocate
    @worker.tmpdir = '/tmp/rmp libre'
  end

  def test_allowed_output_formats_remain_supported
    %w(html txt pdf png jpg).each do |format|
      @worker.preview_format = format
      command = @worker.soffice('/tmp/input.docx', '/tmp/lo profile')
      assert_equal format, Shellwords.split(command)[Shellwords.split(command).index('--convert-to') + 1]
    end
  end

  def test_shell_quote_is_called_for_the_validated_format
    @worker.preview_format = 'pdf'
    @worker.stubs(:shell_quote).returns('quoted')
    @worker.expects(:shell_quote).with('pdf').returns("'pdf'")
    assert_includes @worker.soffice('/tmp/input.docx', '/tmp/profile'), "--convert-to 'pdf'"
  end

  def test_user_installation_with_spaces_is_one_shell_argument
    @worker.preview_format = 'pdf'
    installation = '/tmp/redmine temp/lo profile'
    arguments = Shellwords.split(@worker.soffice('/tmp/my document.docx', installation))

    # Do not compute the expectation using the method under test. LibreOffice
    # requires a URL-encoded path in addition to the shell-safe argument.
    assert_equal ['-env:UserInstallation=file:///tmp/redmine%20temp/lo%20profile'],
                 arguments.grep(/\A-env:UserInstallation=/)
    assert_equal '/tmp/my document.docx', arguments.last
    assert_equal '/tmp/rmp libre', arguments[arguments.index('--outdir') + 1]
  end

  def test_user_installation_with_quotes_and_metacharacters_cannot_split_commands
    @worker.preview_format = 'pdf'
    profiles = {
      "/tmp/redmine's cache/user installation" =>
        'file:///tmp/redmine%27s%20cache/user%20installation',
      '/tmp/cache; touch unexpected-file/$HOME $(id)' =>
        'file:///tmp/cache%3B%20touch%20unexpected-file/%24HOME%20%24%28id%29',
      "/tmp/first line\nsecond line" =>
        'file:///tmp/first%20line%0Asecond%20line',
      '/tmp/hash#query?sign%21/abc' =>
        'file:///tmp/hash%23query%3Fsign%2521/abc'
    }
    profiles.each do |installation, expected_url|
      arguments = Shellwords.split(@worker.soffice('/tmp/input.docx', installation))
      assert_equal ["-env:UserInstallation=#{expected_url}"],
                   arguments.grep(/\A-env:UserInstallation=/)
      assert_equal '/tmp/input.docx', arguments.last
    end
  end

  def test_windows_command_does_not_add_user_installation_flag
    @worker.preview_format = 'pdf'
    Redmine::Platform.stubs(:mswin?).returns(true)
    arguments = Shellwords.split(@worker.soffice('/tmp/input.docx', '/tmp/lo profile'))

    assert arguments.none? { |arg| arg.start_with?('-env:UserInstallation=') }
    assert_includes arguments, '--convert-to'
    assert_includes arguments, 'pdf'
  end

  def test_unknown_and_shell_metacharacter_formats_are_rejected
    ['inline', 'xml', '', 'pdf;touch /tmp/unwanted', 'pdf$(id)', "pdf\nwhoami"].each do |format|
      @worker.preview_format = format
      assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) do
        @worker.soffice('/tmp/input.docx', '/tmp/profile')
      end
    end
  end
end
