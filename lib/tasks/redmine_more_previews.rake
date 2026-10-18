# encoding: utf-8
# frozen_string_literal: true

# Removes the cached previews created more than DAYS (default 30) days ago.
# Run it from cron, f.i. daily:
#   bundle exec rake redmine_more_previews:cache:clean RAILS_ENV=production DAYS=30
# Explicit all-cache purge (under the same per-preview locks):
#   bundle exec rake redmine_more_previews:cache:clean RAILS_ENV=production DAYS=0 CONFIRM_PURGE_ALL=1
namespace :redmine_more_previews do
  namespace :cache do
    desc 'Remove the previews cached more than DAYS (default 30) days ago'
    task :clean => :environment do
      raw_days = ENV['DAYS'].presence || RedmineMorePreviews::Constants::Defaults::CACHE_DAYS.to_s
      abort 'DAYS must be a non-negative integer' unless raw_days.to_s.match?(/\A\d+\z/)
      days = raw_days.to_i
      if days.zero? && ENV['CONFIRM_PURGE_ALL'] != '1'
        abort 'DAYS=0 removes all cached previews; set CONFIRM_PURGE_ALL=1 explicitly'
      end
      removed = RedmineMorePreviews::Lib::RmpCacheClean.run( days )
      puts "#{removed} cached previews removed"
    end
  end
end
