# frozen_string_literal: true

# Run each case in a separate Rails process on an isolated test/staging host:
#   for n in 1000 5000 20000; do
#     RMP_BENCH_REPETITIONS="$n" RAILS_ENV=test bundle exec rails runner \
#       plugins/redmine_more_previews/scripts/benchmark_inline_preview.rb
#   done
#
# Synthetic HTML only; never run on a production server or with customer data.
require 'benchmark'
require 'json'

unless defined?(Rails) && defined?(ApplicationController)
  abort 'Run this script with rails runner from the Redmine root.'
end

helper = ApplicationController.helpers
unless helper.respond_to?(:sanitize_inline_preview)
  abort 'Redmine More Previews sanitizer is not loaded.'
end

# /proc/self/status VmHWM records the process high-water RSS, including
# temporary allocations that can disappear before sanitization returns.
# The absolute value also includes Rails startup; never treat the difference
# as an exact per-operation peak when startup had a higher high-water mark.
def process_memory_kib(field)
  status = '/proc/self/status'
  return nil unless File.readable?(status)

  File.read(status)[/^#{Regexp.escape(field)}:\s+(\d+)\s+kB$/, 1]&.to_i
end

repetitions = Integer(ENV.fetch('RMP_BENCH_REPETITIONS', '1000'), 10)
abort 'RMP_BENCH_REPETITIONS must be between 1 and 20000' unless (1..20_000).cover?(repetitions)

# Each repetition has three elements (span, b, script) and two text nodes
# (sample and ignored). The div wrapper
# contributes one element. Report the actual markup-node count explicitly.
html = '<div>' + ('<span class="entry"><b>sample</b></span><script>ignored</script>' * repetitions) + '</div>'
expected_elements = 1 + 3 * repetitions
expected_text_nodes = 2 * repetitions
rss_before = process_memory_kib('VmRSS')
hwm_before = process_memory_kib('VmHWM')
output = nil
seconds = Benchmark.realtime { output = helper.sanitize_inline_preview(html) }
rss_after = process_memory_kib('VmRSS')
hwm_after = process_memory_kib('VmHWM')

puts JSON.generate(
  repetitions: repetitions,
  input_element_nodes: expected_elements,
  input_text_nodes: expected_text_nodes,
  input_dom_nodes: expected_elements + expected_text_nodes,
  input_bytes: html.bytesize,
  output_bytes: output.bytesize,
  seconds: seconds.round(4),
  rss_before_kib: rss_before,
  rss_after_kib: rss_after,
  process_peak_rss_before_kib: hwm_before,
  process_peak_rss_after_kib: hwm_after,
  peak_includes_rails_startup: true
)
