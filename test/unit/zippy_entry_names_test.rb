# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Windows in Japan writes the names of zip entries in CP932, without the flag
# of UTF-8. Such a name is shown in Japanese where it reads as one; a name in
# UTF-8 or a western name in ISO-8859-1 is shown as before.
class ZippyEntryNamesTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  JAPANESE = %w(テスト資料.txt 議事録_2026.xlsx 見積書.pdf 報告書.docx 漢字だけ.txt
                鬱.txt 東京/大阪.txt ソフト表示.txt 申込書（控）.pdf).freeze
  WESTERN  = ['école.txt', 'café.txt', 'Ärger.txt', 'naïve.txt', 'señor.txt', 'Größe.txt',
              'résumé.pdf', 'über.txt', 'déjà vu.txt', 'façade.txt'].freeze

  def setup
    @tmp = Dir.mktmpdir('rmp-zippy-names')
    @worker = zippy_worker(target: File.join(@tmp, 'cache', 'preview.html', 'index.html'))
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_a_name_in_cp932_is_shown_in_japanese
    JAPANESE.each do |name|
      assert_equal name, @worker.name_to_utf8(name.encode('Windows-31J').b), name
    end
  end

  def test_a_name_in_utf8_is_shown_as_it_is
    (JAPANESE + WESTERN).each do |name|
      assert_equal name, @worker.name_to_utf8(name.b), name
    end
  end

  def test_a_western_name_in_iso_8859_1_is_shown_as_before
    WESTERN.each do |name|
      assert_equal name, @worker.name_to_utf8(name.encode('ISO-8859-1').b), name
    end
  end

  # halfwidth katakana are single bytes, the letters of ISO-8859-1: a name of
  # them alone is not taken for Japanese, nor one without a kana or a common kanji
  def test_a_name_that_may_be_western_is_not_taken_for_japanese
    ['ｱｲｳ.txt', '漢ｶﾅ.txt'].each do |name|
      assert_equal RedmineMorePreviews::Lib::RmpText.to_utf8(name.encode('Windows-31J').b),
                   @worker.name_to_utf8(name.encode('Windows-31J').b), name
    end
    # lead byte 0xE9 only (a kanji of the second level): read as ISO-8859-1
    assert_equal 'éc', @worker.name_to_utf8("\xE9c".b)
  end

  def test_a_tar_listing_shows_a_japanese_name
    tar = File.join(@tmp, 'a.tar')
    File.open(tar, 'wb') do |io|
      Gem::Package::TarWriter.new(io) do |writer|
        writer.add_file_simple('資料/テスト.txt'.encode('Windows-31J').b, 0o644, 5) { |f| f.write('entry') }
      end
    end
    worker = zippy_worker(target: File.join(@tmp, 'cache', 'a.tar', 'preview.html', 'index.html'),
                          request: ActionDispatch::TestRequest.create('PATH_INFO' => '/attachments/more_preview/1.html'))
    html = nil
    worker.preview(File.new(tar)) { |preview| html = preview }
    html = html.to_s.dup.force_encoding(Encoding::UTF_8)
    assert_includes html, '>テスト.txt</a>'
  end
end
