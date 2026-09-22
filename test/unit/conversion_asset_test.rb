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
