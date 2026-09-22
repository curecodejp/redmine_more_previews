# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'erb'
require 'nokogiri'

class CliffHeadersTest < ActiveSupport::TestCase
  MailStub = Struct.new(:from, :to, :cc, :subject, :header) do
    def has_date?
      false
    end
  end

  HeaderStub = Struct.new(:display_names)

  def render_headers(cc)
    @mail = MailStub.new(
      'sender@example.test',
      'to@example.test',
      cc,
      'Subject',
      {from: HeaderStub.new([])}
    )
    template = File.expand_path('../../converters/cliff/app/views/cliff/headers.html.erb', __dir__)
    ERB.new(File.read(template)).result(binding)
  end

  def cc_cell(html)
    label = I18n.translate(:label_mail_field_cc).to_s
    row = Nokogiri::HTML.fragment(html).css('tr').find do |tr|
      cells = tr.css('td')
      cells.first&.text&.strip == label
    end

    assert row, 'Cc row must be present'
    row.css('td')[1].text.strip
  end

  def test_string_cc_displays_cc_instead_of_from
    assert_equal 'cc@example.test', cc_cell(render_headers('cc@example.test'))
  end

  def test_array_cc_is_joined
    assert_equal 'one@example.test, two@example.test',
                 cc_cell(render_headers(['one@example.test', 'two@example.test']))
  end
end
