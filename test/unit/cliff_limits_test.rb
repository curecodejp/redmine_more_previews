# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'mail'

# Cliff parses an email into objects part by part and writes every attachment
# out; naming n equal attachments tried the names 2, 3, ... anew for each one,
# recursively (quadratic time, and a stack overflow for large n). The size and
# the MIME parts are checked before the email is parsed, and the attachments
# beyond the limit are only counted.
class CliffLimitsTest < ActiveSupport::TestCase
  RmpFile = RedmineMorePreviews::Lib::RmpFile

  def setup
    @tmp = Dir.mktmpdir('rmp-cliff-limits')
    @old_settings = Setting.plugin_redmine_more_previews
  end

  def teardown
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    FileUtils.rm_rf(@tmp)
  end

  # the names are the same as those of the former recursive implementation
  def test_unique_filename_names_as_before
    names = %w(a.txt a.2.txt a.3.txt b b.2 c.5 file.tar.gz .hidden .2.txt 5.txt x.y.1.z a..txt)
    candidates = names + %w(a.txt a.2.txt b b.2 c.5 c file.tar.gz .hidden .2.txt 5.txt x.y.1.z x.y.z new.txt a..txt)
    candidates.each do |name|
      assert_equal former_unique_filename(names, name), RmpFile.unique_filename(names, name), name
      assert_equal former_unique_filename(names, name), RmpFile.unique_filename(names.to_set, name, counters: {}), name
    end
  end

  def test_unique_filename_names_a_sequence_as_before
    expected, actual = [], Set.new
    counters = {}
    %w(a.txt a.txt a.2.txt a.txt b b b.2 b a.txt).each do |name|
      expected << former_unique_filename(expected, name)
      actual << RmpFile.unique_filename(actual, name, counters: counters)
    end
    assert_equal expected, actual.to_a
  end

  def test_many_equal_names_are_named_quickly
    names, counters = Set.new, {}
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    8000.times { names << RmpFile.unique_filename(names, 'same.txt', counters: counters) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 1
    assert_equal 8000, names.size
    assert_includes names, 'same.8000.txt'
  end

  def test_attachments_beyond_the_limit_are_counted_only
    with_cliff_settings('max_attachments' => '3') do
      convert(mail_with_attachments(5))
      listing = @assets['attachments.html'].to_s.dup.force_encoding(Encoding::UTF_8)
      assert_includes listing, I18n.translate(:"redmine_more_previews.cliff.text_more_attachments", count: 2)
      assert_equal 3, @saved.size
    end
  end

  def test_email_larger_than_the_limit_is_not_parsed
    with_cliff_settings('max_size' => '1') do
      Mail.expects(:new).never
      html = convert("Subject: big\n\n" + ('x' * (1024 * 1024 + 1)))
      assert_includes html, 'larger than 1 MiB'
    end
  end

  def test_email_with_too_many_parts_is_not_parsed
    source = mail_with_attachments(20)
    with_cliff_settings('max_parts' => '10') do
      Mail.expects(:new).never
      assert_includes convert(source), 'more than 10 parts'
    end
  end

  def test_email_with_too_many_multipart_parts_is_not_parsed
    Mail.expects(:new).never
    body = (1..(Cliff::MAX_MULTIPARTS + 1)).map {|n| "Content-Type: multipart/mixed; boundary=\"b#{n}\"\n"}.join
    assert_includes convert("Subject: nested\n#{body}\n"), "more than #{Cliff::MAX_MULTIPARTS} multipart parts"
  end

  def test_email_within_the_limits_is_previewed
    html = convert(mail_with_attachments(2))
    assert_not_includes html, 'more than'
    assert_equal %w(same.2.txt same.txt), @saved.sort
  end

  private

  # the implementation before the loop, as the reference for the names
  def former_unique_filename(filenames, filename, index = 2)
    return filename unless filenames.any? {|f| f == filename}
    extname = File.extname(filename)
    if extname =~ /\A\.\d+\z/
      basname = File.basename(filename, extname)
      extname = ''
    elsif extname.blank?
      basname = filename
      extname = ''
    else
      tmpname = File.basename(filename, extname)
      indname = File.extname(tmpname)
      basname = indname =~ /\A\.\d+\z/ ? File.basename(tmpname, indname) : tmpname
    end
    former_unique_filename(filenames, "#{basname}.#{index}#{extname}", index + 1)
  end

  def mail_with_attachments(count)
    mail = Mail.new do
      from 'a@example.test'
      to 'b@example.test'
      subject 'attachments'
      text_part { body 'see attached' }
    end
    count.times {|n| mail.add_file(filename: 'same.txt', content: "attachment #{n}")}
    mail.to_s
  end

  # converts the email; returns the preview, keeps the extracted attachments
  def convert(source)
    eml = File.join(@tmp, "#{SecureRandom.hex(4)}.eml")
    File.binwrite(eml, source)
    worker = RedmineMorePreviews::Converter.find(:cliff).worker(
      :preview_format => 'html', :object => {}, :target => File.join(@tmp, 'preview.html', 'index.html'),
      :assets => %w(attachments.html)
    )
    preview = nil
    @assets, @saved = {}, []
    worker.preview(File.new(eml)) do |html, _asset, attachments|
      preview = html
      @assets['attachments.html'] = attachments
      @saved = Dir.children(worker.tmpdir) - %w(index.html attachments.html headers.html fields.html)
    end
    preview.to_s.dup.force_encoding(Encoding::UTF_8)
  end

  def with_cliff_settings(values)
    settings = @old_settings.to_h.deep_dup
    settings['converter'] = settings['converter'].to_h
    settings['converter']['cliff'] = settings['converter']['cliff'].to_h.merge(values)
    Setting.plugin_redmine_more_previews = settings
    Setting.clear_cache
    yield
  end
end
