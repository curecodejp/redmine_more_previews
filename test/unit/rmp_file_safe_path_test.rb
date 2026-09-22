# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class RmpFileSafePathTest < ActiveSupport::TestCase
  RmpFile = RedmineMorePreviews::Lib::RmpFile

  def test_safe_relative_path_accepts_plain_relative_paths
    assert_equal 'file.txt',      RmpFile.safe_relative_path('file.txt')
    assert_equal 'dir/file.txt',  RmpFile.safe_relative_path('dir/file.txt')
    assert_equal 'dir/file.txt',  RmpFile.safe_relative_path('./dir//file.txt')
    assert_equal 'dir/file.txt',  RmpFile.safe_relative_path('dir/./file.txt')
    assert_equal 'dir/file.txt',  RmpFile.safe_relative_path('dir\\file.txt')
    assert_equal '日本語/ファイル.txt', RmpFile.safe_relative_path('日本語/ファイル.txt')
  end

  def test_safe_relative_path_rejects_paths_that_escape_the_base
    assert_nil RmpFile.safe_relative_path('../file.txt')
    assert_nil RmpFile.safe_relative_path('dir/../../file.txt')
    assert_nil RmpFile.safe_relative_path('..')
    assert_nil RmpFile.safe_relative_path('dir/..')
    assert_nil RmpFile.safe_relative_path('..\\file.txt')
  end

  # NTFS drops trailing dots and spaces of a path component, so ".. " or "..."
  # would be treated as ".." on a Windows host
  def test_safe_relative_path_rejects_dot_segments_with_trailing_dots_or_spaces
    assert_nil RmpFile.safe_relative_path('.. /file.txt')
    assert_nil RmpFile.safe_relative_path('dir/.../file.txt')
    assert_nil RmpFile.safe_relative_path('dir/. /file.txt')
    assert_nil RmpFile.safe_relative_path('... ')
    assert_equal 'dir/file.', RmpFile.safe_relative_path('dir/file.')
  end

  def test_safe_relative_path_rejects_absolute_paths
    assert_nil RmpFile.safe_relative_path('/etc/hostname')
    assert_nil RmpFile.safe_relative_path('\\\\server\\share')
    assert_nil RmpFile.safe_relative_path('C:\\Windows\\win.ini')
    assert_nil RmpFile.safe_relative_path('C:/Windows/win.ini')
  end

  def test_safe_relative_path_rejects_empty_and_control_characters
    assert_nil RmpFile.safe_relative_path(nil)
    assert_nil RmpFile.safe_relative_path('')
    assert_nil RmpFile.safe_relative_path('.')
    assert_nil RmpFile.safe_relative_path('/')
    assert_nil RmpFile.safe_relative_path("file\0.txt")
  end

  def test_within_directory
    Dir.mktmpdir do |base|
      inside = File.join(base, 'a', 'b.txt')
      assert RmpFile.within_directory?(base, inside)
      assert RmpFile.within_directory?(base, File.join(base, 'a', '..', 'c.txt'))
      assert_not RmpFile.within_directory?(base, File.join(base, '..', 'x.txt'))
      assert_not RmpFile.within_directory?(base, "#{base}-sibling/x.txt")
      assert_not RmpFile.within_directory?(base, base)
    end
  end

  def test_within_directory_follows_symlinks
    Dir.mktmpdir do |base|
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, 'secret'), 'x')
        File.symlink(File.join(outside, 'secret'), File.join(base, 'link'))
        assert_not RmpFile.within_directory?(base, File.join(base, 'link'))
      end
    end
  end
end
