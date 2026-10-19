# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class VinceFiltersTest < ActiveSupport::TestCase
  def setup
    @filters = Object.new.extend(VinceLib::VObject::Modules::Filters)
  end

  def test_array_minus_removes_only_exact_non_regexp_matches
    input = [[:type, 'home'], [:type, 'work'], [:value, 'home']]
    compared = [[:type, 'home']]

    assert_equal [[:type, 'work'], [:value, 'home']], @filters.array_minus(input, compared)
    assert_equal [[:type, 'home'], [:type, 'work'], [:value, 'home']], input
  end

  def test_array_minus_preserves_non_matching_entries
    assert_equal [[:type, 'home']],
                 @filters.array_minus([[:type, 'home']], [[:type, 'work'], [:value, 'home']])
  end

  def test_array_minus_retains_regexp_matching_support
    pattern = /home\z/
    input = [[:type, pattern], [:type, 'work']]

    assert_equal [[:type, 'work']], @filters.array_minus(input, [[:type, 'at home']])
  end
end
