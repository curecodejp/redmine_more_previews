# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class RepositoryNestedAssetTest < ActiveSupport::TestCase
  def setup
    @repository = Repository.new
    @repository.stubs(:preview_dirname).returns('/tmp/rmp-nested-preview')
    @repository.stubs(:preview_format).returns('html')
  end

  def test_nested_asset_name_preserves_relative_directory_and_extension
    assert_equal 'images/icons/logo.png',
                 @repository.preview_assetname('archive.zip', 'rev1', asset: 'images/icons/logo.png')
    assert_equal '/tmp/rmp-nested-preview/images/icons/logo.png',
                 @repository.preview_assetpath('archive.zip', 'rev1', asset: 'images/icons/logo.png')
  end

  def test_nested_asset_name_assembled_from_route_parameters
    options = {asset: 'images/icons/logo', assetformat: 'png'}
    assert_equal 'images/icons/logo.png',
                 @repository.preview_assetname('archive.zip', 'rev1', options)
    assert_equal '/tmp/rmp-nested-preview/images/icons/logo.png',
                 @repository.preview_assetpath('archive.zip', 'rev1', options)
  end
end
