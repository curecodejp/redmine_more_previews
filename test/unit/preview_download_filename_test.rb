# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class PreviewDownloadFilenameTest < ActiveSupport::TestCase
  def setup
    @helper = Object.new.extend(RedmineMorePreviews::ControllerHelper)
  end

  def test_pdf_name_uses_the_original_basename_without_its_last_extension
    assert_equal 'report.pdf', download_name('report.xlsx', 'index.pdf')
    assert_equal 'meeting.pdf', download_name('meeting.docx', 'index.pdf')
    assert_equal 'report.2026.pdf', download_name('report.2026.xlsx', 'index.pdf')
    assert_equal 'report.pdf', download_name('report.pdf', 'index.pdf')
    assert_equal 'README.pdf', download_name('README', 'index.pdf')
  end

  def test_multibyte_name_and_subdirectory_do_not_change_the_basename
    assert_equal '売上集計.pdf', download_name('売上集計.xlsx', 'index.pdf')
    assert_equal '月次.2026.pdf', download_name('path/to/月次.2026.xlsx', 'index.pdf')
    assert_equal 'windows.pdf', download_name('folder\\windows.xlsx', 'index.pdf')
  end

  def test_other_preview_formats_keep_the_existing_internal_name
    assert_equal 'index.html', download_name('report.xlsx', 'index.html')
    assert_equal 'index.txt', download_name('report.xlsx', 'index.txt')
    assert_equal 'index.png', download_name('report.xlsx', 'index.png')
  end

  def test_missing_source_name_keeps_the_internal_pdf_name
    assert_equal 'index.pdf', download_name(nil, 'index.pdf')
    assert_equal 'index.pdf', download_name('', 'index.pdf')
  end

  private

  def download_name(original, stored)
    @helper.send(:preview_download_filename, original, stored)
  end
end
