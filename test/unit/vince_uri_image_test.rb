# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class VinceUriImageTest < ActiveSupport::TestCase
  PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

  def setup
    @secret = Tempfile.new(['rmp-vince-secret', '.png'])
    @secret.write('RMP-VINCE-LOCAL-FILE-SECRET')
    @secret.flush
  end

  def teardown
    @secret.close!
  end

  def card(line, version: '4.0')
    VinceLib::VObject::Reader.new(
      object: :vcard,
      string: "BEGIN:VCARD\r\nVERSION:#{version}\r\nFN:Test\r\n#{line}\r\nEND:VCARD\r\n"
    ).stringall.first
  end

  %w(photo logo).each do |field|
    define_method("test_#{field}_file_uri_does_not_read_local_file") do
      html = nil
      assert_nothing_raised do
        html = card("#{field.upcase};VALUE=uri:file://#{@secret.path}").send(field).webalize
      end

      html = Array(html).join
      assert_not_includes html, 'RMP-VINCE-LOCAL-FILE-SECRET'
      assert_not_includes html, Base64.strict_encode64('RMP-VINCE-LOCAL-FILE-SECRET')
      assert_not_includes html, '<img'
    end

    define_method("test_#{field}_https_uri_is_kept") do
      html = Array(card("#{field.upcase};VALUE=uri:https://example.com/p.png").send(field).webalize).join

      assert_includes html, %(src="https://example.com/p.png")
      assert_includes html, %(alt="#{I18n.with_locale(Setting.default_language) { I18n.t(:"vcard.#{field.upcase}") }}")
    end

    define_method("test_#{field}_scheme_merely_containing_https_is_dropped") do
      html = Array(card("#{field.upcase};VALUE=uri:nothttps://example.com/p.png").send(field).webalize).join

      assert_not_includes html, '<img'
    end

    define_method("test_#{field}_data_uri_is_kept") do
      html = Array(card("#{field.upcase}:data:image/png;base64,#{PNG_BASE64}").send(field).webalize).join

      assert_includes html, %(src="data:image/png;base64,#{PNG_BASE64}")
      assert_includes html, %(alt="#{I18n.with_locale(Setting.default_language) { I18n.t(:"vcard.#{field.upcase}") }}")
    end

    define_method("test_#{field}_vcard3_inline_type_is_canonicalized") do
      {'jpg' => 'image/jpeg', 'JPEG' => 'image/jpeg', 'PnG' => 'image/png',
       'gif' => 'image/gif', 'bmp' => 'image/bmp', 'TIFF' => 'image/tiff',
       'SVG+XML' => 'image/svg+xml', '"JPEG"' => 'image/jpeg'}.each do |type, expected_mime|
        html = Array(card("#{field.upcase};ENCODING=b;TYPE=#{type}:#{PNG_BASE64}", version: '3.0').
                     public_send(field).webalize).join

        assert_includes html, "src=\"data:#{expected_mime};base64,#{PNG_BASE64}\"", type
      end
    end

    define_method("test_#{field}_vcard3_unrecognized_inline_type_is_not_used_as_mime") do
      ['notpng', 'jpg-extra', 'svg+xml-evil', 'png<script', 'jpeg2000'].each do |type|
        html = Array(card("#{field.upcase};ENCODING=b;TYPE=#{type}:#{PNG_BASE64}", version: '3.0').
                     public_send(field).webalize).join

        assert_includes html, "src=\"data:application/octet-stream;base64,#{PNG_BASE64}\"", type
        assert_not_includes html, "data:image/#{type}", type
      end
    end

    define_method("test_#{field}_vcard3_inline_base64_is_kept") do
      html = Array(card("#{field.upcase};ENCODING=b;TYPE=png:#{PNG_BASE64}", version: '3.0').send(field).webalize).join

      assert_includes html, %(src="data:image/png;base64,#{PNG_BASE64}")
    end
  end
end
