# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# vCards as Apple's, Google's and Outlook's contacts write them (rfc6350 and
# vCard 3 / 2.1): long and folded lines, grouped properties, quoted parameters,
# organizations with units and preferred values. The contacts are made up.
class VinceReaderTest < ActiveSupport::TestCase
  def setup
    @tmp = Dir.mktmpdir('rmp-vince-reader')
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # a line longer than 1000 bytes was cut, and its rest taken for another line
  def test_a_long_line_is_read_whole
    name = 'N' * 1100
    note = 'あ' * 2000
    [card("FN:#{name}\r\nNOTE:#{note}\r\nEMAIL:after@example.com\r\n"),
     file_card("FN:#{name}\r\nNOTE:#{note}\r\nEMAIL:after@example.com\r\n")].each do |c|
      assert_equal [name], values(c, :fn)
      assert_equal [note], values(c, :note)
      assert_equal ['after@example.com'], values(c, :email)
    end
  end

  # rfc6350:3.2 a line is folded by a space or a tab, anywhere: also within a
  # character of UTF-8 (which the rfc forbids, and exporters do), or a parameter
  def test_folded_lines_are_unfolded_before_they_are_split
    folded = "あい".b
    c = file_card("NOTE:first\r\n second\r\n\tthird\r\nFN:#{folded[0, 4]}\r\n #{folded[4..]}\r\n" \
                  "EMAIL;TY\r\n PE=work:folded@example.com\r\n".b)
    assert_equal ['firstsecondthird'], values(c, :note)
    assert_equal ['あい'], values(c, :fn)
    assert_equal ['folded@example.com'], values(c, :email)
    assert_equal({:TYPE => ['work']}, attributes(c, :email).first)
  end

  # Apple's contacts write grouped properties (item1.EMAIL, item1.X-ABLabel)
  def test_a_grouped_property_is_read
    c = card("item1.EMAIL;type=INTERNET;type=pref:grouped@example.com\r\n" \
             "item1.X-ABLabel:_$!<Other>!$_\r\nitem2.TEL:+81 3 0000 0000\r\n")
    assert_equal ['grouped@example.com'], values(c, :email)
    assert_equal ['+81 3 0000 0000'], values(c, :tel)
    assert_includes render(c), 'grouped@example.com'
  end

  # a quoted parameter value may hold ":", ";" and ","
  def test_a_quoted_parameter_value_is_not_split
    c = card(%(EMAIL;X-LABEL="Home: desk; 2F, east";TYPE="work,voice":quoted@example.com\r\n))
    assert_equal ['quoted@example.com'], values(c, :email)
    assert_equal ['EMAIL', 'quoted@example.com', {:'X-LABEL' => ['Home: desk; 2F, east'], :TYPE => ['work,voice']}],
                 VinceLib::VObject::Reader.new.send(:parse, %(EMAIL;X-LABEL="Home: desk; 2F, east";TYPE="work,voice":quoted@example.com))
    # a list of types in quotes is a list of types still
    assert_equal({:'X-LABEL' => ['Home: desk; 2F', ' east'], :TYPE => %w(work voice)}, attributes(c, :email).first)
  end

  # vCard 2.1 parameters without a value, and a quote that is not closed
  def test_parameters_without_a_value_and_an_unbalanced_quote
    c = card(%(TEL;HOME;VOICE:+81 3 1111 1111\r\nEMAIL;X-A="open:unbalanced@example.com\r\n))
    assert_equal ['+81 3 1111 1111'], values(c, :tel)
    assert_equal [:HOME, :VOICE], attributes(c, :tel).first.keys
    assert_equal ['unbalanced@example.com'], values(c, :email)
  end

  def test_blank_lines_and_a_card_without_its_end_are_read
    reader = VinceLib::VObject::Reader.new(object: :vcard,
      string: "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:First\r\n\r\nEND:VCARD\r\nBEGIN:VCARD\r\nFN:Second\r\n")
    assert_equal [['First'], ['Second']], reader.stringall.map { |c| values(c, :fn) }
  end

  private

  def vcard(body)
    "BEGIN:VCARD\r\nVERSION:4.0\r\n#{body}END:VCARD\r\n"
  end

  def card(body)
    VinceLib::VObject::Reader.new(object: :vcard, string: vcard(body)).stringall.first
  end

  # as Vince reads it: from the file, in binary
  def file_card(body)
    path = File.join(@tmp, 'card.vcf')
    File.binwrite(path, vcard(body.b).b)
    VinceLib::VObject::Reader.new(object: :vcard, filepath: path).fileall.first
  end

  def values(card, field)
    card.send(field).sorted.map(&:first)
  end

  def attributes(card, field)
    card.send(field).sorted.map(&:last)
  end

  def org(card)
    card.org.to_h[:org].map { |h| h[:fields] }
  end

  def render(card)
    @preview_format = 'inline'
    @vcfs = [card]
    @iconize = false
    @converter = Struct.new(:public_web_directory, :settings).new('/plugin_assets', {})
    template = File.expand_path('../../converters/vince/app/views/vince/vince.html.erb', __dir__)
    ERB.new(File.read(template)).result(binding).squish
  end
end
