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

  def convert(mail_source)
    eml = File.join(@tmp, 'a.eml')
    File.write(eml, mail_source)
    worker = RedmineMorePreviews::Converter.find(:cliff).worker(
      :preview_format => 'html', :object => {}, :target => File.join(@tmp, 'preview.html', 'index.html')
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

  # cliff ships a second copy of its templates next to the library, and that is
  # the one a packaged install renders; escaping only one of them would leave
  # the exposure in place where it is hardest to notice
  def test_bundled_pre_template_copy_is_in_sync
    app = File.expand_path('../../converters/cliff/app/views/cliff/pre.html.erb', __dir__)
    lib = File.expand_path('../../converters/cliff/lib/cliff/pre.html.erb', __dir__)
    assert_equal File.read(app), File.read(lib)
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

  # the message of a parse failure quotes the mail, so it is attacker controlled
  def test_the_error_page_escapes_the_exception_message
    Mail.expects(:new).raises(RuntimeError.new("broken #{MARKUP}"))
    html = convert(plain_message('body'))
    assert_not_includes html, '<b>bold</b>'
    assert_includes html, '&lt;b&gt;bold&lt;/b&gt;'
  end
end
