# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'nokogiri'

class VinceUriLinkTest < ActiveSupport::TestCase
  def preview(field, value)
    vcf = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Test User\r\n#{field.upcase}:#{value}\r\nEND:VCARD\r\n"
    card = VinceLib::VObject::Reader.new(object: :vcard, string: vcf).stringall.first
    Nokogiri::HTML.fragment(card.public_send(field.downcase).webalize)
  end

  def test_supported_uri_schemes_remain_clickable
    [
      ['url', 'http://example.invalid/page'],
      ['url', 'HTTPS://example.invalid/page'],
      ['url', 'ftp://example.invalid/file'],
      ['url', 'mailto:user@example.invalid'],
      ['tel', 'tel:+12025550123'],
      ['geo', 'geo:35.0,139.0']
    ].each do |field, uri|
      link = preview(field, uri).at_css('a')
      assert_not_nil link, uri
      assert_equal uri.downcase.split(':', 2).first, link['href'].split(':', 2).first.downcase, uri
    end
  end

  def test_unsupported_uri_schemes_render_as_plain_text
    [
      ['url', 'javascript:noop'],
      ['url', 'data:text/plain,hello'],
      ['url', 'file:///tmp/sample.txt'],
      ['url', 'nothttps:example.invalid'],
      ['tel', 'javascript:noop'],
      ['geo', 'custom:35.0,139.0']
    ].each do |field, uri|
      fragment = preview(field, uri)
      assert_nil fragment.at_css('a'), uri
      assert_includes fragment.text, uri, uri
    end
  end
end
