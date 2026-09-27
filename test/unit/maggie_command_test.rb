# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'

# Maggie hands the file to ImageMagick (and, for a PDF, to Ghostscript). Neither the
# input nor the output may be interpreted by ImageMagick as anything other than
# the image type the converter was chosen for.
class MaggieCommandTest < ActiveSupport::TestCase
  PNG  = "\x89PNG\r\n\x1a\n".b + ("\0" * 32)
  JPEG = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00".b + ("\0" * 32)
  GIF  = 'GIF89a'.b + ("\0" * 32)
  BMP  = 'BM'.b + ("\0" * 32)
  PDF  = "%PDF-1.4\n%%EOF\n"
  # PostScript that Marcel reports as application/pdf (%PDF- within the first bytes,
  # no %! at the very start); Ghostscript runs it as PostScript
  DISGUISED_PS = " %!PS\n%PDF-1.4\nnewpath 10 10 moveto 100 100 lineto stroke showpage\n"

  def setup
    @dir = Dir.mktmpdir('rmp-maggie')
    Redmine::Thumbnail.stubs(:gs_available?).returns(true)
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
    %w(a.png doc.pdf).each do |name|
      worker = worker_for(name, name.end_with?('.pdf') ? PDF : PNG)
      convert, = commands(worker)
      input = convert.index {|arg| arg.end_with?(worker.source, "#{worker.source}[0]")}
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

  private

  def worker_for(name, bytes)
    work = Dir.mktmpdir('work', @dir)
    source = File.join(work, name)
    File.binwrite(source, bytes)
    worker = Maggie.allocate
    worker.source = source
    worker.preview_format = 'png'
    worker.tmpdir = Dir.mktmpdir('tmp', @dir)
    worker.tmptarget = File.join(worker.tmpdir, 'index.png')
    worker.stubs(:converter_settings).returns({})
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
