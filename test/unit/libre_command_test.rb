# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'

class LibreCommandTest < ActiveSupport::TestCase
  def setup
    @worker = Libre.allocate
    @worker.tmpdir = '/tmp/rmp libre'
  end

  def sandbox_args(src = '/tmp/input.docx', profile = '/tmp/rmp-profile/private/user_installation')
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
    args = sandbox_args('/redmine/files/input.odt', '/tmp/redmine-profile/private/user_installation')
    assert_equal [Libre::ENV_BIN, '-i', Libre::BWRAP_BIN], args.first(3)
    %w(--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --die-with-parent --new-session).each do |flag|
      assert_includes args, flag
    end
    mounts = args.each_cons(3).select { |a, _, _| %w(--bind --ro-bind).include?(a) }
    refute mounts.any? { |a, src, dest| src == '/' || dest == '/' }, 'never bind the host root'
    assert_includes mounts, ['--ro-bind', '/redmine/files/input.odt', '/input/input.odt']
    assert_includes mounts, ['--bind', '/tmp/rmp libre', '/output']
    assert_includes mounts, ['--bind', '/tmp/redmine-profile/private', '/profile']
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


  def test_bind_sources_are_exactly_the_allowed_resources
    @worker.preview_format = 'pdf'
    args = sandbox_args('/redmine/files/input.odt', '/tmp/rmp-profile/private/user_installation')
    mounts = args.each_cons(3).select { |type, _, _| %w(--bind --ro-bind).include?(type) }
    expected = [
      ['--ro-bind', '/usr/bin', '/usr/bin'],
      ['--ro-bind', '/usr/lib', '/usr/lib'],
      ['--ro-bind', '/etc/fonts', '/etc/fonts'],
      ['--ro-bind', '/etc/ld.so.cache', '/etc/ld.so.cache'],
      ['--ro-bind', '/redmine/files/input.odt', '/input/input.odt'],
      ['--bind', '/tmp/rmp libre', '/output'],
      ['--bind', '/tmp/rmp-profile/private', '/profile']
    ]
    %w(/usr/lib64 /usr/share/fonts /usr/share/fontconfig /usr/share/locale
       /usr/share/mime /usr/share/libreoffice /usr/share/icu /usr/share/zoneinfo
       /etc/alternatives /etc/libreoffice).each do |path|
      expected << ['--ro-bind', path, path] if File.directory?(path)
    end
    %w(/bin /sbin /lib /lib64).each do |path|
      expected << ['--ro-bind', path, path] if File.directory?(path) && !File.symlink?(path)
    end
    assert_equal expected.sort, mounts.sort, 'no unlisted host paths may be mounted'
    refute_includes mounts, ['--ro-bind', '/etc', '/etc']
    %w(--dev-bind --bind-try --ro-bind-try).each do |unsafe_mount|
      refute_includes args, unsafe_mount
    end
    expected_links = %w(/bin /sbin /lib /lib64).select { |path| File.symlink?(path) }.map do |path|
      ['--symlink', File.readlink(path), path]
    end
    actual_links = args.each_cons(3).select { |type, _, _| type == '--symlink' }
    assert_equal expected_links.sort, actual_links.sort, 'symlink mounts must follow host merged-usr layout only'
  end

  def test_status_delegates_to_actual_namespace_probe
    @worker.expects(:sandbox_available?).returns(false)
    assert_equal [:text_libre_office_available, false], @worker.status
  end

  def test_unsafe_libre_output_entries_are_rejected
    Dir.mktmpdir('rmp-libre-output') do |dir|
      @worker.tmpdir = dir
      File.symlink('/etc/passwd', File.join(dir, 'index.pdf'))
      assert_raises(RedmineMorePreviews::Exceptions::ConverterShellError) do
        @worker.send(:validate_libre_output!)
      end
      File.delete(File.join(dir, 'index.pdf'))
      FileUtils.mkdir_p(File.join(dir, 'images'))
      File.symlink('/etc', File.join(dir, 'images', 'private'))
      assert_raises(RedmineMorePreviews::Exceptions::ConverterShellError) do
        @worker.send(:validate_libre_output!)
      end
    end
  end

  def test_symlinked_cached_target_is_never_served
    Dir.mktmpdir('rmp-libre-cache') do |dir|
      secret = File.join(dir, 'outside.txt')
      File.write(secret, 'private-dummy')
      cache = File.join(dir, 'preview')
      FileUtils.mkdir_p(cache)
      target = File.join(cache, 'index.pdf')
      File.symlink(secret, target)
      worker = RedmineMorePreviews::Conversion.allocate
      worker.dir = cache
      worker.target = target
      worker.targetpath = target
      assert_nil worker.send(:read_safe)
    end
  end

  def test_regular_libre_output_tree_is_accepted
    Dir.mktmpdir('rmp-libre-output') do |dir|
      @worker.tmpdir = dir
      FileUtils.mkdir_p(File.join(dir, 'images'))
      File.binwrite(File.join(dir, 'index.pdf'), '%PDF-safe')
      File.binwrite(File.join(dir, 'images', 'logo.png'), 'fake image')
      assert_nil @worker.send(:validate_libre_output!)
    end
  end

  def test_conversion_rejects_symlink_before_rewriting_output
    Dir.mktmpdir('rmp-libre-hostile') do |dir|
      @worker.tmpdir = dir
      @worker.tmptarget = File.join(dir, 'index.pdf')
      @worker.source = File.join(dir, 'document.odt')
      @worker.preview_format = 'pdf'
      File.write(@worker.source, 'dummy')
      File.symlink('/etc/passwd', File.join(dir, 'document.pdf'))
      @worker.stubs(:sandbox_available?).returns(true)
      @worker.stubs(:soffice).returns('fake')
      @worker.expects(:command).once.returns(true)
      @worker.expects(:fix_image_path).never
      assert_raises(RedmineMorePreviews::Exceptions::ConverterShellError) { @worker.convert }
    end
  end

  def test_source_named_index_does_not_rename_file_onto_itself
    Dir.mktmpdir('rmp-libre-index') do |dir|
      @worker.tmpdir = dir
      @worker.tmptarget = File.join(dir, 'index.pdf')
      @worker.source = File.join(dir, 'index.odt')
      @worker.preview_format = 'pdf'
      File.binwrite(@worker.source, 'fake odt')
      @worker.stubs(:sandbox_available?).returns(true)
      @worker.stubs(:soffice).returns('fake soffice')
      @worker.expects(:command).once.with(anything).returns(true)
      # Stubbing command means nothing writes the PDF automatically; supply the
      # same output filename that LibreOffice would create for index.odt.
      File.binwrite(@worker.tmptarget, '%PDF-safe')
      assert_nil @worker.convert
      assert_equal '%PDF-safe', File.binread(@worker.tmptarget)
    end
  end

  def test_relative_paths_rejected
    @worker.preview_format = 'pdf'
    assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) do
      sandbox_args('relative.odt', '/tmp/profile')
    end
  end
end
