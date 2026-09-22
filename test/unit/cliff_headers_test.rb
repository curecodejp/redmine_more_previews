# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'erb'
require 'mail'
require 'nokogiri'

class CliffHeadersTest < ActiveSupport::TestCase
  MailStub = Struct.new(:from, :to, :cc, :subject, :header) do
    def has_date?
      false
    end
  end

  HeaderStub = Struct.new(:display_names)

  FieldStub = Struct.new(:name, :decoded)

  MailWithFields = Struct.new(:header_fields)

  def render_headers(cc)
    @mail = MailStub.new(
      'sender@example.test',
      'to@example.test',
      cc,
      'Subject',
      {from: HeaderStub.new([])}
    )
    render_current_mail
  end

  def render_current_mail
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

  def test_bundled_template_copy_is_in_sync
    app = File.expand_path('../../converters/cliff/app/views/cliff/headers.html.erb', __dir__)
    lib = File.expand_path('../../converters/cliff/lib/cliff/headers.html.erb', __dir__)
    assert_equal File.read(app), File.read(lib)
  end

  # Mail#cc returns a String when the header cannot be parsed as an address list.
  def test_unparseable_cc_of_a_real_message_is_shown_as_is
    @mail = Mail.new("From: sender@example.test\nTo: to@example.test\nCc: not an address <<\nSubject: Subject\n\nbody\n")
    assert_equal 'not an address <<', cc_cell(render_current_mail)
  end

  # --- header values are attacker controlled -----------------------------------------

  MARKUP = '<b>bold</b><a href="https://example.invalid/">link</a>'

  def render_fields
    template = File.expand_path('../../converters/cliff/app/views/cliff/fields.html.erb', __dir__)
    ERB.new(File.read(template)).result(binding)
  end

  # the templates are plain ERB (not ActionView), so <%= %> does not escape, and
  # cliff.rb marks the result html_safe; markup in a header would otherwise be
  # rendered as markup wherever the preview is shown
  def test_header_values_are_escaped
    @mail = MailStub.new(
      "from#{MARKUP}@example.test",
      "to#{MARKUP}@example.test",
      "cc#{MARKUP}@example.test",
      "Subject#{MARKUP}",
      {from: HeaderStub.new([])}
    )
    html = render_current_mail
    assert_not_includes html, '<b>', 'a header value must not reach the page as markup'
    assert_not_includes html, '<a href', 'a header value must not reach the page as markup'
    assert_includes html, '&lt;b&gt;bold&lt;/b&gt;'
    assert_equal "cc#{MARKUP}@example.test", cc_cell(html), 'the value must still be readable'
  end

  def test_display_names_are_escaped
    @mail = MailStub.new(
      'sender@example.test', 'to@example.test', 'cc@example.test', 'Subject',
      {from: HeaderStub.new([MARKUP])}
    )
    html = render_current_mail
    assert_not_includes html, '<b>'
    assert_includes html, '&lt;b&gt;bold&lt;/b&gt;'
  end

  # fields.html.erb lists every header of the message, names included
  def test_field_names_and_values_are_escaped
    @mail = MailWithFields.new([FieldStub.new("X-#{MARKUP}", "value#{MARKUP}")])
    html = render_fields
    assert_not_includes html, '<b>'
    assert_not_includes html, '<a href'
    assert_equal 2, html.scan('&lt;b&gt;bold&lt;/b&gt;').size, 'both the name and the value must be escaped'
  end

  def test_bundled_fields_template_copy_is_in_sync
    app = File.expand_path('../../converters/cliff/app/views/cliff/fields.html.erb', __dir__)
    lib = File.expand_path('../../converters/cliff/lib/cliff/fields.html.erb', __dir__)
    assert_equal File.read(app), File.read(lib)
  end

  # --- labels --------------------------------------------------------------------------

  # the japanese Cc label read "英語" ("English", the language name Vince's own
  # locale uses), so the row was labelled as if it held a language
  def test_japanese_labels_name_the_mail_fields
    {
      :label_mail_field_date => '日付', :label_mail_field_from => '差出人',
      :label_mail_field_to => '宛先', :label_mail_field_cc => 'Cc',
      :label_mail_field_subject => '件名'
    }.each do |key, expected|
      assert_equal expected, I18n.translate(key, :locale => :ja), "#{key} is mistranslated"
    end
  end
end
