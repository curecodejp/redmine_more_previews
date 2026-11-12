# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Windows in Japan writes the names of zip entries in CP932, without the flag
# of UTF-8. Such a name is shown in Japanese where it reads as one; a name in
# UTF-8 or a western name in ISO-8859-1 is shown as before.
class ZippyEntryNamesTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  JAPANESE = %w(テスト資料.txt 議事録_2026.xlsx 見積書.pdf 報告書.docx 漢字だけ.txt
                鬱.txt 東京/大阪.txt ソフト表示.txt 申込書（控）.pdf).freeze
  SYMBOLS  = %w(1月～3月.xlsx ①議事録.txt ※注意.txt 達成率％.xlsx ＃1報告.txt 件名：会議.txt
                手順→結果.txt ○×表.xlsx ㈱見積.pdf 第Ⅱ期.docx).freeze
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

  def test_a_name_with_the_symbols_of_cp932_is_shown_in_japanese
    SYMBOLS.each do |name|
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

  # the punctuation of Windows-1252 (0x80-0x9F) between two letters reads as a
  # kanji: O’Brien is no Japanese name, nor don’t or A–Z
  def test_a_western_name_with_punctuation_of_windows_1252_is_not_taken_for_japanese
    ["O\x92Brien.txt", "don\x92t.txt", "it\x92s here.txt", "A\x96Z.txt"].map(&:b).each do |name|
      assert_equal RedmineMorePreviews::Lib::RmpText.to_utf8(name), @worker.name_to_utf8(name), name.inspect
    end
    assert_not_equal 'O達rien.txt', @worker.name_to_utf8("O\x92Brien.txt".b)
    # a Japanese name of katakana after a western word is Japanese still
    %w(テスト.txt Excelテスト.xlsx 表.xlsx).each do |name|
      assert_equal name, @worker.name_to_utf8(name.encode('Windows-31J').b), name
    end
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

  # each name is decoded by itself: a folder whose entries are guessed apart is
  # listed once, under its own name
  def test_a_zip_folder_is_listed_once
    html = zip_listing('資料/テスト.txt' => 'a', '資料/ｱｲｳ.txt' => 'b')
    assert_equal 1, html.scan('<strong>資料</strong>').size
    assert_equal 1, html.scan('<strong>').size
    assert_includes html, '>テスト.txt</a>'
  end

  # the name of an entry is decoded without its folders: a folder of halfwidth
  # katakana does not garble the names below it
  def test_a_tar_name_is_decoded_without_its_folders
    tar = File.join(@tmp, 'b.tar')
    File.open(tar, 'wb') do |io|
      Gem::Package::TarWriter.new(io) do |writer|
        writer.mkdir('ｱｲｳ/資料'.encode('Windows-31J').b, 0o755)
        writer.add_file_simple('ｱｲｳ/資料/テスト.txt'.encode('Windows-31J').b, 0o644, 5) { |f| f.write('entry') }
      end
    end
    html = listing(tar)
    assert_includes html, '<strong>資料</strong>'
    assert_includes html, '>テスト.txt</a>'
  end

  # a name in UTF-8 and the same name in CP932 are two entries
  def test_names_that_read_alike_in_two_charsets_are_two_entries
    html = zip_listing({'テスト.txt' => 'utf-8'}, {'テスト.txt' => 'cp932'})
    assert_equal 2, html.scan('>テスト.txt</a>').size
  end

  private

  # a zip archive of names in CP932 (and of names in UTF-8), without the flag of UTF-8
  def zip_listing(cp932, utf8 = {})
    zip = File.join(@tmp, 'a.zip')
    Zip::File.open(zip, create: true) do |file|
      utf8.each { |name, content| file.get_output_stream(name) { |io| io.write(content) } }
      cp932.each { |name, content| file.get_output_stream(name.encode('Windows-31J').b) { |io| io.write(content) } }
    end
    listing(zip)
  end

  def listing(archive)
    worker = zippy_worker(target: File.join(@tmp, 'cache', File.basename(archive), 'preview.html', 'index.html'),
                          request: ActionDispatch::TestRequest.create('PATH_INFO' => '/attachments/more_preview/1.html'))
    html = nil
    worker.preview(File.new(archive)) { |preview| html = preview }
    html.to_s.dup.force_encoding(Encoding::UTF_8)
  end
end
