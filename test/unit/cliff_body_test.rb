# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'mail'

# A text/plain message is shown verbatim inside <pre>, so its body must reach
# the page as text. Cliff renders that page with plain ERB and marks the result
# html_safe, and its own sweep only removes <script>, so markup in the body was
# rendered as markup - the same exposure the header tables had.
class CliffBodyTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  MARKUP = '<b>bold</b></pre><table><tr><td>injected</td></tr></table>'

  def setup
    @tmp = Dir.mktmpdir('rmp-cliff-body')
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def convert(mail_source, unsafe: false)
    eml = File.join(@tmp, 'a.eml')
    File.binwrite(eml, mail_source)
    worker = RedmineMorePreviews::Converter.find(:cliff).worker(
      :preview_format => 'html', :object => {}, :target => File.join(@tmp, 'preview.html', 'index.html'),
      :unsafe => unsafe
    )
    preview = nil
    worker.preview(File.new(eml)) { |html, _asset| preview = html }
    # the preview is read back as binary; the templates write UTF-8
    preview.to_s.dup.force_encoding(Encoding::UTF_8)
  end

  def plain_message(body)
    "From: a@example.test\nTo: b@example.test\nSubject: s\n" \
    "Content-Type: text/plain; charset=UTF-8\n\n#{body}\n"
  end

  def quoted_printable_message(body)
    "From: a@example.test\nTo: b@example.test\nSubject: s\n" \
    "Content-Type: text/plain; charset=UTF-8\n" \
    "Content-Transfer-Encoding: quoted-printable\n\n#{[body].pack('M')}"
  end

  def render_pre(text)
    @text = text
    template = File.expand_path('../../converters/cliff/app/views/cliff/pre.html.erb', __dir__)
    ERB.new(File.read(template)).result(binding)
  end

  def test_plain_text_body_is_escaped
    html = convert(plain_message("plain #{MARKUP}"))
    assert_not_includes html, '<b>bold</b>', 'the body must not reach the page as markup'
    assert_not_includes html, '<table><tr><td>injected',
                         'a body closing the <pre> must not be able to add markup of its own'
    assert_includes html, '&lt;b&gt;bold&lt;/b&gt;', 'the body must still be readable'
  end

  def test_plain_text_body_keeps_its_text
    html = convert(plain_message("ordinary body & 日本語"))
    assert_includes html, 'ordinary body &amp; 日本語'
  end

  def test_quoted_printable_plain_text_body_is_escaped
    html = convert(quoted_printable_message("plain #{MARKUP}"))
    assert_not_includes html, '<b>bold</b>', 'the encoded body must not reach the page as markup'
    assert_not_includes html, '<table><tr><td>injected',
                         'an encoded body must not be able to add markup of its own'
    assert_includes html, '&lt;b&gt;bold&lt;/b&gt;', 'the encoded body must still be readable'
  end

  def test_pre_template_escapes_html_safe_text
    text = ActiveSupport::SafeBuffer.new(MARKUP)
    assert text.html_safe?

    html = render_pre(text)
    assert_not_includes html, '<b>bold</b>', 'the sink must not trust the caller\'s safety flag'
    assert_not_includes html, '<table><tr><td>injected'
    assert_includes html, '&lt;b&gt;bold&lt;/b&gt;'
  end

  # an html message is html by definition: that part is rendered, not escaped,
  # and is protected by the sandbox and the inline sanitiser instead
  def test_html_part_is_still_rendered_as_html
    html = convert(
      "From: a@example.test\nTo: b@example.test\nSubject: s\n" \
      "Content-Type: text/html; charset=UTF-8\n\n<p>hello <b>world</b></p>\n"
    )
    assert_includes html, '<b>world</b>'
  end

  # the message of a parse failure quotes the mail, so it is attacker controlled:
  # the error page does not show it. The email is parsed in a child process: a
  # stub works there, an expectation is not counted
  def test_the_error_page_shows_no_exception_message
    Mail.stubs(:new).raises(RuntimeError.new("broken #{MARKUP}"))
    html = convert(plain_message('body'))
    assert_not_includes html, 'bold'
    assert_equal I18n.translate(:"redmine_more_previews.cliff.text_not_previewed"), html
  end

  # The body of a part was shown in the charset of the email: only
  # quoted-printable text was converted, and only in a multipart email.
  # Japanese mail is mostly ISO-2022-JP or Shift_JIS, often base64 encoded.
  JAPANESE = '日本語の本文です'
  WESTERN  = 'café naïve'
  CHARSETS = {
    'ISO-2022-JP'  => [JAPANESE, %w(base64 7bit quoted-printable)],
    'Shift_JIS'    => [JAPANESE, %w(base64 8bit quoted-printable)],
    'Windows-1252' => [WESTERN,  %w(base64 8bit quoted-printable)],
    'UTF-8'        => [JAPANESE, %w(base64 8bit quoted-printable)]
  }.freeze

  def encoded_message(type, charset, encoding, bytes, multipart: false)
    body = case encoding
           when 'base64' then [bytes].pack('m')
           when 'quoted-printable' then [bytes].pack('M')
           else bytes
           end
    part = "Content-Type: #{type}; charset=#{charset}\nContent-Transfer-Encoding: #{encoding}\n\n".b + body.b
    head = "From: a@example.test\nTo: b@example.test\nSubject: s\nMIME-Version: 1.0\n".b
    return head + part unless multipart

    head + "Content-Type: multipart/mixed; boundary=XX\n\n--XX\n".b + part +
      "\n--XX\nContent-Type: application/octet-stream; name=a.bin\nContent-Disposition: attachment; filename=a.bin\n" \
      "Content-Transfer-Encoding: base64\n\nAAAA\n--XX--\n".b
  end

  def test_text_bodies_are_converted_from_their_charset
    CHARSETS.each do |charset, (text, encodings)|
      encodings.each do |encoding|
        [false, true].each do |multipart|
          html = convert(encoded_message('text/plain', charset, encoding, text.encode(charset).b, multipart: multipart))
          assert_includes html, text, "#{charset} #{encoding} text, multipart: #{multipart}"
        end
      end
    end
  end

  def test_html_bodies_are_converted_from_their_charset
    CHARSETS.each do |charset, (text, encodings)|
      encodings.each do |encoding|
        [false, true].each do |multipart|
          html = convert(encoded_message('text/html', charset, encoding, "<p>#{text}</p>".encode(charset).b, multipart: multipart))
          assert_includes html, text, "#{charset} #{encoding} html, multipart: #{multipart}"
        end
      end
    end
  end

  # the page is written in UTF-8: a charset of the email in the html must not
  # remain, or the browser would read the page in it
  def test_html_body_declares_utf8
    source = '<html><head><meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"></head>' \
             "<body><p>#{JAPANESE}</p></body></html>"
    html = convert(encoded_message('text/html', 'Shift_JIS', 'base64', source.encode('Shift_JIS').b))
    assert_includes html, JAPANESE
    assert_match(/<meta[^>]*charset=UTF-8/i, html)
    assert_no_match(/Shift_JIS/i, html)
  end

  # without the sweep (unsafe, administrators only) the html is written as it
  # is: its charset must still be UTF-8
  def test_unsafe_html_body_declares_utf8
    source = '<html><head><meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"></head>' \
             "<body><p>#{JAPANESE}</p></body></html>"
    [false, true].each do |multipart|
      html = convert(encoded_message('text/html', 'Shift_JIS', 'base64', source.encode('Shift_JIS').b, multipart: multipart),
                     unsafe: true)
      assert_includes html, JAPANESE, "multipart: #{multipart}"
      assert_match(/<meta[^>]*charset=UTF-8/i, html, "multipart: #{multipart}")
      assert_no_match(/Shift_JIS/i, html, "multipart: #{multipart}")
    end
  end

  # Japanese mail declared Shift_JIS or ISO-2022-JP mostly uses Microsoft's
  # supersets of them
  def test_japanese_bodies_keep_characters_of_microsofts_supersets
    text = '①～髙'
    %w(Shift_JIS shift-jis).each do |label|
      assert_includes convert(encoded_message('text/plain', label, 'base64', text.encode('Windows-31J').b)), text, label
    end
    assert_includes convert(encoded_message('text/plain', 'ISO-2022-JP', '7bit', text.encode('CP50221').b)), text
  end

  # an email that is not UTF-8 is read as ISO-8859-1; an 8bit part gets its
  # bytes back, a quoted-printable part beside it is not touched
  def test_8bit_and_quoted_printable_parts_of_one_email
    source = "From: a@example.test\nTo: b@example.test\nSubject: s\nMIME-Version: 1.0\n" \
             "Content-Type: multipart/alternative; boundary=XX\n\n--XX\n" \
             "Content-Type: text/plain; charset=Shift_JIS\nContent-Transfer-Encoding: 8bit\n\n".b +
             JAPANESE.encode('Shift_JIS').b +
             "\n--XX\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: quoted-printable\n\n".b +
             ['<p>エイチティーエムエル版</p>'.b].pack('M') + "\n--XX--\n".b
    assert_includes convert(source), 'エイチティーエムエル版'
  end

  # Mail turns a charset it does not know into binary and replaces every byte
  # that is not ASCII: the body is guessed instead, as without a charset
  def test_body_of_an_unknown_charset_is_shown
    html = convert(encoded_message('text/plain', 'x-unknown', 'base64', "unknown charset #{JAPANESE}".b))
    assert_includes html, "unknown charset #{JAPANESE}"
  end

  # Mail also replaces the bytes that are not valid in a charset it knows: a
  # body the charset does not fit is guessed too
  def test_body_of_a_wrong_charset_is_shown
    { 'US-ASCII' => '8bit', 'ISO-2022-JP' => '8bit', 'Shift_JIS' => 'base64' }.each do |charset, encoding|
      [['text/plain', JAPANESE], ['text/html', "<p>#{JAPANESE}</p>"]].each do |type, body|
        [false, true].each do |multipart|
          html = convert(encoded_message(type, charset, encoding, body.b, multipart: multipart))
          assert_includes html, JAPANESE, "UTF-8 #{type} declared #{charset}, multipart: #{multipart}"
        end
      end
    end
  end

  # an html part without a charset in its Content-Type often declares it in
  # the html itself
  def test_html_body_without_a_charset_uses_its_meta_charset
    source = '<html><head><meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"></head>' \
             "<body><p>#{JAPANESE}</p></body></html>"
    raw = encoded_message('text/html', 'Shift_JIS', 'base64', source.encode('Shift_JIS').b)
    html = convert(raw.sub('; charset=Shift_JIS'.b, ''.b))
    assert_includes html, JAPANESE
    assert_no_match(/Shift_JIS/i, html)
  end

  # the browser ignores a <meta> in a comment
  def test_html_body_without_a_charset_skips_a_commented_meta
    source = '<html><head><!-- <meta charset="UTF-8"> -->' \
             '<meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"></head>' \
             "<body><p>#{JAPANESE}</p></body></html>"
    raw = encoded_message('text/html', 'Shift_JIS', 'base64', source.encode('Shift_JIS').b)
    assert_includes convert(raw.sub('; charset=Shift_JIS'.b, ''.b)), JAPANESE
  end

  # nor does a '<meta' in a script, which the pattern finds too
  def test_html_body_without_a_charset_skips_a_meta_in_a_script
    source = '<html><head><script>var s = "<meta charset=UTF-8>";</script>' \
             '<meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"></head>' \
             "<body><p>#{JAPANESE}</p></body></html>"
    raw = encoded_message('text/html', 'Shift_JIS', 'base64', source.encode('Shift_JIS').b)
    assert_includes convert(raw.sub('; charset=Shift_JIS'.b, ''.b)), JAPANESE
  end

  # each <meta> charset tried converts the whole body: the labels of one
  # encoding count once, and only the first few are tried
  def test_html_body_tries_each_encoding_of_its_meta_once
    source = '<html><head>' + %w(utf-8 UTF-8 utf8 UTF_8).map { |c| %(<meta charset="#{c}">) }.join +
             '<meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"></head>' \
             "<body><p>#{JAPANESE}</p></body></html>"
    raw = encoded_message('text/html', 'Shift_JIS', 'base64', source.encode('Shift_JIS').b)
    assert_includes convert(raw.sub('; charset=Shift_JIS'.b, ''.b)), JAPANESE
  end

  # ISO-2022-JP is 7 bit: a broken escape is not replaced by U+FFFD, the body
  # is guessed and its text kept
  def test_iso_2022_jp_body_with_a_broken_escape_is_shown
    bytes = "before #{JAPANESE} after".encode('CP50221').b.sub("\e$B".b, "\e$Z".b)
    html = convert(encoded_message('text/plain', 'ISO-2022-JP', '7bit', bytes))
    assert_includes html, 'before'
    assert_includes html, 'after'
    assert_not_includes html, "\uFFFD"
  end

  def test_pre_contents_are_exactly_the_escaped_plain_text
    text = "  indented\nline"
    html = render_pre(text)
    contents = html[/<pre class='project_email_pre'>(.*?)<\/pre>/m, 1]

    assert_equal CGI.escapeHTML(text), contents
  end

  def test_pre_style_uses_a_selector_and_preserves_spaces
    html = render_pre('body')
    rule = html[/\.project_email_pre\s*\{[^}]*\}/m]

    # Previously the declarations had no selector, so they applied to nothing.
    # pre-line would collapse spaces that are significant in plain-text mail.
    assert rule, 'the declarations must belong to the project_email_pre selector'
    assert_includes rule, 'white-space: pre-wrap'
    assert_not_includes rule, 'pre-line'
  end
end
