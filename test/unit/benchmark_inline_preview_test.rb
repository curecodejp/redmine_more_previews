# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'json'
require 'open3'
require 'rbconfig'

class BenchmarkInlinePreviewTest < ActiveSupport::TestCase
  SCRIPT = File.expand_path('../../scripts/benchmark_inline_preview.rb', __dir__).freeze

  def dry_run(profile, repetitions)
    stdout, stderr, status = Open3.capture3(
      { 'RMP_BENCH_DRY_RUN' => '1', 'RMP_BENCH_PROFILE' => profile,
        'RMP_BENCH_REPETITIONS' => repetitions.to_s },
      RbConfig.ruby, SCRIPT
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def test_balanced_markup_is_actually_sanitized_below_256_kib
    result = dry_run('balanced', 4000)
    assert_equal 'sanitizer', result.fetch('expected_path')
    assert_equal 256_011, result.fetch('input_bytes')
    assert_operator result.fetch('input_bytes'), :<=, result.fetch('limit_bytes')
    assert_equal 20_001, result.fetch('input_dom_nodes')
  end

  def test_dense_markup_stresses_more_nodes_without_hitting_size_limit
    result = dry_run('dense', 20_000)
    assert_equal 'sanitizer', result.fetch('expected_path')
    assert_equal 160_011, result.fetch('input_bytes')
    assert_operator result.fetch('input_bytes'), :<=, result.fetch('limit_bytes')
    assert_equal 40_001, result.fetch('input_dom_nodes')
  end

  def test_oversized_markup_measures_rejection_instead_of_sanitization
    result = dry_run('reject', 5000)
    assert_equal 'limit_rejection', result.fetch('expected_path')
    assert_equal 320_011, result.fetch('input_bytes')
    assert_operator result.fetch('input_bytes'), :>, result.fetch('limit_bytes')
  end

  def test_mislabeled_sanitizer_case_is_rejected
    _stdout, stderr, status = Open3.capture3(
      { 'RMP_BENCH_DRY_RUN' => '1', 'RMP_BENCH_PROFILE' => 'balanced',
        'RMP_BENCH_REPETITIONS' => '5000' },
      RbConfig.ruby, SCRIPT
    )
    assert_not status.success?
    assert_includes stderr, 'expected sanitizer, got limit_rejection'
  end
end
