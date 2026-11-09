# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# libheif and libtiff allocate memory for the size an image declares, outside
# ImageMagick's limits. Maggie reads that size from the header before it hands
# the file over: the primary image of a HEIC file, the first page of a TIFF file.
class ImageDimensionsTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  FIXTURES = File.expand_path('../../fixtures/maggie', __FILE__)

  def setup
    @dir = Dir.mktmpdir('rmp-image-dimensions')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # the coded size (ispe), before clap crops it to 32x16
  def test_the_heic_fixtures_declare_their_coded_size
    %w(plain.heic plain.heif rotated.heic multi.heic).each do |name|
      assert_equal [64, 64], RedmineMorePreviews.heif_dimensions(File.join(FIXTURES, name)), name
    end
  end

  def test_the_size_of_the_primary_image_is_read
    images = {1 => [16, 16], 2 => [8064, 6048], 3 => [100, 50]}
    assert_equal [8064, 6048], heif(heic_header(images, primary: 2))
    assert_equal [100, 50], heif(heic_header(images, primary: 3))
    assert_equal [16, 16], heif(heic_header(images, primary: 1))
  end

  def test_a_meta_box_after_other_boxes_is_found
    mdat = iso_box('mdat', "\0" * 4096)
    assert_equal [4000, 3000], heif(heic_header({1 => [4000, 3000]}, before: mdat))
    # an mdat with a 64-bit size
    large = [1].pack('N') + 'mdat' + [16 + 64].pack('Q>') + ("\0" * 64)
    assert_equal [4000, 3000], heif(heic_header({1 => [4000, 3000]}, before: large.b))
  end

  # the size of a sequence or of a file whose meta box is beyond the boxes
  # walked, too large or cut short cannot be read
  def test_a_size_that_cannot_be_read_is_nil
    header = heic_header({1 => [4000, 3000]})
    {
      'no meta'      => iso_box('ftyp', 'msf1' + "\0\0\0\0" + 'msf1hevc') + iso_box('moov', "\0" * 32),
      'cut short'    => header[0, header.bytesize - 6],
      'no ispe'      => heic_header({1 => [4000, 3000]}).sub('ispe'.b, 'pixi'.b),
      'zero size'    => heic_header({1 => [0, 3000]}),
      'other item'   => heic_header({1 => [4000, 3000]}, primary: 7),
      'many boxes'   => iso_box('ftyp', 'heic' + "\0\0\0\0") + (iso_box('free') * 16) + header,
      'meta to end'  => iso_box('ftyp', 'heic' + "\0\0\0\0") + iso_box('meta', "\0" * 16, size: 0),
      'huge meta'    => iso_box('ftyp', 'heic' + "\0\0\0\0") + iso_box('meta', ''.b, size: 8 + RedmineMorePreviews::HEIF_META_LIMIT + 1),
      'bad box size' => iso_box('ftyp', 'heic' + "\0\0\0\0") + iso_box('meta', [0].pack('N') + iso_box('pitm', ''.b, size: 4)),
      'not heif'     => 'GIF89a' + ("\0" * 32),
      'empty'        => ''
    }.each do |label, bytes|
      assert_nil heif(bytes), label
    end
    assert_nil RedmineMorePreviews.heif_dimensions(File.join(@dir, 'missing.heic'))
  end

  # flags 1: property indices of two bytes; version 1: item ids of four bytes
  def test_wide_indices_and_item_ids_are_read
    ipco = iso_box('pixi', [0, 1, 8].pack('NCC')) + iso_box('ispe', [0, 300, 200].pack('NNN'))
    ipma = [1 << 24 | 1, 1].pack('NN') + [5, 2, 0x0001, 0x8002].pack('NCnn')
    meta = iso_box('meta', [0].pack('N') + iso_box('pitm', [1 << 24, 5].pack('NN')) +
                           iso_box('iprp', iso_box('ipco', ipco) + iso_box('ipma', ipma)))
    assert_equal [300, 200], heif(iso_box('ftyp', 'heic' + "\0\0\0\0") + meta)
  end

  def test_the_tiff_fixtures_declare_the_size_of_their_first_page
    {'multipage.tif' => [32, 16], 'rotated.tif' => [32, 16], 'cmyk.tif' => [8, 8]}.each do |name, size|
      assert_equal size, RedmineMorePreviews.tiff_dimensions(File.join(FIXTURES, name)), name
    end
  end

  def test_byte_orders_types_and_bigtiff_are_read
    [{}, {order: 'MM'}, {type: 3}, {order: 'MM', type: 3}, {big: true}, {big: true, order: 'MM'},
     {big: true, type: 16}, {big: true, order: 'MM', type: 3}].each do |options|
      assert_equal [7000, 9900], tiff(tiff_header(7000, 9900, **options)), options.inspect
    end
    assert_equal [100_000, 100_000], tiff(tiff_header(100_000, 100_000))
  end

  # the first IFD often follows the image data, at the end of the file
  def test_an_ifd_after_the_image_data_is_read
    assert_equal [640, 480], tiff(tiff_header(640, 480, pad: 1024 * 1024))
  end

  def test_a_size_that_cannot_be_read_is_nil_for_tiff
    header = tiff_header(640, 480)
    {
      'cut short'     => header[0, header.bytesize - 20],
      'offset beyond' => header.dup.tap {|h| h[4, 4] = [1 << 30].pack('V') },
      'offset in head'=> header.dup.tap {|h| h[4, 4] = [4].pack('V') },
      'no entries'    => header.dup.tap {|h| h[24, 2] = [0].pack('v') },
      'many entries'  => header.dup.tap {|h| h[24, 2] = [RedmineMorePreviews::TIFF_MAX_ENTRIES + 1].pack('v') },
      'zero width'    => tiff_header(0, 480),
      'no height'     => header.sub([257].pack('v').b, [258].pack('v').b),
      'rational'      => header.dup.tap {|h| h[24 + 2 + 2, 2] = [5].pack('v') },
      'long8 classic' => tiff_header(640, 480, type: 16),
      'bigtiff bytes' => tiff_header(640, 480, big: true).tap {|h| h[4, 2] = [4].pack('v') },
      'not tiff'      => "IM*\0".b + ("\0" * 32),
      'empty'         => ''
    }.each do |label, bytes|
      assert_nil tiff(bytes), label
    end
    assert_nil RedmineMorePreviews.tiff_dimensions(File.join(@dir, 'missing.tif'))
  end

  private

  def heif(bytes)
    RedmineMorePreviews.heif_dimensions(write(bytes))
  end

  def tiff(bytes)
    RedmineMorePreviews.tiff_dimensions(write(bytes))
  end

  def write(bytes)
    path = File.join(@dir, "image-#{SecureRandom.hex(4)}")
    File.binwrite(path, bytes)
    path
  end
end
