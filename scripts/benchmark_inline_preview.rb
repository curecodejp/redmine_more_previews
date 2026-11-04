# frozen_string_literal: true

# Run each case in a separate Rails process on an isolated test/staging host:
#   RMP_BENCH_PROFILE=balanced RMP_BENCH_REPETITIONS=4000 RAILS_ENV=test bundle exec rails runner \
#     plugins/redmine_more_previews/scripts/benchmark_inline_preview.rb
#   RMP_BENCH_PROFILE=dense RMP_BENCH_REPETITIONS=20000 RAILS_ENV=test bundle exec rails runner \
#     plugins/redmine_more_previews/scripts/benchmark_inline_preview.rb
#   RMP_BENCH_PROFILE=reject RMP_BENCH_REPETITIONS=5000 RAILS_ENV=test bundle exec rails runner \
#     plugins/redmine_more_previews/scripts/benchmark_inline_preview.rb
#
# Inspect input sizes without Rails (not a sanitizer or memory benchmark):
#   RMP_BENCH_DRY_RUN=1 RMP_BENCH_PROFILE=dense ruby plugins/redmine_more_previews/scripts/benchmark_inline_preview.rb
#
# Synthetic HTML only; never run on a production server or with customer data.
require 'benchmark'
require 'json'

cases = {
  'balanced' => {
    fragment: '<span class="entry"><b>sample</b></span><script>ignored</script>',
    default_repetitions: 4000, elements_per_repetition: 3, text_nodes_per_repetition: 2,
    expected_path: 'sanitizer'
  },
  'dense' => {
    fragment: '<b>x</b>',
    default_repetitions: 20_000, elements_per_repetition: 1, text_nodes_per_repetition: 1,
    expected_path: 'sanitizer'
  },
  'reject' => {
    fragment: '<span class="entry"><b>sample</b></span><script>ignored</script>',
    default_repetitions: 5000, elements_per_repetition: 3, text_nodes_per_repetition: 2,
    expected_path: 'limit_rejection'
  },
  # Nested below Nokogiri's default HTML5 tree depth limit (400).
  'deep' => {
    fragment: '<div>', closing_fragment: '</div>',
    default_repetitions: 390, elements_per_repetition: 1, text_nodes_per_repetition: 0,
    expected_path: 'sanitizer'
  },
  # Nested above that limit, still far below the size limit.
  'deep_over_parser_limit' => {
    fragment: '<div>', closing_fragment: '</div>',
    default_repetitions: 5000, elements_per_repetition: 1, text_nodes_per_repetition: 0,
    expected_path: 'sanitizer'
  },
  # Forty attributes per element, all of which the scrubber has to remove.
  'attrs' => {
    fragment: "<span #{(0...40).map { |i| %(a#{i}="1") }.join(' ')}>x</span>",
    default_repetitions: 700, elements_per_repetition: 1, text_nodes_per_repetition: 1,
    expected_path: 'sanitizer'
  },
  # One element above Nokogiri's default limit of 400 attributes per element.
  'attrs_over_parser_limit' => {
    fragment: "<span #{(0...500).map { |i| %(a#{i}="1") }.join(' ')}>x</span>",
    default_repetitions: 1, elements_per_repetition: 1, text_nodes_per_repetition: 1,
    expected_path: 'sanitizer'
  },
  # Every style attribute goes through Loofah's CSS scrubbing.
  'style' => {
    fragment: '<span style="color:red;font-size:1px">x</span>',
    default_repetitions: 5000, elements_per_repetition: 1, text_nodes_per_repetition: 1,
    expected_path: 'sanitizer'
  },
  # One style attribute holding nearly all of the input.
  'style_long' => {
    fragment: "<span style=\"#{'color:red;' * 26_000}\">x</span>",
    default_repetitions: 1, elements_per_repetition: 1, text_nodes_per_repetition: 1,
    expected_path: 'sanitizer'
  },
  # Repeated subtrees just below the tree depth limit.
  'deep_repeated' => {
    fragment: '<div>' * 390 + '</div>' * 390,
    default_repetitions: 60, elements_per_repetition: 390, text_nodes_per_repetition: 0,
    expected_path: 'sanitizer'
  }
}.freeze

profile = ENV.fetch('RMP_BENCH_PROFILE', 'balanced')
abort "Unknown RMP_BENCH_PROFILE: #{profile.inspect}" unless cases.key?(profile)
case_info = cases.fetch(profile)
repetitions = Integer(ENV.fetch('RMP_BENCH_REPETITIONS', case_info[:default_repetitions].to_s), 10)
abort 'RMP_BENCH_REPETITIONS must be between 1 and 20000' unless (1..20_000).cover?(repetitions)
iterations = Integer(ENV.fetch('RMP_BENCH_ITERATIONS', '1'), 10)
abort 'RMP_BENCH_ITERATIONS must be between 1 and 100' unless (1..100).cover?(iterations)

html = '<div>' + case_info[:fragment] * repetitions + case_info[:closing_fragment].to_s * repetitions + '</div>'
# These are counts of *source* nodes, not the nodes actually passed to the
# sanitizer (especially in the limit-rejection case, which parses no HTML).
source_elements = 1 + case_info[:elements_per_repetition] * repetitions
source_text_nodes = case_info[:text_nodes_per_repetition] * repetitions

# The 256 KiB value below is used *only* by the standalone dry run. The actual
# benchmark gets the limit from the plugin, so it detects a future change.
dry_run = ENV['RMP_BENCH_DRY_RUN'] == '1'
if dry_run
  max_inline_bytes = 256 * 1024
else
  unless defined?(Rails) && defined?(ApplicationController)
    abort 'Run this script with rails runner from the Redmine root.'
  end
  unless Rails.env.test? || Rails.env.staging?
    abort 'Benchmark only permitted in test or staging environments.'
  end
  max_inline_bytes = RedmineMorePreviews::Patches::ApplicationHelperPatch::MAX_INLINE_PREVIEW_HTML_BYTES
end

expected_path = case_info[:expected_path]
actual_path = html.bytesize > max_inline_bytes ? 'limit_rejection' : 'sanitizer'
if actual_path != expected_path
  abort "#{profile} input is #{html.bytesize} bytes (limit #{max_inline_bytes}); expected #{expected_path}, got #{actual_path}. Adjust the repetitions."
end

result = {
  profile: profile,
  expected_path: expected_path,
  repetitions: repetitions,
  iterations: iterations,
  input_bytes: html.bytesize,
  limit_bytes: max_inline_bytes,
  input_element_nodes: source_elements,
  input_text_nodes: source_text_nodes,
  input_dom_nodes: source_elements + source_text_nodes,
  node_counts_are_source_estimates: true
}

if dry_run
  puts JSON.generate(result.merge(dry_run: true))
  exit 0
end

helper = ApplicationController.helpers
abort 'Redmine More Previews sanitizer is not loaded.' unless helper.respond_to?(:sanitize_inline_preview)

# /proc/self/status VmHWM records high-water RSS, including temporary
# allocations. Startup may have a higher high-water mark than this operation;
# do not interpret the difference as an exact per-sanitization peak.
def process_memory_kib(field)
  status = '/proc/self/status'
  return nil unless File.readable?(status)

  File.read(status)[/^#{Regexp.escape(field)}:\s+(\d+)\s+kB$/, 1]&.to_i
end

# Initialize I18n and the sanitizer before timing or measuring RSS. The first
# translation lookup can load all locales and otherwise dominate the rejection
# timing, although rejection itself never parses the oversized HTML.
notice = ERB::Util.html_escape(helper.l(:text_more_previews_inline_too_large))
helper.sanitize_inline_preview('<b>warm-up</b>')

rss_before = process_memory_kib('VmRSS')
hwm_before = process_memory_kib('VmHWM')
output = nil
error = nil
# Sampled after every iteration to show whether repeated views of one preview
# plateau or keep growing. RSS can only hint at this; it is not a leak check.
seconds_each = []
rss_after_each = []
iterations.times do
  seconds_each << Benchmark.realtime do
    output = helper.sanitize_inline_preview(html)
  rescue StandardError, SystemStackError => e
    # The parser's own limits raise; a page render would fail the same way.
    error = "#{e.class}: #{e.message}"
  end
  rss_after_each << process_memory_kib('VmRSS')
  break if error
end
seconds = seconds_each.first
rss_after = rss_after_each.first
hwm_after = process_memory_kib('VmHWM')

if error
  # Reported below: an exception is itself the result for this input.
elsif expected_path == 'limit_rejection'
  abort 'The oversized preview did not return the size notice.' unless output.to_s == notice
else
  abort 'The sanitizer case unexpectedly returned the size notice.' if output.to_s == notice
  abort 'The sanitizer leaked a script tag.' if profile == 'balanced' && output.to_s.include?('<script')
end

puts JSON.generate(result.merge(
  output_bytes: output.to_s.bytesize,
  error: error,
  seconds: seconds.round(7),
  seconds_each: seconds_each.map { |value| value.round(7) },
  rss_after_each_kib: rss_after_each,
  rss_before_kib: rss_before,
  rss_after_kib: rss_after,
  process_peak_rss_before_kib: hwm_before,
  process_peak_rss_after_kib: hwm_after,
  peak_includes_rails_startup: true
))
