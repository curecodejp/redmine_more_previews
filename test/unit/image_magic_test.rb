# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'

# Marcel reports image/heic or image/tiff for a file by its name alone when its
# content is unknown, and libheif decodes whatever codec an image item names,
# not only HEVC. Only a file that starts as the format it claims may reach the
# HEIC or TIFF coder of ImageMagick, and an AVIF file never the HEIC coder.
class ImageMagicTest < ActiveSupport::TestCase
  def setup
    @dir = Dir.mktmpdir('rmp-image-magic')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_heic_brands_are_accepted
    %w(heic heix hevc hevx heim heis hevm hevs).each do |brand|
      assert RedmineMorePreviews.valid_heif_magic?(file(ftyp(brand, %w(mif1 heic)))), brand
    end
  end

  def test_mif1_with_a_hevc_brand_is_accepted
    assert RedmineMorePreviews.valid_heif_magic?(file(ftyp('mif1', %w(mif1 heic miaf))))
    assert RedmineMorePreviews.valid_heif_magic?(file(ftyp('msf1', %w(msf1 hevc))))
  end

  def test_mif1_without_a_hevc_brand_is_rejected
    assert_not RedmineMorePreviews.valid_heif_magic?(file(ftyp('mif1', %w(mif1 miaf))))
    assert_not RedmineMorePreviews.valid_heif_magic?(file(ftyp('mif1', %w(mif1 jpeg))))
  end

  def test_avif_is_rejected_whatever_other_brands_it_names
    [ftyp('avif', %w(avif mif1 miaf)), ftyp('avis', %w(avis msf1)),
     ftyp('mif1', %w(mif1 avif miaf)), ftyp('mif1', %w(mif1 heic avif)),
     ftyp('heic', %w(mif1 heic avif)), ftyp('heic', %w(avis))].each do |bytes|
      assert_not RedmineMorePreviews.valid_heif_magic?(file(bytes)), bytes.inspect
    end
  end

  # an AVIF brand far down a long brand list is still seen
  def test_avif_after_many_brands_is_rejected
    assert_not RedmineMorePreviews.valid_heif_magic?(file(ftyp('heic', (%w(mif1) * 20) + %w(avif))))
    assert RedmineMorePreviews.valid_heif_magic?(file(ftyp('heic', (%w(mif1) * 20) + %w(heic))))
  end

  # an ftyp box too long to read is not trusted
  def test_an_overlong_ftyp_box_is_rejected
    assert_not RedmineMorePreviews.valid_heif_magic?(file(ftyp('heic', %w(mif1) * 100)))
  end

  def test_brands_beyond_the_ftyp_box_are_ignored
    # "heic" follows the box, in the next one: it is not a compatible brand
    bytes = ftyp('mif1', %w(mif1)) + [16].pack('N') + 'free' + 'heic' + 'heic'
    assert_not RedmineMorePreviews.valid_heif_magic?(file(bytes))
  end

  def test_other_content_is_not_heif
    ['', 'junk', "\x89PNG\r\n\x1a\n".b + ("\0" * 32), "\0\0\0\x18ftxpheic".b + ("\0" * 16),
     "\0\0\0\x04ftypheic".b, "\0\0\0\x18ftyp".b].each do |bytes|
      assert_not RedmineMorePreviews.valid_heif_magic?(file(bytes)), bytes.inspect
    end
  end

  def test_a_missing_file_is_not_heif
    assert_not RedmineMorePreviews.valid_heif_magic?(File.join(@dir, 'missing.heic'))
  end

  def test_tiff_byte_orders_and_bigtiff_are_accepted
    ["II*\0".b, "MM\0*".b, "II+\0".b, "MM\0+".b].each do |magic|
      assert RedmineMorePreviews.valid_tiff_magic?(file(magic + ("\0" * 12))), magic.inspect
    end
  end

  def test_other_content_is_not_tiff
    ['', 'II', "IM*\0".b, "II\0*".b, "MM*\0".b, 'GIF89a', "\0\0\0\x18ftypheic".b].each do |bytes|
      assert_not RedmineMorePreviews.valid_tiff_magic?(file(bytes)), bytes.inspect
    end
    assert_not RedmineMorePreviews.valid_tiff_magic?(File.join(@dir, 'missing.tif'))
  end

  IM6_FORMATS = <<~LIST
       Format  Module    Mode  Description
    -------------------------------------------------------------------------------
         HEIC* HEIC      rw+   Apple High efficiency Image Format (1.17.6)
         TIFF* TIFF      rw+   Tagged Image File Format (LIBTIFF, Version 4.5.1)
       TIFF64* TIFF      rw-   Tagged Image File Format (64-bit) (LIBTIFF, Version 4.5.1)
  LIST

  IM7_FORMATS = <<~LIST
       Format  Module    Mode  Description
    -------------------------------------------------------------------------------
         AVIF  HEIC      rw+   AV1 Image File Format (1.19.8)
         HEIC  HEIC      rw+   High Efficiency Image Format (1.19.8)
         TIFF  TIFF      rw+   Tagged Image File Format (LIBTIFF, Version 4.7.0)
  LIST

  # ImageMagick 6.9.12-98 on Ubuntu 24.04 (libheif1): no module for HEIC
  UBUNTU_IM6_FORMATS = <<~LIST
       Format  Module    Mode  Description
    -------------------------------------------------------------------------------
         HEIC            r--   Apple High efficiency Image Format (1.17.6)
         HEIF            r--   Apple High efficiency Image Format (1.17.6)
         TIFF* TIFF      rw+   Tagged Image File Format (LIBTIFF, Version 4.5.1)
  LIST

  NO_HEIC = <<~LIST
       Format  Module    Mode  Description
    -------------------------------------------------------------------------------
         HEIF  HEIC      -w+   Writes only
         TIFF* TIFF      rw+   Tagged Image File Format (LIBTIFF, Version 4.0.9)
  LIST

  def test_coders_listed_as_readable_by_imagemagick_6_and_7
    [IM6_FORMATS, IM7_FORMATS, UBUNTU_IM6_FORMATS].each do |list|
      with_formats(list) do
        assert RedmineMorePreviews.imagemagick_reads?('HEIC')
        assert RedmineMorePreviews.imagemagick_reads?('TIFF')
        assert_not RedmineMorePreviews.imagemagick_reads?('JP2')
      end
    end
  end

  def test_a_coder_that_is_missing_or_writes_only_is_not_readable
    with_formats(NO_HEIC) do
      assert_not RedmineMorePreviews.imagemagick_reads?('HEIC')
      assert_not RedmineMorePreviews.imagemagick_reads?('HEIF')
      assert RedmineMorePreviews.imagemagick_reads?('TIFF')
    end
  end

  # an empty module column: the description does not count as the mode
  def test_a_coder_without_a_module_is_read_by_its_mode
    with_formats("     HEIC            ---   reads nothing\n     TIFF            -w-   rw+ in the description\n") do
      assert_not RedmineMorePreviews.imagemagick_reads?('HEIC')
      assert_not RedmineMorePreviews.imagemagick_reads?('TIFF')
    end
  end

  def test_only_the_format_column_names_the_coder
    # "TIFF64" and the "TIFF" module of other formats are not the TIFF format
    with_formats(" TIFF64* TIFF      rw-   64-bit\n   PTIF* TIFF  rw+  Pyramid\n") do
      assert_not RedmineMorePreviews.imagemagick_reads?('TIFF')
    end
  end

  # the program is run as it is named, without a shell, once per process
  def test_imagemagick_is_asked_without_a_shell_and_once
    calls = File.join(@dir, 'calls')
    bin = script('my convert; touch pwned', "echo run >> #{calls.shellescape}\ncat <<'LIST'\n#{IM6_FORMATS}LIST\n")
    with_bin(bin) do
      assert RedmineMorePreviews.imagemagick_reads?('HEIC')
      assert RedmineMorePreviews.imagemagick_reads?('TIFF')
    end
    assert_equal ["run\n"], File.readlines(calls)
    assert_not File.exist?(File.join(@dir, 'pwned'))
  end

  # requests that come together at the start ask the program once
  def test_concurrent_first_requests_ask_imagemagick_once
    calls = File.join(@dir, 'calls')
    bin = script('convert', "echo run >> #{calls.shellescape}\nsleep 0.5\ncat <<'LIST'\n#{IM6_FORMATS}LIST\n")
    with_bin(bin) do
      results = Array.new(4) { Thread.new { RedmineMorePreviews.imagemagick_reads?('HEIC') } }.map(&:value)
      assert_equal [true] * 4, results
    end
    assert_equal ["run\n"], File.readlines(calls)
  end

  # a failure is asked again: one that passes (a fork error, a program being
  # upgraded) must not turn HEIC and TIFF off until Redmine restarts
  def test_a_missing_or_failing_imagemagick_reads_nothing_and_is_asked_again
    with_bin(File.join(@dir, 'missing')) do
      assert_not RedmineMorePreviews.imagemagick_reads?('TIFF')
    end
    bin = script('convert', "exit 1\n")
    with_bin(bin) do
      assert_not RedmineMorePreviews.imagemagick_reads?('TIFF')
      File.write(bin, "#!/bin/sh\ncat <<'LIST'\n#{IM6_FORMATS}LIST\n")
      assert RedmineMorePreviews.imagemagick_reads?('TIFF')
    end
  end

  # Windows has no process groups: pgroup raises ArgumentError there
  def test_imagemagick_is_asked_in_a_new_process_group_on_windows
    Redmine::Platform.stubs(:mswin?).returns(true)
    Open3.expects(:popen2e).with('convert', '-list', 'format', {:new_pgroup => true}).returns(IM6_FORMATS)
    with_bin('convert') do
      assert RedmineMorePreviews.imagemagick_reads?('HEIC')
    end
  end

  # asked within a request (the settings, the first conversion): it is stopped
  def test_a_hanging_imagemagick_is_stopped
    RedmineMorePreviews.stubs(:imagemagick_list_timeout).returns(1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    with_bin(script('convert', "exec sleep 30\n")) do
      assert_not RedmineMorePreviews.imagemagick_reads?('TIFF')
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
  end

  private

  def ftyp(major, compatible)
    body = major + "\0\0\0\0" + compatible.join
    [8 + body.bytesize].pack('N') + 'ftyp' + body + ("\0" * 16)
  end

  def file(bytes)
    path = File.join(Dir.mktmpdir('f', @dir), 'image')
    File.binwrite(path, bytes.b)
    path
  end

  def with_formats(list)
    RedmineMorePreviews.reset_imagemagick_formats
    RedmineMorePreviews.stubs(:imagemagick_list_formats).returns(list)
    yield
  ensure
    RedmineMorePreviews.unstub(:imagemagick_list_formats)
    RedmineMorePreviews.reset_imagemagick_formats
  end

  def with_bin(bin)
    RedmineMorePreviews.reset_imagemagick_formats
    RedmineMorePreviews.stubs(:convert_bin).returns(bin)
    yield
  ensure
    RedmineMorePreviews.unstub(:convert_bin)
    RedmineMorePreviews.reset_imagemagick_formats
  end

  def script(name, body)
    path = File.join(Dir.mktmpdir('bin', @dir), name)
    File.write(path, "#!/bin/sh\n#{body}")
    File.chmod(0o755, path)
    path
  end
end
