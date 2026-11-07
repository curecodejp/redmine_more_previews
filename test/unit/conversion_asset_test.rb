# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class ConversionAssetTest < ActiveSupport::TestCase
  include RedmineMorePreviews::TestHelper

  def test_worker_rejects_asset_escaping_the_preview_directory
    Dir.mktmpdir do |cache|
      target = File.join(cache, 'preview.html', 'index.html')
      ['../escaped.txt', 'dir/../../escaped.txt', '/etc/hostname', "a\0b"].each do |asset|
        assert_raises RedmineMorePreviews::Exceptions::ConverterBadArgument, asset do
          zippy_worker(target: target, asset: asset)
        end
      end
    end
  end

  def test_worker_rejects_assets_list_entries_escaping_the_preview_directory
    Dir.mktmpdir do |cache|
      target = File.join(cache, 'preview.html', 'index.html')
      assert_raises RedmineMorePreviews::Exceptions::ConverterBadArgument do
        zippy_worker(target: target, assets: ['ok.png', '../escaped.png'])
      end
    end
  end

  def test_worker_normalizes_accepted_asset_names
    Dir.mktmpdir do |cache|
      target = File.join(cache, 'preview.html', 'index.html')
      worker = zippy_worker(target: target, asset: './dir//file.txt')
      assert_equal 'dir/file.txt', worker.asset
      assert_equal File.join(cache, 'preview.html', 'dir', 'file.txt'), worker.assetpath
    end
  end

  # no two names of an archive may share a file, nor one share the preview's
  def test_entries_named_like_the_preview_are_stored_apart_from_it
    Dir.mktmpdir do |cache|
      dir = File.join(cache, 'preview.html')
      stored = {
        'index.html'             => 'index.html.entry',
        'index.html.entry'       => 'index.html.entry.entry',
        'index.html/nested.txt'  => 'index.html.entry/nested.txt',
        'index.htmlx'            => 'index.htmlx.entry',
        'a/index.html'           => 'a/index.html',
        'other.txt'              => 'other.txt'
      }
      stored.each do |asset, name|
        worker = zippy_worker(target: File.join(dir, asset), asset: asset, preview_format: 'html')
        assert_equal asset, worker.asset
        assert_equal dir, worker.dir, asset
        assert_equal File.join(dir, name), worker.assetpath, asset
        assert_equal File.join(dir, name), worker.targetpath, asset
      end
    end
  end

  # the name of the preview follows its format
  def test_entry_named_index_html_is_stored_as_it_is_for_an_inline_listing
    Dir.mktmpdir do |cache|
      dir = File.join(cache, 'preview.inline')
      worker = zippy_worker(target: File.join(dir, 'index.html'), asset: 'index.html', preview_format: 'inline')
      assert_equal File.join(dir, 'index.html'), worker.assetpath
      worker = zippy_worker(target: File.join(dir, 'index.inline'), asset: 'index.inline', preview_format: 'inline')
      assert_equal File.join(dir, 'index.inline.entry'), worker.assetpath
    end
  end

  # a converter that writes its assets with the preview has no entry of that
  # name: the asset would be the preview, and its failure the preview's
  def test_asset_named_as_the_preview_of_another_converter_is_not_served
    Dir.mktmpdir do |cache|
      source = File.join(cache, 'source.html')
      File.write(source, '<p>source</p>')
      target = File.join(cache, 'preview.html', 'index.html')
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, '<p>preview</p>')
      worker = RedmineMorePreviews::Converter.find(:pass).worker(
        preview_format: 'html', object: {}, asset: 'index.html', target: target
      )
      worker.expects(:convert).never
      RedmineMorePreviews::Lib::RmpFailures.expects(:record).never

      assert_nil worker.preview(File.new(source))
      assert_equal '<p>preview</p>', File.read(target)
    end
  end

  def test_cached_asset_is_not_read_through_a_symlink
    Dir.mktmpdir do |cache|
      Dir.mktmpdir do |outside|
        secret = File.join(outside, 'secret.txt')
        File.write(secret, 'top secret')

        preview_dir = File.join(cache, 'preview.html')
        FileUtils.mkdir_p(preview_dir)
        File.write(File.join(preview_dir, 'index.html'), '<html></html>')
        File.symlink(secret, File.join(preview_dir, 'link.txt'))

        worker = zippy_worker(target: File.join(preview_dir, 'index.html'), asset: 'link.txt')
        assert_nil worker.read_safe
      end
    end
  end
end
