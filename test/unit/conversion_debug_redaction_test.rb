# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Debug results may be cached and subsequently served to another viewer. Never
# expose worker instance variables, request parameters, filesystem paths, etc.
class ConversionDebugRedactionTest < ActiveSupport::TestCase
  def setup
    @dir = Dir.mktmpdir('rmp-debug-redaction')
    @source = File.join(@dir, 'PRIVATE_SOURCE_PATH.txt')
    File.write(@source, 'source data')
    @target = File.join(@dir, 'cache', 'preview.txt', 'index.txt')
    @object = Struct.new(:project, :id).new(nil, 'SECRET_ATTACHMENT_ID')
    @worker = pass_worker
    @worker.source = @source
    @worker.request = Struct.new(:url, :parameters).new(
      'https://example.invalid/preview?token=SECRET_REQUEST_TOKEN',
      {'controller' => 'SECRET_CONTROLLER'}
    )
    @worker.settings = {'password' => 'SECRET_SETTING_PASSWORD'}
    @worker.instance_variable_set(:@custom_secret, 'SECRET_ARBITRARY_IVAR')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_debug_fields_are_an_explicit_allowlist
    fields = @worker.send(:debug_fields)
    assert_equal %w(converter converter_version plugin_version source_type preview_format), fields.keys
    assert_equal 'attachment', fields['source_type']
    assert_equal 'txt', fields['preview_format']
    assert fields.values.all? { |value| value.is_a?(String) }
    assert_no_secrets(fields.inspect)
  end

  def test_html_and_inline_debug_previews_do_not_expose_internal_state
    %w(html inline).each do |format|
      html = render_debug(format)
      assert_includes html, 'Converter debug information'
      assert_includes html, 'preview_format'
      assert_includes html, format
      assert_no_secrets(html)
      assert_not_includes html, '@source'
      assert_not_includes html, '@request'
    end
  end

  def test_text_debug_preview_does_not_expose_internal_state
    txt = render_debug('txt')
    assert_includes txt, 'Converter debug information'
    assert_includes txt, 'source_type'
    assert_no_secrets(txt)
  end

  def test_image_debug_uses_only_the_allowlisted_fields
    RedmineMorePreviews::Lib::RmpImg.expects(:to_img).with do |markup, format|
      assert_equal 'png', format
      assert_includes markup, 'preview_format'
      assert_no_secrets(markup)
      true
    end.returns('SAFE_IMAGE')
    assert_equal 'SAFE_IMAGE', render_debug('png')
  end

  def test_pdf_debug_passes_only_allowlisted_fields_to_renderer
    RedmineMorePreviews::Lib::RmpPdf.expects(:more_prewiew_to_pdf).with do |fields|
      assert_equal %w(converter converter_version plugin_version source_type preview_format), fields.keys
      assert_equal 'pdf', fields['preview_format']
      assert_no_secrets(fields.inspect)
      true
    end.returns('%PDF-SAFE')
    assert_equal '%PDF-SAFE', render_debug('pdf')
  end

  def test_cached_debug_preview_contains_no_private_data
    RedmineMorePreviews::Converter.stubs(:debug?).returns(true)
    result = pass_worker.preview(File.new(@source))
    assert_includes result, 'Converter debug information'
    assert_no_secrets(result)
    assert File.file?(@target)

    # A different request gets the exact same cached diagnostic content.
    Pass.any_instance.expects(:convert).never
    another_viewer = pass_worker
    another_viewer.request = Struct.new(:url, :parameters).new(
      'https://example.invalid/?token=DIFFERENT_PRIVATE_TOKEN', {}
    )
    cached = another_viewer.preview(File.new(@source))
    assert_equal result, cached
    assert_no_secrets(cached)
  end

  private

  def pass_worker
    RedmineMorePreviews::Converter.find(:pass).worker(
      preview_format: 'txt', format: 'txt', target: @target,
      object: {type: :attachment, object: @object}
    )
  end

  def render_debug(format)
    @worker.preview_format = format
    @worker.format = format
    @worker.tmpdir = @dir
    @worker.tmptarget = File.join(@dir, "debug.#{format}")
    @worker.debug
    File.binread(@worker.tmptarget)
  end

  def assert_no_secrets(output)
    %w(PRIVATE_SOURCE_PATH SECRET_ATTACHMENT_ID SECRET_REQUEST_TOKEN
       SECRET_CONTROLLER SECRET_SETTING_PASSWORD SECRET_ARBITRARY_IVAR
       rmp-debug-redaction).each do |secret|
      assert_not_includes output, secret
    end
  end
end
