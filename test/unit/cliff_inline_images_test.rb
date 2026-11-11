# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Cliff embeds the inline images of an email in its HTML preview (see
# RmpDataUri), as long as the page stays within the size of a preview.
class CliffInlineImagesTest < ActiveSupport::TestCase
  PNG = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')

  def setup
    @tmp = Dir.mktmpdir('rmp-cliff-images')
    @old_settings = Setting.plugin_redmine_more_previews
  end

  def teardown
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache
    FileUtils.rm_rf(@tmp)
  end

  def mail_with_image(image)
    <<~MAIL.gsub("\n", "\r\n")
      From: a@example.test
      To: b@example.test
      Subject: inline image
      MIME-Version: 1.0
      Content-Type: multipart/related; boundary="b1"

      --b1
      Content-Type: text/html; charset=UTF-8

      <html><body><p>body</p><img src="cid:img1@x"></body></html>
      --b1
      Content-Type: image/png; name="image001.png"
      Content-Transfer-Encoding: base64
      Content-ID: <img1@x>
      Content-Disposition: inline; filename="image001.png"

      #{Base64.encode64(image).strip}
      --b1--
    MAIL
  end

  def convert(mail_source)
    eml = File.join(@tmp, 'a.eml')
    File.binwrite(eml, mail_source)
    worker = RedmineMorePreviews::Converter.find(:cliff).worker(
      :preview_format => 'html', :object => {}, :target => File.join(@tmp, 'preview.html', 'index.html')
    )
    preview = nil
    worker.preview(File.new(eml)) { |html, _asset| preview = html }
    preview.to_s.dup.force_encoding(Encoding::UTF_8)
  end

  def test_inline_image_is_embedded
    html = convert(mail_with_image(PNG))
    assert_includes html, %(src="data:image/png;base64,#{Base64.strict_encode64(PNG)}")
    assert_includes html, 'body'
  end

  # a page larger than a preview would not be shown at all: the image is linked
  def test_image_that_would_exceed_the_size_of_a_preview_is_linked
    Setting.plugin_redmine_more_previews = {'max_output' => '1'}
    Setting.clear_cache
    large = PNG.byteslice(0, 16) + Random.new(1).bytes(900 * 1024)
    html = convert(mail_with_image(large))
    assert_includes html, 'src="image001.png"'
    assert_not_includes html, 'data:image/png'
  end

  # an image referenced many times is not embedded each time: the images
  # embedded add no more than twice the email
  def test_an_image_referenced_many_times_is_embedded_while_it_stays_within_the_email
    image = PNG.byteslice(0, 16) + Random.new(2).bytes(30 * 1024)
    mail = mail_with_image(image).sub('<img src="cid:img1@x">', '<img src="cid:img1@x">' * 10)
    html = convert(mail)
    embedded = html.scan('src="data:image/png;base64,').size
    assert_operator embedded, :>=, 1
    assert_operator embedded, :<=, 2
    assert_equal 10 - embedded, html.scan('src="image001.png"').size
  end
end
