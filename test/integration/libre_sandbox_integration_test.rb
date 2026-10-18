# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require 'zip'
require 'timeout'

# Opt-in on hosts with a working bwrap sandbox, system LibreOffice and pdfimages.
# The intentionally unsandboxed positive control uses ONLY generated dummy data.
class LibreSandboxIntegrationTest < ActiveSupport::TestCase
  def test_external_file_image_is_inaccessible_but_document_converts
    worker = Libre.allocate
    unless worker.send(:sandbox_available?) && system('command -v pdfimages >/dev/null 2>&1')
      message = 'working bwrap/soffice namespace and pdfimages are required'
      flunk message if ENV['RMP_LIBRE_REQUIRE_SANDBOX'] == '1'
      skip message
    end

    Dir.mktmpdir('rmp-libre-integration') do |root|
      stage = File.join(root, 'staged')
      outside = File.join(root, 'outside')
      sandbox_output = File.join(root, 'sandbox-output')
      control_output = File.join(root, 'control-output')
      profile = File.join(root, 'profile')
      [stage, outside, sandbox_output, control_output, profile].each { |dir| FileUtils.mkdir_p(dir) }
      image = File.join(outside, 'DUMMY.png')
      File.binwrite(image, dummy_png)
      input = File.join(stage, 'external-image.odt')
      build_odt(input, "file://#{image}")

      worker.tmpdir = sandbox_output
      worker.preview_format = 'pdf'
      command = Shellwords.split(worker.soffice(input, File.join(profile, 'user_installation')))
      stdout, stderr, status = Timeout.timeout(120) { Open3.capture3(*command) }
      assert status.success?, "Sandboxed LibreOffice failed: #{stdout} #{stderr}"
      pdf = File.join(sandbox_output, 'external-image.pdf')
      assert File.file?(pdf), 'Sandboxed conversion must still produce a PDF'
      assert File.binread(pdf, 5).start_with?('%PDF-')
      worker.send(:validate_libre_output!)
      assert_equal 0, image_objects_4x4(pdf), 'External file image must not be embedded'

      control_profile = File.join(root, 'control-profile')
      stdout, stderr, status = Timeout.timeout(120) do
        Open3.capture3(Libre::LIBRE_OFFICE_BIN,
                       "-env:UserInstallation=file://#{control_profile}",
                       '--headless', '--convert-to', 'pdf', '--outdir', control_output, input)
      end
      assert status.success?, "Unsandboxed dummy-only control failed: #{stdout} #{stderr}"
      control_pdf = File.join(control_output, 'external-image.pdf')
      assert File.file?(control_pdf)
      assert_operator image_objects_4x4(control_pdf), :>=, 1,
                      'Positive control must embed the generated external PNG'
    end
  end

  private

  def image_objects_4x4(pdf)
    stdout, stderr, status = Timeout.timeout(20) { Open3.capture3('pdfimages', '-list', pdf) }
    assert status.success?, "pdfimages failed: #{stderr}"
    stdout.lines.count do |line|
      columns = line.split
      columns.length >= 5 && columns[0].match?(/\A\d+\z/) &&
        columns[3] == '4' && columns[4] == '4'
    end
  end

  def png_chunk(kind, body)
    [body.bytesize].pack('N') + kind + body + [Zlib.crc32(kind + body)].pack('N')
  end

  def dummy_png
    rows = 4.times.map do |y|
      "\x00".b + 4.times.map do |x|
        [20 + x * 60, 25 + y * 55, 50 + (x + y * 4) * 12].pack('C3')
      end.join
    end.join
    "\x89PNG\r\n\x1a\n".b +
      png_chunk('IHDR', [4, 4, 8, 2, 0, 0, 0].pack('NNC5')) +
      png_chunk('IDAT', Zlib::Deflate.deflate(rows)) + png_chunk('IEND', ''.b)
  end

  def build_odt(path, file_url)
    namespaces = 'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" ' \
                 'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" ' \
                 'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" ' \
                 'xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" ' \
                 'xmlns:xlink="http://www.w3.org/1999/xlink"'
    content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" \
              "<office:document-content #{namespaces} office:version=\"1.2\">" \
              '<office:body><office:text><text:p>LIBRE-SANDBOX-TEST</text:p>' \
              '<text:p><draw:frame draw:name="ExternalImage" text:anchor-type="as-char" ' \
              'svg:width="3cm" svg:height="3cm">' \
              "<draw:image xlink:href=\"#{file_url}\" xlink:type=\"simple\" " \
              'xlink:show="embed" xlink:actuate="onLoad"/>' \
              '</draw:frame></text:p></office:text></office:body></office:document-content>'
    manifest = '<?xml version="1.0" encoding="UTF-8"?>' \
               '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" ' \
               'manifest:version="1.2">' \
               '<manifest:file-entry manifest:full-path="/" ' \
               'manifest:media-type="application/vnd.oasis.opendocument.text"/>' \
               '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>' \
               '</manifest:manifest>'
    Zip::File.open(path, create: true) do |zip|
      zip.get_output_stream('mimetype') { |io| io.write('application/vnd.oasis.opendocument.text') }
      zip.get_output_stream('content.xml') { |io| io.write(content) }
      zip.get_output_stream('META-INF/manifest.xml') { |io| io.write(manifest) }
    end
  end
end
