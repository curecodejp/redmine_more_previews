# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Ghostscript runs a file as PostScript unless it starts as a PDF, while Marcel
# reports application/pdf when %PDF- appears near the start. Only a file that
# starts with the PDF header may reach Ghostscript, through any converter and on
# any supported Redmine: Redmine::Thumbnail.valid_pdf_magic? is missing in
# 6.0.0 - 6.0.7 and 6.1.0, and could be bypassed before 6.0.10 / 6.1.3.
class PdfMagicTest < ActiveSupport::TestCase
  PDF = "%PDF-1.4\n%%EOF\n"
  BODY = "newpath 10 10 moveto 100 100 lineto stroke showpage\n"
  POSTSCRIPT = {
    'PostScript' => "%!PS\n#{BODY}",
    'PostScript with %PDF-1.4 on its second line' => "%!PS\n%PDF-1.4\n#{BODY}",
    'PostScript after a space' => " %!PS\n%PDF-1.4\n#{BODY}",
    'PostScript with a short header' => "%!\n%PDF-1.4\n#{BODY}",
    'PostScript without a header' => "#{BODY}%PDF-1.4\n"
  }.freeze

  def setup
    @dir = Dir.mktmpdir('rmp-pdf-magic')
    # as on a Redmine whose own check is missing or can be bypassed
    Redmine::Thumbnail.stubs(:valid_pdf_magic?).returns(true)
    Redmine::Thumbnail.stubs(:gs_available?).returns(true)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_pdf_is_accepted
    assert RedmineMorePreviews.valid_pdf_magic?(file('doc.pdf', PDF))
  end

  def test_pdf_with_a_byte_order_mark_is_accepted
    assert RedmineMorePreviews.valid_pdf_magic?(file('doc.pdf', "\xEF\xBB\xBF".b + PDF.b))
  end

  def test_postscript_is_rejected
    POSTSCRIPT.each do |name, bytes|
      assert_not RedmineMorePreviews.valid_pdf_magic?(file('doc.pdf', bytes)), name
    end
  end

  def test_empty_and_missing_files_are_rejected
    assert_not RedmineMorePreviews.valid_pdf_magic?(file('empty.pdf', ''))
    assert_not RedmineMorePreviews.valid_pdf_magic?(File.join(@dir, 'missing.pdf'))
  end

  def test_peek_does_not_hand_postscript_to_redmine_thumbnails
    Redmine::Thumbnail.expects(:generate).never
    POSTSCRIPT.each do |name, bytes|
      %w(png jpg gif).each do |format|
        peek(file('doc.pdf', bytes), format).convert
      end
    end
  end

  def test_peek_hands_a_pdf_to_redmine_thumbnails
    source = file('doc.pdf', PDF)
    worker = peek(source, 'png')
    Redmine::Thumbnail.expects(:generate).with(source, worker.tmptarget, 800, true).once
    worker.convert
  end

  def test_peek_passes_a_pdf_through_without_conversion
    source = file('doc.pdf', "%!PS\n#{BODY}")
    worker = peek(source, 'pdf')
    Redmine::Thumbnail.expects(:generate).never
    worker.convert
    assert_equal File.binread(source), File.binread(worker.tmptarget)
  end

  private

  def file(name, bytes)
    path = File.join(Dir.mktmpdir('src', @dir), name)
    File.binwrite(path, bytes)
    path
  end

  def peek(source, format)
    worker = Peek.allocate
    worker.source = source
    worker.preview_format = format
    worker.tmpdir = Dir.mktmpdir('tmp', @dir)
    worker.tmptarget = File.join(worker.tmpdir, "index.#{format}")
    worker
  end
end
