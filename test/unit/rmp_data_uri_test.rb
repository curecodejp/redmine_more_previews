# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# The frame of an HTML preview has an opaque origin: the browser sends no
# session cookie with the requests of its document, so the images of an HTML
# preview are embedded as data: URIs instead of being linked.
class RmpDataUriTest < ActiveSupport::TestCase
  DataUri = RedmineMorePreviews::Lib::RmpDataUri

  PNG = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
  BUDGET = 1024 * 1024

  def setup
    @dir = Dir.mktmpdir('rmp-data-uri')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write(name, content = PNG)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def png_uri
    "data:image/png;base64,#{Base64.strict_encode64(PNG)}"
  end

  def test_image_of_a_raster_file
    assert_equal png_uri, DataUri.image(@dir, write('a.png'), BUDGET)
  end

  def test_the_type_comes_from_the_content_not_the_name
    assert_equal png_uri, DataUri.image(@dir, write('picture.txt'), BUDGET)
    assert_nil DataUri.image(@dir, write('fake.png', 'plain text'), BUDGET)
  end

  def test_no_image_of_svg_or_html
    assert_nil DataUri.image(@dir, write('a.svg', '<svg xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>'), BUDGET)
    assert_nil DataUri.image(@dir, write('a.html', '<html><body>x</body></html>'), BUDGET)
  end

  def test_no_image_of_a_symlink_or_a_file_outside_the_directory
    outside = Dir.mktmpdir('rmp-data-uri-outside')
    target = File.join(outside, 'b.png')
    File.binwrite(target, PNG)
    File.symlink(target, File.join(@dir, 'link.png'))
    assert_nil DataUri.image(@dir, File.join(@dir, 'link.png'), BUDGET)
    assert_nil DataUri.image(@dir, target, BUDGET)
    assert_nil DataUri.image(@dir, File.join(@dir, 'missing.png'), BUDGET)
  ensure
    FileUtils.rm_rf(outside)
  end

  def test_no_image_beyond_the_budget
    path = write('a.png')
    assert_nil DataUri.image(@dir, path, png_uri.bytesize - 1)
    assert_equal png_uri, DataUri.image(@dir, path, DataUri.uri_size(PNG.bytesize))
  end

  def test_embed_replaces_local_images_only
    write('a.png')
    write('sub/b.png')
    html = '<p><img src="a.png"><img alt="x" src=\'sub/b.png\'>' \
           '<img src="https://example.invalid/a.png"><img src="/a.png"><img src="../a.png">' \
           '<img src="a.png?x=1"><img src="data:image/gif;base64,R0lGOD"><a href="a.png">a</a></p>'
    embedded = DataUri.embed(html, @dir, BUDGET)
    assert_includes embedded, %(<img src="#{png_uri}">)
    assert_includes embedded, %(<img alt="x" src='#{png_uri}'>)
    %w(https://example.invalid/a.png /a.png ../a.png a.png?x=1 data:image/gif;base64,R0lGOD).each do |src|
      assert_includes embedded, %(src="#{src}"), "#{src} must be kept"
    end
    assert_includes embedded, '<a href="a.png">', 'only images are embedded'
  end

  def test_embed_decodes_percent_encoded_names
    write('議事録 v2_html_1.png')
    embedded = DataUri.embed(%(<img src="#{ERB::Util.url_encode('議事録 v2')}_html_1.png">), @dir, BUDGET)
    assert_equal %(<img src="#{png_uri}">), embedded
  end

  def test_embed_stops_at_the_budget
    write('a.png')
    write('b.png')
    embedded = DataUri.embed('<img src="a.png"><img src="b.png">', @dir, DataUri.uri_size(PNG.bytesize) + 10)
    assert_equal %(<img src="#{png_uri}"><img src="b.png">), embedded
  end

  # LibreOffice keeps a "'" of a document's name in the names of its images
  def test_embed_takes_a_src_holding_the_other_quote
    write("a'b_html_1.png")
    embedded = DataUri.embed(%(<img src="a'b_html_1.png" name="x">), @dir, BUDGET)
    assert_equal %(<img src="#{png_uri}" name="x">), embedded
  end

  def test_embed_keeps_a_page_that_is_not_utf8
    write('a.png')
    html = "<p>\xE9t\xE9</p><img src=\"a.png\">".b
    embedded = DataUri.embed(html, @dir, BUDGET)
    assert_equal "<p>\xE9t\xE9</p><img src=\"#{png_uri}\">".b, embedded.b
  end

  # LibreOffice writes the images of an HTML preview beside the page
  def test_libre_embeds_the_images_beside_the_page
    write('minutes_html_1.png')
    page = write('minutes.html', '<html><body><img src="minutes_html_1.png" name="x"></body></html>')
    worker = Libre.allocate
    worker.tmpdir = @dir
    worker.send(:embed_images, page)
    assert_includes File.read(page), %(<img src="#{png_uri}" name="x">)
  end

  # a page already larger than a preview is left as it is, without being read
  def test_libre_leaves_a_page_larger_than_a_preview
    write('minutes_html_1.png')
    page = write('minutes.html', '<img src="minutes_html_1.png">' + ' ' * (1024 * 1024))
    worker = Libre.allocate
    worker.tmpdir = @dir
    RedmineMorePreviews::Converter.stubs(:max_output).returns(1024 * 1024)
    File.expects(:binread).with(page).never
    worker.send(:embed_images, page)
    assert_includes File.read(page), '<img src="minutes_html_1.png">'
  end

  # the HTML LibreOffice writes is converted with its images embedded
  def test_libre_conversion_to_html_embeds_the_images
    worker = Libre.allocate
    worker.tmpdir = @dir
    worker.tmptarget = File.join(@dir, 'index.html')
    worker.source = write('minutes.docx', 'fake docx')
    worker.preview_format = 'html'
    worker.stubs(:sandbox_available?).returns(true)
    worker.stubs(:soffice).returns('fake soffice')
    worker.expects(:command).once.returns(true)
    # command is stubbed: write what LibreOffice would write
    write('minutes_html_1.png')
    write('minutes.html', '<html><body><img src="minutes_html_1.png"></body></html>')
    worker.convert
    assert_includes File.read(worker.tmptarget), %(<img src="#{png_uri}">)
  end
end
