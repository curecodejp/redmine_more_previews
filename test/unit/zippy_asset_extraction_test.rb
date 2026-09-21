# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Archive entries are attacker controlled: an entry name is used both as the
# +asset+ request parameter and as the path the entry is extracted to. The
# converter must never write outside its temporary directory, must never create
# symlinks there, and must only hand back regular file entries.
class ZippyAssetExtractionTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  def setup
    @tmp = Dir.mktmpdir('rmp-zippy')
    # Dir.mktmpdir inside the converter honours TMPDIR, so everything the
    # converter writes lands below @tmp/tmp and anything escaping lands in @tmp.
    @old_tmpdir = ENV['TMPDIR']
    ENV['TMPDIR'] = File.join(@tmp, 'tmp').tap { |d| FileUtils.mkdir_p(d) }
    @cache = File.join(@tmp, 'cache')
    @target = File.join(@cache, 'preview.html', 'index.html')
  end

  def teardown
    ENV['TMPDIR'] = @old_tmpdir
    FileUtils.rm_rf(@tmp)
  end

  def escaped_files
    Dir.glob(File.join(@tmp, '**', '*'), File::FNM_DOTMATCH).
      reject { |f| File.directory?(f) }.
      reject { |f| f.start_with?(File.join(@tmp, 'tmp', ''), File.join(@tmp, 'cache', ''), File.join(@tmp, 'archives', '')) }
  end

  def archive(name)
    dir = File.join(@tmp, 'archives')
    FileUtils.mkdir_p(dir)
    File.join(dir, name)
  end

  def extract(archive_path, asset)
    worker = zippy_worker(target: @target, asset: asset)
    result = nil
    worker.preview(File.new(archive_path)) { |_preview, asset_data| result = asset_data }
    result
  end

  def fake_request
    ActionDispatch::TestRequest.create(
      'PATH_INFO' => '/attachments/more_preview/1.html',
      'action_dispatch.request.path_parameters' => {controller: 'attachments', action: 'more_preview', id: '1', format: 'html'}
    )
  end

  # --- regular entries keep working -------------------------------------------------

  def test_zip_regular_entry_is_extracted
    zip = build_zip(archive('a.zip'), 'dir/file.txt' => 'hello')
    assert_equal 'hello', extract(zip, 'dir/file.txt')
  end

  def test_tar_regular_entry_is_extracted
    tar = build_tar(archive('a.tar'), 'dir/file.txt' => 'hello')
    assert_equal 'hello', extract(tar, 'dir/file.txt')
  end

  def test_tgz_regular_entry_is_extracted
    tgz = build_tgz(archive('a.tgz'), 'dir/file.txt' => 'hello')
    assert_equal 'hello', extract(tgz, 'dir/file.txt')
  end

  # --- traversal in the requested asset / entry name ---------------------------------

  def test_zip_entry_escaping_the_tmp_directory_is_not_written
    zip = build_zip(archive('t.zip'), '../../escaped.txt' => 'owned')
    assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) { extract(zip, '../../escaped.txt') }
    assert_empty escaped_files
  end

  def test_tar_entry_escaping_the_tmp_directory_is_not_written
    tar = build_tar(archive('t.tar'), '../../escaped.txt' => 'owned')
    assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) { extract(tar, '../../escaped.txt') }
    assert_empty escaped_files
  end

  def test_absolute_entry_name_is_rejected
    tar = build_tar(archive('abs.tar'), '/tmp/escaped.txt' => 'owned')
    assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) { extract(tar, '/tmp/escaped.txt') }
    assert_empty escaped_files
  end

  # --- symlink entries ----------------------------------------------------------------

  def test_zip_symlink_entry_is_not_extracted
    zip = build_zip(archive('s.zip'), 'link.txt' => symlink_to)
    assert_nil extract(zip, 'link.txt')
    assert_empty escaped_files
    assert_empty Dir.glob(File.join(@tmp, 'tmp', '**', 'link.txt'))
  end

  def test_tar_symlink_entry_is_not_extracted
    tar = build_tar(archive('s.tar'), 'link.txt' => symlink_to)
    assert_nil extract(tar, 'link.txt')
    assert_empty Dir.glob(File.join(@tmp, 'tmp', '**', 'link.txt'))
  end

  # --- table of contents --------------------------------------------------------------

  def toc(archive_path)
    worker = zippy_worker(target: @target, request: fake_request)
    html = nil
    worker.preview(File.new(archive_path)) { |preview, *| html = preview }
    html
  end

  def test_zip_toc_does_not_link_entries_with_unsafe_names
    html = toc(build_zip(archive('toc.zip'), 'ok.txt' => 'a', '../bad.txt' => 'b'))
    assert_includes html, 'href="/attachments/more_preview/1.html?asset=ok.txt"'
    assert_not_includes html, '%2F..', 'no link may be generated for an entry escaping the archive root'
    assert_not_includes html, '..%2F'
  end

  def test_toc_links_nested_entries_encoded_once
    html = toc(build_zip(archive('nested.zip'), 'dir/' => '', 'dir/file.txt' => 'a'))
    assert_includes html, 'href="/attachments/more_preview/1.html?asset=dir%2Ffile.txt"'
    assert_not_includes html, '%252F'
  end

  def test_tar_toc_lists_unsafe_entry_names_without_a_link
    html = toc(build_tar(archive('toc.tar'), 'ok.txt' => 'a', '../bad.txt' => 'b', '/abs.txt' => 'c'))
    assert_includes html, 'href="/attachments/more_preview/1.html?asset=ok.txt"'
    assert_includes html, '<td>bad.txt</td>'
    assert_includes html, '<td>abs.txt</td>'
    assert_not_includes html, '%2F..'
    assert_not_includes html, '..%2F'
    assert_not_includes html, 'asset=%2F'
  end
end
