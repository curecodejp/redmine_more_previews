# frozen_string_literal: true

# Run from the Redmine root (test/staging only):
#   RAILS_ENV=test bundle exec rails runner plugins/redmine_more_previews/scripts/benchmark_inline_preview.rb
#
# Benchmark synthetic, locally generated HTML only. Do not run under production
# load, and do not use untrusted or customer data as benchmark input.
require 'benchmark'
require 'json'

unless defined?(Rails) && defined?(ApplicationController)
  abort 'Run this script with rails runner from the Redmine root.'
end

helper = ApplicationController.helpers
unless helper.respond_to?(:sanitize_inline_preview)
  abort 'Redmine More Previews sanitizer is not loaded.'
end

def rss_kib
  status = '/proc/self/status'
  return nil unless File.readable?(status)

  value = File.read(status)[/^VmRSS:\s+(\d+)\s+kB$/, 1]
  value&.to_i
end

sizes = [1_000, 5_000, 20_000]
puts JSON.generate(event: 'inline_sanitizer_benchmark', ruby: RUBY_VERSION,
                   rails: Rails.version, rss_supported: !rss_kib.nil?)

sizes.each do |nodes|
  # Include attributes and a non-allowed element to exercise parsing and
  # scrubbing, without introducing external resources or executable content.
  html = '<div>' + ('<span class="entry"><b>sample</b></span><script>ignored</script>' * nodes) + '</div>'
  before = rss_kib
  output = nil
  seconds = Benchmark.realtime { output = helper.sanitize_inline_preview(html) }
  after = rss_kib

  puts JSON.generate(
    nodes: nodes,
    input_bytes: html.bytesize,
    output_bytes: output.bytesize,
    seconds: seconds.round(4),
    rss_before_kib: before,
    rss_after_kib: after,
    rss_delta_kib: before && after ? after - before : nil
  )
end
