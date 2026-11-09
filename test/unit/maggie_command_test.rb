# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'

# Maggie hands the file to ImageMagick (and, for a PDF, to Ghostscript). Neither the
# input nor the output may be interpreted by ImageMagick as anything other than
# the image type the converter was chosen for.
class MaggieCommandTest < ActiveSupport::TestCase
  extend RedmineMorePreviews::TestHelper
  PNG  = "\x89PNG\r\n\x1a\n".b + ("\0" * 32)
  JPEG = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00".b + ("\0" * 32)
  GIF  = 'GIF89a'.b + ("\0" * 32)
  BMP  = 'BM'.b + ("\0" * 32)
  PDF  = "%PDF-1.4\n%%EOF\n"
  # PostScript that Marcel reports as application/pdf (%PDF- within the first bytes,
  # no %! at the very start); Ghostscript runs it as PostScript
  DISGUISED_PS = " %!PS\n%PDF-1.4\nnewpath 10 10 moveto 100 100 lineto stroke showpage\n"

  def self.ftyp(major, compatible)
    body = major + "\0\0\0\0" + compatible.join
    ([8 + body.bytesize].pack('N') + 'ftyp' + body).b + ("\0" * 32)
  end

  # headers that declare a size (see RedmineMorePreviews.heif_dimensions)
  HEIC = heic_header({1 => [64, 64]})
  HEIF = heic_header({1 => [64, 64]}, major: 'mif1')
  HEIC_SEQUENCE = heic_header({1 => [64, 64]}, major: 'hevc')
  HEIF_SEQUENCE = heic_header({1 => [64, 64]}, major: 'msf1')
  AVIF = ftyp('avif', %w(avif mif1 miaf))
  TIFF = tiff_header(32, 16)
  BIGTIFF = tiff_header(32, 16, order: 'MM', big: true)
  FIXTURES = File.expand_path('../../fixtures/maggie', __FILE__)
  # every image format enabled, as an administrator who previews all of them
  ALL_ENABLED = {'mime_types' => %w(png jpg gif bmp pdf heic heif tif tiff).
                   to_h {|ext| [ext, {'active' => '1', 'format' => 'png'}]}}.freeze

  def setup
    @dir = Dir.mktmpdir('rmp-maggie')
    Redmine::Thumbnail.stubs(:gs_available?).returns(true)
    RedmineMorePreviews.stubs(:imagemagick_reads?).returns(true)
    @settings = ALL_ENABLED
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_postscript_disguised_as_pdf_is_not_handed_to_imagemagick
    worker = worker_for('doc.pdf', DISGUISED_PS)
    assert_equal 'application/pdf', Marcel::MimeType.for(Pathname.new(worker.source), name: 'doc.pdf')
    worker.expects(:command).never
    worker.convert
  end

  def test_pdf_with_a_byte_order_mark_is_accepted
    worker = worker_for('doc.pdf', "\xEF\xBB\xBF".b + PDF.b)
    convert, = commands(worker)
    assert_includes convert, "pdf:#{worker.source}[0]"
  end

  def test_pdf_is_read_as_pdf_into_a_fixed_output_name
    worker = worker_for('doc.pdf', PDF)
    convert, move = commands(worker)
    assert_includes convert, "pdf:#{worker.source}[0]"
    assert_equal 'png:./out.png', convert.last
    assert_equal './out.png', move[1]
  end

  def test_pdf_without_ghostscript_does_not_copy_pdf_as_raster_preview
    Redmine::Thumbnail.stubs(:gs_available?).returns(false)

    %w(png jpg gif).each do |format|
      worker = worker_for('doc.pdf', PDF)
      worker.preview_format = format
      worker.tmptarget = File.join(worker.tmpdir, "index.#{format}")

      worker.expects(:command).never
      assert_nil worker.convert
      assert_not File.exist?(worker.tmptarget), "PDF must not be served as #{format}"
    end
  end

  def test_regular_image_conversion_does_not_require_ghostscript
    Redmine::Thumbnail.stubs(:gs_available?).returns(false)
    worker = worker_for('a.png', PNG)

    convert, move = commands(worker)
    assert_includes convert, "png:#{worker.source}"
    assert_equal './out.png', move[1]
  end

  def test_images_are_read_with_their_coder
    {'a.png' => [PNG, 'png'], 'a.jpg' => [JPEG, 'jpeg'], 'a.gif' => [GIF, 'gif'], 'a.bmp' => [BMP, 'bmp']}.
      each do |name, (bytes, coder)|
      worker = worker_for(name, bytes)
      convert, = commands(worker)
      assert_includes convert, "#{coder}:#{worker.source}", name
    end
  end

  # the entry name of a repository file is chosen by whoever commits it: ImageMagick
  # reads "|cmd" as a pipe, "-x" as an option and "txt:x" as another coder
  def test_output_name_does_not_depend_on_the_file_name
    ['|touch pwned.png', '-write.png', 'txt:a.png'].each do |name|
      worker = worker_for(name, PNG)
      convert, move = commands(worker)
      assert_equal 'png:./out.png', convert.last, name
      assert_equal './out.png', move[1], name
      assert_not convert.any? {|arg| arg.include?(File.basename(name, '.png')) && arg != "png:#{worker.source}"}, name
    end
  end

  def test_limits_precede_the_input
    {'a.png' => PNG, 'doc.pdf' => PDF, 'a.heic' => HEIC, 'a.tif' => TIFF}.each do |name, bytes|
      worker = worker_for(name, bytes)
      convert, = commands(worker)
      input = convert.index {|arg| arg.end_with?(worker.source, "#{worker.source}[0]")}
      assert input, "#{name}: input"
      %w(width height area memory map disk).each do |resource|
        limit = convert.each_cons(2).find_index {|a, b| a == '-limit' && b == resource}
        assert limit && limit < input, "#{name}: -limit #{resource} before the input"
      end
    end
  end

  # the limits and coder prefixes must be accepted by the installed ImageMagick
  def test_png_is_converted
    skip 'ImageMagick is not available' unless Redmine::Thumbnail.convert_available?
    source = File.join(@dir, 'real.png')
    assert system(Maggie::CONVERT_BIN, '-size', '8x8', 'xc:red', "png:#{source}")
    worker = worker_for('real.png', File.binread(source))
    worker.convert
    assert File.file?(worker.tmptarget)
    assert_equal "\x89PNG".b, File.binread(worker.tmptarget, 4)
  end

  # a HEIC file holds several images (a burst, a sequence, an edit and its
  # original): only the first ([0], the primary image) is previewed, under the
  # fixed output name. libheif rotates the image as the file says, so it is not
  # rotated again; the EXIF orientation the file still carries is dropped, or
  # the browser would rotate the preview once more.
  # Marcel reports video/quicktime for most HEVC brands but heic (f.i. heix of
  # Canon's HEIF, hevc and msf1 of sequences)
  def test_heif_is_read_with_the_heic_coder_first_image_only
    {'a.heic' => HEIC, 'a.heif' => HEIF, 'burst.heic' => HEIC_SEQUENCE, 'burst.heif' => HEIF_SEQUENCE,
     'IMG_0001.HEIC' => HEIC, 'canon.heif' => self.class.heic_header({1 => [64, 64]}, major: 'heix')}.each do |name, bytes|
      worker = worker_for(name, bytes)
      convert, move = commands(worker)
      assert_includes convert, "heic:#{worker.source}[0]", name
      assert_equal 'png:./out.png', convert.last, name
      assert_equal './out.png', move[1], name
      assert_equal 'exif', convert[convert.index('+profile') + 1], name
      assert_not_includes convert, '-auto-orient', name
    end
  end

  # a TIFF file holds several pages: only the first is previewed. ImageMagick
  # does not apply the TIFF orientation itself, and a browser shows CMYK badly
  def test_tiff_is_read_with_the_tiff_coder_first_page_only
    {'scan.tif' => TIFF, 'scan.tiff' => TIFF, 'SCAN.TIF' => TIFF, 'big.tif' => BIGTIFF}.each do |name, bytes|
      worker = worker_for(name, bytes)
      convert, move = commands(worker)
      assert_includes convert, "tiff:#{worker.source}[0]", name
      assert_equal 'png:./out.png', convert.last, name
      assert_equal './out.png', move[1], name
      assert_includes convert, '-auto-orient', name
      assert_equal 'exif', convert[convert.index('+profile') + 1], name
      assert_equal 'sRGB', convert[convert.index('-colorspace') + 1], name
    end
  end

  # Marcel reports image/heic or image/tiff by the name alone when the content is
  # unknown, and image/avif for an AVIF file: none reaches ImageMagick
  def test_content_that_is_not_the_named_format_is_not_converted
    {'junk.heic' => 'junk', 'JUNK.HEIC' => 'junk', 'junk.heif' => "\0\0\0\x18ftyp".b,
     'avif.heic' => AVIF, 'mixed.heic' => self.class.ftyp('mif1', %w(mif1 heic avif)),
     'branded.heic' => self.class.ftyp('heic', %w(mif1 heic avis)),
     'junk.tif' => 'junk', 'JUNK.TIFF' => "IM*\0".b}.each do |name, bytes|
      worker = worker_for(name, bytes)
      worker.expects(:command).never
      assert_nil worker.convert, name
      assert_not File.exist?(worker.tmptarget), name
    end
  end

  # a file named like a HEIC or TIFF image is read as what it holds
  def test_an_image_named_heic_or_tiff_is_read_as_its_content
    {'a.heic' => [PNG, 'png'], 'A.HEIC' => [JPEG, 'jpeg'], 'a.tif' => [GIF, 'gif'], 'a.tiff' => [PNG, 'png']}.
      each do |name, (bytes, coder)|
      worker = worker_for(name, bytes)
      convert, = commands(worker)
      assert_includes convert, "#{coder}:#{worker.source}", name
    end
  end

  # an administrator who enabled only PNG previews does not have HEIC or TIFF
  # content of a file named .png parsed by libheif or libtiff
  def test_heif_and_tiff_are_converted_only_when_enabled
    @settings = {'mime_types' => {'png' => {'active' => '1', 'format' => 'png'},
                                  'heic' => {'active' => '0', 'format' => 'png'}}}
    {'a.png' => HEIC, 'b.png' => TIFF, 'c.heic' => HEIC, 'd.tif' => TIFF}.each do |name, bytes|
      worker = worker_for(name, bytes)
      worker.expects(:command).never
      assert_nil worker.convert, name
    end

    @settings = {'mime_types' => {'heif' => {'active' => '1'}, 'tiff' => {'active' => '1'}}}
    {'a.heic' => [HEIC, 'heic'], 'a.tif' => [TIFF, 'tiff']}.each do |name, (bytes, coder)|
      worker = worker_for(name, bytes)
      convert, = commands(worker)
      assert_includes convert, "#{coder}:#{worker.source}[0]", name
    end
  end

  # without the coder (f.i. ImageMagick without libheif) nothing is converted,
  # and the other images are converted as before
  def test_without_the_coder_nothing_is_converted_and_other_images_are
    RedmineMorePreviews.stubs(:imagemagick_reads?).returns(false)
    {'a.heic' => HEIC, 'a.tif' => TIFF}.each do |name, bytes|
      worker = worker_for(name, bytes)
      worker.expects(:command).never
      assert_nil worker.convert, name
      assert_not File.exist?(worker.tmptarget), name
    end
    {'a.png' => [PNG, 'png'], 'a.jpg' => [JPEG, 'jpeg']}.each do |name, (bytes, coder)|
      worker = worker_for(name, bytes)
      convert, = commands(worker)
      assert_includes convert, "#{coder}:#{worker.source}", name
    end
  end

  # libheif and libtiff allocate memory for the size the header declares: a
  # larger image than max_megapixels is answered with 413, without a conversion
  def test_an_image_larger_than_the_limit_is_not_converted
    {'big.heic' => self.class.heic_header({1 => [16, 16], 2 => [10_000, 10_000]}, primary: 2),
     'big.tif' => self.class.tiff_header(10_000, 10_000),
     'wide.tiff' => self.class.tiff_header(100_000, 641, big: true)}.each do |name, bytes|
      worker = worker_for(name, bytes)
      worker.expects(:command).never
      assert_raises(RedmineMorePreviews::Exceptions::ConverterTooLarge, name) { worker.convert }
      assert_not File.exist?(worker.tmptarget), name
    end
  end

  # the photos of phones (48 and 50 megapixels) and the limit itself pass
  def test_an_image_within_the_limit_is_converted
    {'iphone.heic' => [self.class.heic_header({1 => [8064, 6048]}), 'heic'],
     'pixel.heif' => [self.class.heic_header({1 => [8160, 6144]}, major: 'mif1'), 'heic'],
     'limit.tif' => [self.class.tiff_header(8000, 8000), 'tiff']}.each do |name, (bytes, coder)|
      convert, = commands(worker_for(name, bytes))
      assert_includes convert.join(' '), "#{coder}:", name
    end
  end

  def test_the_limit_is_a_setting
    @settings = ALL_ENABLED.merge('max_megapixels' => '100')
    convert, = commands(worker_for('big.tif', self.class.tiff_header(10_000, 10_000)))
    assert_includes convert.join(' '), 'tiff:'

    @settings = ALL_ENABLED.merge('max_megapixels' => '1')
    worker = worker_for('small.tif', self.class.tiff_header(1001, 1000))
    assert_raises(RedmineMorePreviews::Exceptions::ConverterTooLarge) { worker.convert }

    # not a positive number: the default
    ['', '0', '-5', 'x'].each do |value|
      @settings = ALL_ENABLED.merge('max_megapixels' => value)
      worker = worker_for('big.tif', self.class.tiff_header(10_000, 10_000))
      assert_raises(RedmineMorePreviews::Exceptions::ConverterTooLarge, value) { worker.convert }
      convert, = commands(worker_for('limit.tif', self.class.tiff_header(8000, 8000)))
      assert_includes convert.join(' '), 'tiff:', value
    end
  end

  # a size that cannot be read (f.i. a sequence without a primary image, a cut
  # header) is not converted; the other images do not declare one
  def test_an_image_whose_size_cannot_be_read_is_not_converted
    {'burst.heic' => self.class.iso_box('ftyp', 'hevc' + "\0\0\0\0" + 'msf1hevc') + self.class.iso_box('moov', "\0" * 32),
     'cut.tif' => "II*\0".b + ("\0" * 32),
     'no-ispe.heic' => HEIC.sub('ispe'.b, 'pixi'.b)}.each do |name, bytes|
      worker = worker_for(name, bytes)
      worker.expects(:command).never
      assert_nil worker.convert, name
    end
    {'a.png' => [PNG, 'png'], 'a.jpg' => [JPEG, 'jpeg']}.each do |name, (bytes, coder)|
      worker = worker_for(name, bytes)
      convert, = commands(worker)
      assert_includes convert, "#{coder}:#{worker.source}", name
    end
  end

  # real conversions: skipped where ImageMagick reads no HEIC (or TIFF).
  # RMP_TEST_CONVERT_BIN runs them with another program, f.i. magick
  def test_heic_and_heif_are_converted
    %w(plain.heic plain.heif).each do |fixture|
      output = real_conversion(fixture)
      assert_equal "\x89PNG".b, File.binread(output, 4), fixture
      assert_equal [32, 16], dimensions(output), fixture
    end
  end

  # the primary image is the second in the file and smaller than the first
  def test_the_primary_image_of_a_heic_file_is_previewed
    assert_equal [32, 16], dimensions(real_conversion('multi.heic'))
  end

  # stored 32x16, red left of blue, with irot and EXIF orientation 6 as an
  # iPhone writes them: shown 16x32 with red on top, rotated once
  def test_a_rotated_heic_is_rotated_once
    output = real_conversion('rotated.heic')
    assert_equal [16, 32], dimensions(output)
    assert_color :red, pixel(output, 8, 4)
    assert_color :blue, pixel(output, 8, 28)
    assert_no_exif output
  end

  def test_the_first_page_of_a_tiff_is_previewed
    output = real_conversion('multipage.tif')
    assert_equal [32, 16], dimensions(output)
  end

  # stored 32x16, red left of blue, orientation 6: shown 16x32 with red on top
  def test_a_rotated_tiff_is_rotated
    %w(png jpg).each do |format|
      output = real_conversion('rotated.tif', format)
      assert_equal [16, 32], dimensions(output), format
      assert_color :red, pixel(output, 8, 4)
      assert_color :blue, pixel(output, 8, 28)
    end
  end

  def test_a_cmyk_tiff_is_shown_in_srgb
    output = real_conversion('cmyk.tif', 'jpg')
    assert_equal 'sRGB', identify(output, '%[colorspace]')
    assert_color :red, pixel(output, 4, 4)
  end

  def test_a_broken_heic_fails_without_a_preview
    assert_broken_fails 'plain.heic'
  end

  def test_a_broken_tiff_fails_without_a_preview
    assert_broken_fails 'multipage.tif'
  end

  # the limits of ImageMagick bound the images libheif and libtiff decode
  def test_a_heic_beyond_the_limits_fails_without_a_preview
    assert_beyond_limits_fails 'plain.heic'
  end

  def test_a_tiff_beyond_the_limits_fails_without_a_preview
    assert_beyond_limits_fails 'multipage.tif'
  end

  private

  # the file cut after 200 bytes: its header is intact, its image data is not
  # the header stays readable (the size it declares is read first): the image
  # data of the HEIC file is cut short, the TIFF file names an unknown
  # compression (with broken data, ImageMagick writes an empty image)
  def assert_broken_fails(fixture)
    bytes = File.binread(File.join(FIXTURES, fixture))
    broken = if fixture.end_with?('.tif')
               ifd = bytes[4, 4].unpack1('V')
               entry = (0...bytes[ifd, 2].unpack1('v')).map {|i| ifd + 2 + (i * 12) }.find {|e| bytes[e, 2].unpack1('v') == 259 }
               bytes.dup.tap {|b| b[entry + 8, 2] = [0x7777].pack('v') }
             else
               mdat = bytes.index('mdat'.b) - 4
               bytes[0, mdat + 24]
             end
    assert RedmineMorePreviews.send(fixture.end_with?('.tif') ? :tiff_dimensions : :heif_dimensions, write_fixture(broken)), fixture
    assert_raises(RedmineMorePreviews::Exceptions::ConverterShellError) do
      real_conversion(fixture, 'png', broken)
    end
    assert_not File.exist?(@worker.tmptarget)
  end

  def assert_beyond_limits_fails(fixture)
    limited = "#{Redmine::Utils::Shell.shell_quote(test_convert_bin)} -limit width 8 -limit height 8"
    RedmineMorePreviews.stubs(:convert_command).returns(limited)
    assert_raises(RedmineMorePreviews::Exceptions::ConverterShellError) { real_conversion(fixture) }
    assert_not File.exist?(@worker.tmptarget)
  end

  def test_convert_bin
    ENV['RMP_TEST_CONVERT_BIN'].presence || RedmineMorePreviews::CONVERT_BIN
  end

  # converts a fixture (or bytes under its name) with the installed ImageMagick
  def real_conversion(fixture, format = 'png', bytes = nil)
    coder = fixture.end_with?('.tif') ? 'TIFF' : 'HEIC'
    RedmineMorePreviews.unstub(:imagemagick_reads?)
    RedmineMorePreviews.stubs(:convert_bin).returns(test_convert_bin)
    unless RedmineMorePreviews.imagemagick_reads?(coder)
      # CI sets it: a skipped conversion must not pass for a verified one
      flunk "#{test_convert_bin} reads no #{coder}" if ENV['RMP_REQUIRE_IMAGE_CODERS'] == '1'
      skip "#{test_convert_bin} reads no #{coder}"
    end
    @worker = worker_for(fixture, bytes || File.binread(File.join(FIXTURES, fixture)))
    @worker.preview_format = format
    @worker.tmptarget = File.join(@worker.tmpdir, "index.#{format}")
    @worker.convert
    @worker.tmptarget
  end

  def identify(path, format)
    out, status = Open3.capture2(test_convert_bin, path, '-format', format, 'info:')
    assert status.success?, "#{test_convert_bin} cannot read #{path}"
    out.strip
  end

  def dimensions(path)
    identify(path, '%w %h').split.map(&:to_i)
  end

  def pixel(path, x, y)
    identify(path, "%[fx:int(255*p{#{x},#{y}}.r)] %[fx:int(255*p{#{x},#{y}}.g)] %[fx:int(255*p{#{x},#{y}}.b)]").
      split.map(&:to_i)
  end

  # lossy formats: the colour, not the exact value
  def assert_color(color, (r, g, b))
    expected = {red: r > 180 && g < 80 && b < 80, blue: b > 180 && r < 80 && g < 80}
    assert expected.fetch(color), "expected #{color}, got #{[r, g, b].inspect}"
  end

  # no EXIF in the preview (PNG eXIf chunk or JPEG APP1), whose orientation a
  # browser would apply once more
  def assert_no_exif(path)
    data = File.binread(path)
    assert_not data.include?('eXIf'.b), 'PNG preview carries EXIF'
    assert_not data.include?("Exif\0\0".b), 'preview carries EXIF'
  end

  def write_fixture(bytes)
    path = File.join(Dir.mktmpdir('fixture', @dir), 'image')
    File.binwrite(path, bytes)
    path
  end

  def worker_for(name, bytes)
    work = Dir.mktmpdir('work', @dir)
    source = File.join(work, name)
    File.binwrite(source, bytes)
    worker = Maggie.allocate
    worker.source = source
    worker.preview_format = 'png'
    worker.tmpdir = Dir.mktmpdir('tmp', @dir)
    worker.tmptarget = File.join(worker.tmpdir, 'index.png')
    worker.stubs(:converter_settings).returns(@settings)
    worker
  end

  # the convert and the move command, split into arguments as the shell does
  def commands(worker)
    cmd = nil
    worker.expects(:command).with {|c| cmd = c}.returns(true)
    worker.convert
    parts = cmd.split('; ').map {|part| Shellwords.split(part)}
    [parts.find {|p| p.first.end_with?('convert', 'magick')}, parts.find {|p| p.first == 'mv'}]
  end
end
