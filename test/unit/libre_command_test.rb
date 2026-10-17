# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'

class LibreCommandTest < ActiveSupport::TestCase
  def setup
    @worker = Libre.allocate
    @worker.tmpdir = '/tmp/rmp libre'
  end

  def sandbox_args(src = '/tmp/input.docx', profile = '/tmp/profile')
    Shellwords.split(@worker.soffice(src, profile))
  end

  def test_allowed_output_formats_remain_supported
    %w(html txt pdf png jpg).each do |format|
      @worker.preview_format = format
      args = sandbox_args
      assert_equal format, args[args.index('--convert-to') + 1]
    end
  end

  def test_shell_quote_is_called_for_the_validated_format
    @worker.preview_format = 'pdf'
    @worker.stubs(:shell_quote).returns('quoted')
    @worker.expects(:shell_quote).with('pdf').returns("'pdf'")
    assert_includes @worker.soffice('/tmp/input.docx', '/tmp/profile'), "'pdf'"
  end

  def test_sandbox_has_no_host_root_or_unrestricted_input_directory
    @worker.preview_format = 'pdf'
    args = sandbox_args('/redmine/files/input.odt', '/tmp/redmine profile')
    assert_equal [Libre::ENV_BIN, '-i', Libre::BWRAP_BIN], args.first(3)
    %w(--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --die-with-parent --new-session).each do |flag|
      assert_includes args, flag
    end
    mounts = args.each_cons(3).select { |a, _, _| %w(--bind --ro-bind).include?(a) }
    refute mounts.any? { |a, src, dest| src == '/' || dest == '/' }, 'never bind the host root'
    assert_includes mounts, ['--ro-bind', '/redmine/files/input.odt', '/input/input.odt']
    assert_includes mounts, ['--bind', '/tmp/rmp libre', '/output']
    assert_includes mounts, ['--bind', '/tmp', '/profile']
    assert_equal '/input/input.odt', args.last
    assert_equal '/output', args[args.index('--outdir') + 1]
  end

  def test_shell_metacharacters_in_paths_cannot_split_commands
    @worker.preview_format = 'pdf'
    input = "/tmp/a ' file;$(id).odt"
    profile = "/tmp/weird ' ;$(touch evil)/user_installation"
    args = sandbox_args(input, profile)
    assert_includes args, input
    assert_includes args, File.dirname(profile)
    assert_equal File.join('/input', File.basename(input)), args.last
    assert_equal 1, args.count('--')
  end

  def test_empty_environment_and_private_profile
    @worker.preview_format = 'pdf'
    args = sandbox_args
    assert_equal [Libre::ENV_BIN, '-i', Libre::BWRAP_BIN], args.first(3)
    refute_includes args, '--clearenv'
    assert_includes args, '--setenv'
    assert_includes args, '--tmpfs'
    assert_equal ['-env:UserInstallation=file:///profile/user_installation'],
                 args.grep(/\A-env:UserInstallation=/)
    refute args.include?('/home')
  end

  def test_rejects_windows_and_unknown_formats
    @worker.preview_format = 'pdf'
    Redmine::Platform.stubs(:mswin?).returns(true)
    assert_raises(RedmineMorePreviews::Exceptions::ConverterShellError) do
      sandbox_args
    end
    Redmine::Platform.stubs(:mswin?).returns(false)
    ['inline', 'xml', '', 'pdf;touch /tmp/unwanted', 'pdf$(id)', "pdf\nwhoami"].each do |format|
      @worker.preview_format = format
      assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) { sandbox_args }
    end
  end

  def test_refuses_host_root_mounts
    @worker.preview_format = 'pdf'
    assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) do
      sandbox_args('/tmp/input.odt', '/profile')
    end
    @worker.tmpdir = '/'
    assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) do
      sandbox_args('/tmp/input.odt', '/tmp/profile')
    end
  end


  def test_conversion_fails_closed_when_sandbox_is_unavailable
    @worker.stubs(:sandbox_available?).returns(false)
    @worker.expects(:command).never
    assert_raises(RedmineMorePreviews::Exceptions::ConverterShellError) { @worker.convert }
  end

  def test_legacy_preview_cache_is_invalidated
    assert_equal 'libre-sandbox-v2', RedmineMorePreviews::Conversion::CACHE_FORMAT_VERSION
  end

  def test_relative_paths_rejected
    @worker.preview_format = 'pdf'
    assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) do
      sandbox_args('relative.odt', '/tmp/profile')
    end
  end
end
