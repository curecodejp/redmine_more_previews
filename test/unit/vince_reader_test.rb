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

  # rfc6350:5 each value of a list may be quoted by itself (TYPE="work","pref")
  def test_the_values_of_a_parameter_quoted_one_by_one
    c = card(%(TEL:+1 none\r\nTEL;TYPE="work","pref":+1 quoted\r\nTEL;TYPE=home,"voice":+1 home\r\n))
    assert_equal ['+1 quoted', '+1 none', '+1 home'], values(c, :tel)
    assert_equal [{:TYPE => %w(work pref)}, {}, {:TYPE => %w(home voice)}], attributes(c, :tel)
  end

  # rfc6350:5 the names of parameters are case-insensitive: Apple's contacts
  # write "type=", and a photo of "type=JPEG" was given as application/octet-stream
  def test_the_names_of_parameters_in_any_case
    c = card("EMAIL;TYPE=work;type=pref:mixed@example.com\r\nPHOTO;encoding=b;type=JPEG:#{'A' * 8}\r\n")
    assert_equal [{:TYPE => %w(work pref)}], attributes(c, :email)
    assert_includes render(c), 'data:image/jpeg;base64,AAAAAAAA'
  end

  # a line with many quoted parameters (and characters of more than one byte)
  # was split in a time growing with the square of its length
  def test_many_quoted_parameters_are_split_in_linear_time
    line   = 'EMAIL' + ';X-A="あ"' * 20_000 + ':many@example.com'
    parsed = nil
    time   = Benchmark.realtime { parsed = VinceLib::VObject::Reader.new.send(:parse, line) }
    assert_equal 'many@example.com', parsed[1]
    assert_equal ['あ'] * 20_000, parsed[2][:'X-A']
    assert_operator time, :<, 2, 'parsed in linear time'
  end

  # vCard 2.1 parameters without a value are types (TEL;HOME;VOICE), and a quote
  # that is not closed
  def test_parameters_without_a_value_and_an_unbalanced_quote
    c = card(%(TEL;HOME;VOICE:+81 3 1111 1111\r\nEMAIL;X-A="open:unbalanced@example.com\r\n))
    assert_equal ['+81 3 1111 1111'], values(c, :tel)
    assert_equal [{:TYPE => %w(HOME VOICE)}], attributes(c, :tel)
    assert_equal ['unbalanced@example.com'], values(c, :email)
  end

  # an empty parameter (a ";" too many) is left out: the whole file failed
  def test_an_empty_parameter_is_left_out
    c = card("TEL;TYPE=cell;:+1 trailing\r\nTEL;:+1 empty\r\nTEL;;TYPE=cell:+1 between\r\n")
    assert_equal ['+1 trailing', '+1 empty', '+1 between'], values(c, :tel)
    assert_equal [{:TYPE => ['cell']}, {}, {:TYPE => ['cell']}], attributes(c, :tel)
  end

  # ORG is an organization and its units, separated by ";"
  def test_the_units_of_an_organization_are_separated
    assert_equal [{1 => 'Example Corp.', 2 => 'Sales', 3 => 'Tokyo'}], org(card("ORG:Example Corp.;Sales;Tokyo\r\n"))
    assert_equal [{1 => 'Example, Inc.'}], org(card("ORG:Example\\, Inc.\r\n"))
    assert_equal [{1 => 'Example'}], org(card("ORG:Example;\r\n"))
    assert_equal [{1 => 'A;B'}], org(card("ORG:A\\;B\r\n"))
    # the lists of other properties are separated by ","
    c = card("CATEGORIES:friends,work\r\nNICKNAME:Ex, Sample\r\n")
    assert_equal [{1 => 'friends', 2 => 'work'}], c.categories.to_h[:categories].map { |h| h[:fields] }
    assert_equal [{1 => 'Ex', 2 => ' Sample'}], c.nickname.to_h[:nickname].map { |h| h[:fields] }

    c = card("ORG:Example Corp.;Sales\r\n")
    html = render(c)
    assert_includes html, '>Example Corp.</span>'
    assert_includes html, '>Sales</span>'
    assert_includes c.org.humanize, 'Sales'
  end

  # the preferred values first (PREF=1 before PREF=2), then those without a
  # preference, in the order of the vCard
  def test_values_are_sorted_by_preference
    c = card("EMAIL:none1@example.com\r\nEMAIL;PREF=2:two@example.com\r\nEMAIL:none2@example.com\r\n" \
             "EMAIL;PREF=1:one@example.com\r\n")
    assert_equal %w(one@example.com two@example.com none1@example.com none2@example.com), values(c, :email)
    # vCard 3 TYPE=pref and vCard 2.1 PREF without a value are preferred too
    c = card("TEL:+1 none\r\nTEL;TYPE=work,pref:+1 type\r\n")
    assert_equal ['+1 type', '+1 none'], values(c, :tel)
    c = card("TEL:+1 none\r\nTEL;WORK;PREF:+1 bare\r\n")
    assert_equal ['+1 bare', '+1 none'], values(c, :tel)
  end

  # the addresses are shown under their type: work, home, the preferred ones and
  # the others (the type was not seen, and all were shown under the others)
  def test_values_are_shown_under_their_type
    c = card(%(EMAIL;TYPE=work:work@example.com\r\nEMAIL;TYPE=home:home@example.com\r\n) +
             %(TEL;TYPE="work,voice":+81 3 2222 2222\r\nEMAIL:other@example.com\r\n))
    html = I18n.with_locale(:en) { render(c) }
    sections = html.split(%r{<h4>([^<]+)</h4>}).drop(1).each_slice(2).to_h
    assert_includes sections['Work'], 'work@example.com'
    assert_includes sections['Work'], '+81 3 2222 2222'
    assert_includes sections['Home'], 'home@example.com'
    assert_includes sections['Other'], 'other@example.com'
    assert_not_includes sections['Other'], 'work@example.com'
    # vCard 2.1 (Outlook) writes the types without TYPE=
    c = card("TEL;WORK;VOICE:+81 3 5555 5555\r\nEMAIL;PREF;INTERNET:pref@example.com\r\n")
    sections = I18n.with_locale(:en) { render(c) }.split(%r{<h4>([^<]+)</h4>}).drop(1).each_slice(2).to_h
    assert_equal %w(Personal Work Preferred), sections.keys
    assert_includes sections['Work'], '+81 3 5555 5555'
    assert_includes sections['Preferred'], 'pref@example.com'
  end

  # a telephone number of text (vCard 3, VALUE=text) is no URI: it was shown empty
  def test_a_telephone_number_of_text_is_shown
    c = card("TEL;TYPE=work:+81 3 3333 3333\r\nTEL:<b>555</b> 0100\r\nTEL;VALUE=uri:tel:+81-3-4444-4444\r\n" \
             "TEL:+81 3 1234 5678 ext. 12345 (reception desk, 2F)\r\n")
    html = render(c)
    assert_includes html, '>+81 3 3333 3333</span>'
    assert_includes html, '>+81 3 1234 5678 ext. 12345 (reception desk, 2F)</span>'
    assert_includes html, '&lt;b&gt;555&lt;/b&gt; 0100'
    assert_not_includes html, '<b>555</b>'
    assert_includes html, 'href="tel:+81-3-4444-4444"'
    assert_equal 1, html.scan('href="tel:').size
    assert_includes c.tel.humanize, '+81 3 3333 3333'
  end

  def test_blank_lines_and_a_card_without_its_end_are_read
    reader = VinceLib::VObject::Reader.new(object: :vcard,
      string: "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:First\r\n\r\nEND:VCARD\r\nBEGIN:VCARD\r\nFN:Second\r\n")
    assert_equal [['First'], ['Second']], reader.stringall.map { |c| values(c, :fn) }
  end

  # a photo as large as a vCard may be (Vince::MAX_SIZE), on one line or folded,
  # as a data URI (its scheme in any case) or in base64 (vCard 3): it is read and
  # shown with the rest of the card, within the memory of the conversion (the URI
  # parser took some 50 bytes for a byte of it). A long value that is no data URI
  # is not parsed as a URI: it is not shown, and the rest of the card is
  def test_a_large_photo_is_shown
    photo = 'A' * (Vince::MAX_SIZE * 9 / 10)
    {'data'  => ["PHOTO:data:image/png;base64,#{photo}", 'src="data:image/png;base64,'],
     'mixed' => ["PHOTO:Data:image/png;base64,#{photo}", 'src="Data:image/png;base64,'],
     'b64'   => ["PHOTO;ENCODING=b;TYPE=JPEG:#{photo.scan(/.{1,74}/).join("\r\n ")}", 'src="data:image/jpeg;base64,'],
     'url'   => ["URL:https://example.com/#{photo}", nil]}.each do |form, (line, src)|
      source = File.join(@tmp, "#{form}.vcf")
      File.binwrite(source, vcard("FN:Photographed\r\n#{line}\r\nEMAIL:after@example.com\r\n"))
      worker = RedmineMorePreviews::Converter.find(:vince).worker(
        preview_format: 'html', object: {}, target: File.join(@tmp, form, 'index.html'))
      html = File.open(source) { |io| worker.preview(io) }.to_s
      assert_includes html, 'after@example.com', form
      if src
        assert_includes html, src + photo[0, 1000], form
      else
        assert_not_includes html, photo[0, 1000], form
      end
    end
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
