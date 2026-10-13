# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# A repository's cached conversion files must be deleted with the repository,
# without affecting any other repository or the shared preview storage root.
class RepositoryPreviewDestroyTest < ActiveSupport::TestCase
  fixtures :projects, :repositories, :enabled_modules

  def setup
    @old_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = (@old_scm + ['Filesystem']).uniq
    @source = Dir.mktmpdir('rmp-repo-source')
    @cache = Dir.mktmpdir('rmp-repo-cleanup')
    @old_cache = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @cache)

    EnabledModule.find_or_create_by!(project_id: 3, name: 'repository')
    @repository = Repository::Filesystem.create!(
      project: Project.find(3), url: @source, path_encoding: '', is_default: true
    )
  end

  def teardown
    Setting.enabled_scm = @old_scm
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_cache)
    FileUtils.rm_rf(@cache)
    FileUtils.rm_rf(@source)
  end

  def test_destroy_removes_only_this_repository_cache
    target = @repository.preview_storagepath
    cached = File.join(target, 'docs', 'digest', 'preview.html')
    FileUtils.mkdir_p(cached)
    File.write(File.join(cached, 'index.html'), 'private preview')
    File.write("#{cached}.converter", 'cliff:safe-debug-v1:normal')

    other_cache = File.join(@repository.previews_storagepath, '999999', 'keep.txt')
    FileUtils.mkdir_p(File.dirname(other_cache))
    File.write(other_cache, 'another repository')
    outside = File.join(@cache, 'keep.txt')
    File.write(outside, 'shared storage')

    @repository.destroy!

    assert_not File.exist?(target)
    assert_equal 'another repository', File.read(other_cache)
    assert_equal 'shared storage', File.read(outside)
  end

  def test_destroy_does_not_follow_repository_cache_symlink_outside_root
    external = Dir.mktmpdir('rmp-outside')
    File.write(File.join(external, 'secret.txt'), 'keep')
    root = @repository.previews_storagepath
    FileUtils.mkdir_p(root)
    File.symlink(external, @repository.preview_storagepath)

    @repository.destroy!
    assert_equal 'keep', File.read(File.join(external, 'secret.txt'))
  ensure
    FileUtils.rm_rf(external) if external
  end

  def test_destroy_without_a_cache_directory_still_succeeds
    assert_not File.exist?(@repository.preview_storagepath)
    assert_difference('Repository.count', -1) { @repository.destroy! }
  end
end
