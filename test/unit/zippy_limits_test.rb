# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# An archive expands without bound: a tgz is inflated from the start up to the
# entry asked for, and rubyzip reads the whole central directory of a zip. The
# walk through a tar / tgz, the central directory of a zip, the size of an
# extracted asset and the assets stored per archive are bounded.
class ZippyLimitsTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  ConverterTooLarge = RedmineMorePreviews::Exceptions::ConverterTooLarge

  def setup
    @tmp = Dir.mktmpdir('rmp-zippy-limits')
    @old_tmpdir = ENV['TMPDIR']
    ENV['TMPDIR'] = File.join(@tmp, 'tmp').tap { |d| FileUtils.mkdir_p(d) }
    @target = File.join(@tmp, 'cache', 'preview.html', 'index.html')
    @old_settings = Setting.plugin_redmine_more_previews
  end

  def teardown
    ENV['TMPDIR'] = @old_tmpdir
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    FileUtils.rm_rf(@tmp)
  end

  def test_tgz_list_stops_at_the_entry_limit
    tgz = build_tgz(path('a.tgz'), (1..5).to_h { |n| ["f#{n}.txt", "file #{n}"] })
    with_zippy_limits('max_entries' => '3') do
      html = listing(tgz)
      assert_includes html, 'f3.txt'
      assert_not_includes html, 'f4.txt'
      assert_includes html, CGI.escapeHTML(I18n.translate(:"redmine_more_previews.zippy.text_list_truncated"))
    end
  end

  def test_tgz_list_stops_at_the_inflated_limit
    tgz = build_tgz(path('a.tgz'), 'big.bin' => "\0" * (2 * 1024 * 1024), 'after.txt' => 'after')
    with_zippy_limits('max_inflated' => '1') do
      html = listing(tgz)
      assert_not_includes html, 'after.txt'
      assert_includes html, CGI.escapeHTML(I18n.translate(:"redmine_more_previews.zippy.text_list_truncated"))
      # the entry beyond the limit is not reached either
      assert_raises(ConverterTooLarge) { extract(tgz, 'after.txt') }
    end
  end

  def test_complete_tar_list_is_not_marked_truncated
    tar = build_tar(path('a.tar'), 'a.txt' => 'a')
    assert_not_includes listing(tar), CGI.escapeHTML(I18n.translate(:"redmine_more_previews.zippy.text_list_truncated"))
  end

  def test_tar_asset_larger_than_the_limit_is_refused
    tar = build_tar(path('a.tar'), 'big.bin' => 'x' * (1024 * 1024 + 1))
    with_zippy_limits('max_asset' => '1') do
      assert_raises(ConverterTooLarge) { extract(tar, 'big.bin') }
    end
  end

  def test_zip_asset_larger_than_the_limit_is_refused
    zip = build_zip(path('a.zip'), 'big.bin' => 'x' * (1024 * 1024 + 1))
    with_zippy_limits('max_asset' => '1') do
      assert_raises(ConverterTooLarge) { extract(zip, 'big.bin') }
    end
  end

  def test_zip_with_too_many_entries_is_not_opened
    zip = build_zip(path('a.zip'), (1..5).to_h { |n| ["f#{n}.txt", "file #{n}"] })
    with_zippy_limits('max_entries' => '3') do
      Zip::File.expects(:open).never
      assert_raises(ConverterTooLarge) { listing(zip) }
      assert_raises(ConverterTooLarge) { extract(zip, 'f1.txt') }
    end
  end

  def test_zip64_end_of_central_directory_is_read
    # a zip64 record, its locator and a record pointing to them
    zip64 = [0x06064b50, 44, 45, 45, 0, 0, 70_000, 70_000, 5_000_000, 0].pack('VQ<vvVVQ<Q<Q<Q<')
    locator = [0x07064b50, 0, 16, 1].pack('VVQ<V')
    eocd = [0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0].pack('VvvvvVVv')
    file = path('zip64.zip')
    File.binwrite(file, ('P' * 16) + zip64 + locator + eocd)
    worker = zippy_worker(target: @target)
    worker.source = file
    assert_equal [70_000, 5_000_000], worker.send(:central_directory)
  end

  # a zip64 record in the comment: rubyzip goes by it whatever the end of central
  # directory record says, and so must the check
  def test_entries_are_counted_as_rubyzip_counts_them
    zip = build_zip(path('comment.zip'), (1..5).to_h { |n| ["f#{n}.txt", "file #{n}"] })
    add_comment(zip, zip64_record(3, 1000) + zip64_locator)
    worker = zippy_worker(target: @target)
    worker.source = zip
    rubyzip = Zip::CentralDirectory.new
    File.open(zip, 'rb') { |io| rubyzip.read_from_stream(io) rescue nil }
    assert_equal 3, rubyzip.instance_variable_get(:@size)
    assert_equal 3, worker.send(:central_directory).first
  end

  def test_zip64_record_in_the_comment_beyond_the_limit_is_refused
    zip = build_zip(path('comment.zip'), 'f.txt' => 'file')
    add_comment(zip, zip64_record(20_000, 1000) + zip64_locator)
    Zip::File.expects(:open).never
    assert_raises(ConverterTooLarge) { listing(zip) }
  end

  def test_file_without_end_of_central_directory_is_left_to_rubyzip
    file = path('broken.zip')
    File.binwrite(file, 'not a zip')
    worker = zippy_worker(target: @target)
    worker.source = file
    assert_nil worker.send(:central_directory)
  end

  def test_assets_stored_per_archive_are_bounded
    zip = build_zip(path('a.zip'), 'small.txt' => 'small')
    preview_dir = File.dirname(@target)
    FileUtils.mkdir_p(preview_dir)
    File.binwrite(File.join(preview_dir, 'stored.bin'), 'x' * (1024 * 1024))
    File.write("#{preview_dir}.converter", 'zippy')
    File.write(@target, '<p>listing</p>')
    with_zippy_limits('max_stored' => '1') do
      worker = zippy_worker(target: File.join(preview_dir, 'small.txt'), asset: 'small.txt')
      assert_raises(ConverterTooLarge) { worker.preview(File.new(zip)) }
      # not stored, so not bounded: a transient extraction still works
      assert_equal 'small', extract(zip, 'small.txt')
    end
  end

  # a nested asset is stored at its own path below the archive's directory:
  # the assets stored for the whole archive count
  def test_assets_stored_per_archive_count_nested_assets
    zip = build_zip(path('a.zip'), 'dir/small.txt' => 'small')
    preview_dir = File.dirname(@target)
    FileUtils.mkdir_p(File.join(preview_dir, 'other'))
    File.binwrite(File.join(preview_dir, 'other', 'stored.bin'), 'x' * (1024 * 1024))
    File.write("#{preview_dir}.converter", 'zippy')
    File.write(@target, '<p>listing</p>')
    with_zippy_limits('max_stored' => '1') do
      worker = zippy_worker(target: File.join(preview_dir, 'dir', 'small.txt'), asset: 'dir/small.txt')
      assert_raises(ConverterTooLarge) { worker.preview(File.new(zip)) }
    end
  end

  def test_full_cache_does_not_bound_what_is_stored_per_archive
    zip = build_zip(path('a.zip'), 'small.txt' => 'small')
    preview_dir = File.dirname(@target)
    FileUtils.mkdir_p(preview_dir)
    File.binwrite(File.join(preview_dir, 'stored.bin'), 'x' * (1024 * 1024))
    File.write("#{preview_dir}.converter", 'zippy')
    File.write(@target, '<p>listing</p>')
    RedmineMorePreviews::Lib::RmpCacheSize.stubs(:full?).returns(true)
    with_zippy_limits('max_stored' => '1') do
      worker = zippy_worker(target: File.join(preview_dir, 'small.txt'), asset: 'small.txt')
      assert_equal 'small', worker.preview(File.new(zip))
      assert_not File.exist?(File.join(preview_dir, 'small.txt'))
    end
  end

  def test_tar_asset_beyond_the_limits_is_refused
    tgz = build_tgz(path('a.tgz'), (1..5).to_h { |n| ["f#{n}.txt", "file #{n}"] })
    with_zippy_limits('max_entries' => '3') do
      assert_equal 'file 2', extract(tgz, 'f2.txt')
      assert_raises(ConverterTooLarge) { extract(tgz, 'f5.txt') }
      assert_nil extract(build_tgz(path('b.tgz'), 'a.txt' => 'a'), 'missing.txt')
    end
  end

  def test_deep_directories_are_listed_as_one_name
    name = (1..70).map { |n| "d#{n}" }.join('/') + '/file.txt'
    zip = build_zip(path('deep.zip'), name => 'deep')
    worker = zippy_worker(target: @target)
    depth = 0
    Zip::File.open(zip) do |zip_file|
      node = worker.send(:ziptree, zip_file)
      while node.size == 1 && node.values.first[:dir]
        depth += 1
        node = node.values.first[:children]
      end
      assert_equal (65..70).map { |n| "d#{n}" }.join('/') + '/file.txt', node.keys.first
    end
    assert_equal Zippy::MAX_DEPTH, depth
  end

  # the stored listing names the entries: another name is not looked for in the
  # archive again, and no failure is kept for it (one for each name asked for)
  def test_name_missing_from_the_stored_listing_is_not_looked_for
    tgz = build_tgz(path('a.tgz'), 'a.txt' => 'a', 'dir/b.txt' => 'b')
    store_listing(tgz)
    Zippy.any_instance.expects(:convert).never
    %w(missing.txt dir/missing.txt).each do |name|
      assert_nil stored_asset(tgz, name)
      assert_nil RedmineMorePreviews::Lib::RmpFailures.recorded(asset_target(tgz, name))
    end
  end

  def test_names_in_the_stored_listing_are_extracted
    tgz = build_tgz(path('a.tgz'), './a.txt' => 'a', 'dir/b.txt' => 'b')
    zip = build_zip(path('a.zip'), 'dir/' => '', 'dir/c.txt' => 'c')
    store_listing(tgz)
    store_listing(zip)
    assert_equal 'a', stored_asset(tgz, 'a.txt'), 'by its normalized name'
    assert_equal 'b', stored_asset(tgz, 'dir/b.txt')
    assert_equal 'c', stored_asset(zip, 'dir/c.txt')
    assert_nil stored_asset(zip, 'dir'), 'a directory is no asset'
  end

  # a listing that stopped at a limit: a name it has not may lie beyond, and is
  # refused as the walk would refuse it, without the walk
  def test_name_beyond_a_truncated_listing_is_refused_without_a_walk
    tgz = build_tgz(path('a.tgz'), (1..5).to_h { |n| ["f#{n}.txt", "file #{n}"] })
    with_zippy_limits('max_entries' => '3') do
      store_listing(tgz)
      assert_equal 'file 2', stored_asset(tgz, 'f2.txt')
      Zippy.any_instance.expects(:convert).never
      assert_raises(ConverterTooLarge) { stored_asset(tgz, 'f5.txt') }
      assert_nil RedmineMorePreviews::Lib::RmpFailures.recorded(asset_target(tgz, 'f5.txt'))
    end
  end

  # without a stored listing the archive is walked once, to its end, and the
  # names are stored then: another name is not looked for again, and a missing
  # name is not remembered as failed
  def test_names_are_listed_by_the_first_asset_without_a_stored_listing
    tgz = build_tgz(path('a.tgz'), 'a.txt' => 'a', 'b.txt' => 'b')
    assert_equal 'a', stored_asset(tgz, 'a.txt')
    assert_nil stored_asset(tgz, 'missing.txt')
    assert_nil RedmineMorePreviews::Lib::RmpFailures.recorded(asset_target(tgz, 'missing.txt'))
    Zippy.any_instance.expects(:convert).never
    assert_nil stored_asset(tgz, 'other.txt')
    assert_equal 'a', stored_asset(tgz, 'a.txt')
  end

  def test_names_are_listed_by_a_missing_asset_without_a_stored_listing
    zip = build_zip(path('a.zip'), 'a.txt' => 'a')
    assert_nil stored_asset(zip, 'missing.txt')
    Zippy.any_instance.expects(:convert).never
    assert_nil stored_asset(zip, 'other.txt')
  end

  # the walk of a first asset stopped at a limit: the names before it are
  # stored all the same, and another name is refused without a walk
  def test_names_are_listed_by_an_asset_beyond_the_limits
    tgz = build_tgz(path('a.tgz'), (1..5).to_h { |n| ["f#{n}.txt", "file #{n}"] })
    with_zippy_limits('max_entries' => '3') do
      assert_raises(ConverterTooLarge) { stored_asset(tgz, 'f5.txt') }
      Zippy.any_instance.expects(:convert).never
      assert_raises(ConverterTooLarge) { stored_asset(tgz, 'f6.txt') }
      assert_nil RedmineMorePreviews::Lib::RmpFailures.recorded(asset_target(tgz, 'f6.txt'))
    end
  end

  # the first exact match wins over a later entry of the same name, as before
  # the walk went on past it
  def test_first_entry_of_a_name_is_extracted
    tar = build_tar(path('dup.tar'), 'a.txt' => 'first')
    File.open(tar, 'r+b') do |f|
      data = f.read
      f.seek(data.rindex("\0" * 1024))
      Gem::Package::TarWriter.new(f) { |t| t.add_file_simple('a.txt', 0o644, 6) { |io| io.write('second') } }
    end
    assert_equal 'first', stored_asset(tar, 'a.txt')
  end

  private

  def store_listing(archive_path)
    worker = zippy_worker(target: target_of(archive_path), request: fake_request)
    assert worker.preview(File.new(archive_path))
  end

  def asset_target(archive_path, asset)
    File.join(File.dirname(target_of(archive_path)), asset)
  end

  # an asset converted into the cache, as a link of the listing asks for it
  def stored_asset(archive_path, asset)
    zippy_worker(target: asset_target(archive_path, asset), asset: asset).preview(File.new(archive_path))
  end

  def path(name)
    File.join(FileUtils.mkdir_p(File.join(@tmp, 'archives')).first, name)
  end

  # each archive has a preview directory of its own, as each attachment has
  def target_of(archive_path)
    File.join(@tmp, 'cache', File.basename(archive_path), 'preview.html', 'index.html')
  end

  def listing(archive_path)
    worker = zippy_worker(target: target_of(archive_path), request: fake_request)
    html = nil
    worker.preview(File.new(archive_path)) { |preview| html = preview }
    html.to_s.dup.force_encoding(Encoding::UTF_8)
  end

  def extract(archive_path, asset)
    worker = zippy_worker(target: File.join(File.dirname(target_of(archive_path)), asset), asset: asset)
    result = nil
    worker.preview(File.new(archive_path)) { |_preview, asset_data| result = asset_data }
    result
  end

  def zip64_locator
    [0x07064b50, 0, 0, 1].pack('VVQ<V')
  end

  # the end of central directory record ends with the comment's length
  def add_comment(zip, comment)
    data = File.binread(zip)
    data[-2, 2] = [comment.bytesize].pack('v')
    File.binwrite(zip, data + comment)
  end

  def zip64_record(entries, size)
    [0x06064b50, 44, 45, 45, 0, 0, entries, entries, size, 0].pack('VQ<vvVVQ<Q<Q<Q<')
  end

  def fake_request
    ActionDispatch::TestRequest.create(
      'PATH_INFO' => '/attachments/more_preview/1.html',
      'action_dispatch.request.path_parameters' => {controller: 'attachments', action: 'more_preview', id: '1', format: 'html'}
    )
  end

  def with_zippy_limits(values)
    settings = @old_settings.to_h.deep_dup
    settings['converter'] = settings['converter'].to_h
    settings['converter']['zippy'] = settings['converter']['zippy'].to_h.merge(values)
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    yield
  end
end
