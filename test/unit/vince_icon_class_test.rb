# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'nokogiri'

# with iconize, a value of the vCard names the class of its icon; it must not
# add classes of its own (Redmine's "flash error" would draw a message of Redmine)
class VinceIconClassTest < ActiveSupport::TestCase
  def classes(field, value)
    vcf = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Test User\r\n#{field.upcase}:#{value}\r\nEND:VCARD\r\n"
    card = VinceLib::VObject::Reader.new(object: :vcard, string: vcf).stringall.first
    html = card.public_send(field.downcase).webalize(iconize: true)
    Nokogiri::HTML.fragment(html).css('span').flat_map { |span| span['class'].to_s.split }
  end

  def test_a_value_names_one_icon_class
    assert_includes classes('kind', 'individual'), 'icon-kind-individual'
    assert_includes classes('lang', 'en-US'), 'icon-lang-en-us'
    assert_includes classes('gender', 'M'), 'icon-gender-m'
  end

  def test_a_value_adds_no_classes
    %w(kind lang gender).each do |field|
      found = classes(field, 'x flash error')
      assert_not_includes found, 'flash', field
      assert_not_includes found, 'error', field
      assert_includes found, "icon-#{field}-x-flash-error", field
    end
  end
end
