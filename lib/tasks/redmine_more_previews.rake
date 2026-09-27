# encoding: utf-8
# frozen_string_literal: true

# Removes the cached previews created more than DAYS (default 30) days ago.
# Run it from cron, f.i. daily:
#   bundle exec rake redmine_more_previews:cache:clean RAILS_ENV=production DAYS=30
namespace :redmine_more_previews do
  namespace :cache do
    desc 'Remove the previews cached more than DAYS (default 30) days ago'
    task :clean => :environment do
      days = (ENV['DAYS'].presence || RedmineMorePreviews::Constants::Defaults::CACHE_DAYS).to_i
      abort "DAYS must be a positive number of days" unless days > 0
      removed = RedmineMorePreviews::Lib::RmpCacheClean.run( days )
      puts "#{removed} cached previews removed"
    end
  end
end
