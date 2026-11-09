# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Maggie takes TIFF as tif and tiff, both image/tiff. A file is matched by its
# content first: of the extensions of that type, the settings of the file's own
# extension apply, and a file of an extension that is turned off is not
# previewed, although another extension of its type is enabled.
class ConverterMimeExtensionTest < ActiveSupport::TestCase
  FIXTURES = File.expand_path('../../fixtures/maggie', __FILE__)

  def setup
    @previous = Setting.plugin_redmine_more_previews
    @dir = Dir.mktmpdir('rmp-mime-extension')
  end

  def teardown
    Setting.plugin_redmine_more_previews = @previous
    Setting.clear_cache
    FileUtils.rm_rf(@dir)
  end

  def test_each_tiff_extension_keeps_its_output_format
    configure('tif' => {'active' => '1', 'format' => 'png'}, 'tiff' => {'active' => '1', 'format' => 'jpg'})
    assert_equal 'png', RedmineMorePreviews::Converter.conversion_ext(tiff('scan.tif'))
    assert_equal 'jpg', RedmineMorePreviews::Converter.conversion_ext(tiff('scan.tiff'))
    assert_equal 'jpg', RedmineMorePreviews::Converter.conversion_ext(tiff('SCAN.TIFF'))
  end

  def test_a_tiff_extension_that_is_turned_off_is_not_previewed
    configure('tif' => {'active' => '1', 'format' => 'png'}, 'tiff' => {'active' => '0', 'format' => 'jpg'})
    assert_equal 'png', RedmineMorePreviews::Converter.conversion_ext(tiff('scan.tif'))
    assert_raises(RedmineMorePreviews::Exceptions::ConverterNotFound) do
      RedmineMorePreviews::Converter.mime(tiff('scan.tiff'))
    end
  end

  # a name of another type, or none: the first extension of the type, as before
  def test_a_tiff_under_another_name_takes_the_first_tiff_extension
    configure('tif' => {'active' => '1', 'format' => 'png'}, 'tiff' => {'active' => '1', 'format' => 'jpg'},
              'png' => {'active' => '0', 'format' => 'png'})
    assert_equal 'png', RedmineMorePreviews::Converter.conversion_ext(tiff('scan.png'))
    assert_equal 'png', RedmineMorePreviews::Converter.conversion_ext(tiff('scan'))
  end

  # content first, as before: a PNG named .tif is a PNG
  def test_content_of_another_type_ignores_the_extension
    configure('tif' => {'active' => '1', 'format' => 'jpg'}, 'png' => {'active' => '1', 'format' => 'gif'})
    png = File.join(@dir, 'image.tif')
    File.binwrite(png, Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=='))
    assert_equal 'gif', RedmineMorePreviews::Converter.conversion_ext(png)
  end

  # Marcel reports image/heif for a HEIC file of major brand mif1, and image/heic
  # for a HEIF file of major brand heic: heic and heif are each other's related
  # type, and the settings of the file's own extension apply
  def test_heic_and_heif_keep_the_settings_of_their_own_extension
    configure('heic' => {'active' => '1', 'format' => 'jpg'}, 'heif' => {'active' => '1', 'format' => 'gif'})
    assert_equal 'jpg', RedmineMorePreviews::Converter.conversion_ext(fixture('plain.heif', 'photo.heic'))
    assert_equal 'gif', RedmineMorePreviews::Converter.conversion_ext(fixture('plain.heic', 'photo.heif'))
    assert_equal 'jpg', RedmineMorePreviews::Converter.conversion_ext(fixture('plain.heic', 'photo.heic'))
    assert_equal 'gif', RedmineMorePreviews::Converter.conversion_ext(fixture('plain.heif', 'photo.heif'))
  end

  def test_a_heic_extension_that_is_turned_off_is_not_previewed
    configure('heic' => {'active' => '0', 'format' => 'jpg'}, 'heif' => {'active' => '1', 'format' => 'gif'})
    assert_raises(RedmineMorePreviews::Exceptions::ConverterNotFound) do
      RedmineMorePreviews::Converter.mime(fixture('plain.heif', 'photo.heic'))
    end
    configure('heic' => {'active' => '1', 'format' => 'jpg'}, 'heif' => {'active' => '0', 'format' => 'gif'})
    assert_raises(RedmineMorePreviews::Exceptions::ConverterNotFound) do
      RedmineMorePreviews::Converter.mime(fixture('plain.heic', 'photo.heif'))
    end
  end

  # under another name, the type of the content decides, as before
  def test_a_heif_under_another_name_takes_its_own_type
    configure('heic' => {'active' => '1', 'format' => 'jpg'}, 'heif' => {'active' => '1', 'format' => 'gif'},
              'png' => {'active' => '1', 'format' => 'png'})
    assert_equal 'gif', RedmineMorePreviews::Converter.conversion_ext(fixture('plain.heif', 'photo.png'))
    assert_equal 'jpg', RedmineMorePreviews::Converter.conversion_ext(fixture('plain.heic', 'photo.png'))
  end

  private

  def fixture(source, name)
    path = File.join(@dir, name)
    FileUtils.cp(File.join(FIXTURES, source), path)
    path
  end

  def configure(mime_types)
    Setting.plugin_redmine_more_previews = {
      'converter' => {'maggie' => {'active' => '1', 'mime_types' => mime_types}}
    }
    Setting.clear_cache
  end

  def tiff(name)
    path = File.join(@dir, name)
    FileUtils.cp(File.join(FIXTURES, 'multipage.tif'), path)
    path
  end
end
