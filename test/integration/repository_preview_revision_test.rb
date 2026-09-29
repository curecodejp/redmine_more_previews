# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'open3'

# The cached Zippy listing links to the request path it was generated for, which
# carries the revision. A revision with the same content must not be served a
# listing whose links lead to another revision. (A functional test builds
# request.path from the first matching route, without the revision, so this needs
# the real routing.)
class RepositoryPreviewRevisionTest < Redmine::IntegrationTest
  include RedmineMorePreviews::TestHelper

  fixtures :users, :email_addresses, :projects, :roles, :members, :member_roles,
           :enabled_modules, :repositories

  PRJ_ID = 4

  def setup
    super
    @old_enabled_scm = Setting.enabled_scm.dup
    Setting.enabled_scm = (@old_enabled_scm + ['Git']).uniq
    @old_settings = Setting.plugin_redmine_more_previews
    Setting.plugin_redmine_more_previews = ZIPPY_SETTINGS
    %w(repository redmine_more_previews).each do |name|
      EnabledModule.find_or_create_by!(project_id: PRJ_ID, name: name)
    end

    @storage = Dir.mktmpdir('rmp-storage')
    @old_storage = RedmineMorePreviews::Constants::Defaults::MORE_PREVIEWS_STORAGE_PATH
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @storage)

    @dir = Dir.mktmpdir('rmp-git-repo')
    git('init', '-q', '-b', 'master')
    @repository = Repository::Git.create!(project: Project.find(PRJ_ID), url: File.join(@dir, '.git'),
                                          path_encoding: '', is_default: true)
    log_user('admin', 'admin')
  end

  def teardown
    super
    Setting.enabled_scm = @old_enabled_scm
    Setting.plugin_redmine_more_previews = @old_settings
    Setting.clear_cache # the writer caches the symbol key; the plugin reads the string key
    RedmineMorePreviews::Constants::Defaults.send(:remove_const, :MORE_PREVIEWS_STORAGE_PATH)
    RedmineMorePreviews::Constants::Defaults.const_set(:MORE_PREVIEWS_STORAGE_PATH, @old_storage)
    FileUtils.rm_rf(@storage)
    FileUtils.rm_rf(@dir)
  end

  def test_listing_links_to_the_requested_revision
    c1 = commit_zip('dir/old.txt' => 'old')
    get "/projects/#{PRJ_ID}/repository/#{@repository.id}/preview/a.zip@/index.html"
    assert_response :success
    assert_includes response.body, 'old.txt'

    # master moves on; c1 still holds the content cached for master
    commit_zip('dir/new.txt' => 'new')
    get "/projects/#{PRJ_ID}/repository/#{@repository.id}/#{c1}/preview/a.zip@/index.html"
    assert_response :success
    assert_includes response.body, "/#{c1}/preview/a.zip@/index.html?asset=dir%2Fold.txt"

    get "/projects/#{PRJ_ID}/repository/#{@repository.id}/#{c1}/preview/a.zip@/index.html?asset=dir%2Fold.txt"
    assert_response :success
    assert_equal 'old', response.body
  end

  # a revision the route's :rev does not take (a slash, capitals) comes as the
  # rev query parameter: the links keep it, or they lead to the default branch
  def test_listing_links_keep_a_revision_given_as_a_parameter
    commit_zip('dir/entry.txt' => 'master')
    git('checkout', '-q', '-b', 'feature/Review')
    commit_zip('dir/entry.txt' => 'branch')
    git('checkout', '-q', 'master')

    get "/projects/#{PRJ_ID}/repository/#{@repository.id}/preview/a.zip@/index.html?rev=feature%2FReview"
    assert_response :success
    link = response.body[%r{href="([^"]*asset=dir%2Fentry\.txt[^"]*)"}, 1]
    assert link, 'the listing links to the entry'
    link = CGI.unescapeHTML(link)
    assert_includes link, 'rev=feature%2FReview'

    get link
    assert_response :success
    assert_equal 'branch', response.body
  end

  private

  # replaces a.zip with an archive of +entries+, commits it and returns the commit id
  def commit_zip(entries)
    FileUtils.rm_f(File.join(@dir, 'a.zip'))
    build_zip(File.join(@dir, 'a.zip'), {'dir/' => ''}.merge(entries))
    git('add', 'a.zip')
    git('-c', 'user.name=test', '-c', 'user.email=test@example.net', 'commit', '-q', '-m', 'a.zip')
    git('rev-parse', 'HEAD').strip
  end

  def git(*args)
    out, status = Open3.capture2e('git', '-C', @dir, *args)
    assert status.success?, out
    out
  end
end
