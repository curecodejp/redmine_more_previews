# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class VinceEscapingTest < ActiveSupport::TestCase
  def setup
    @escaping = Object.new.extend(VinceLib::VObject::Modules::Escaping)
  end

  def test_scalar_values_round_trip_through_escape_and_unescape
    values = [
      'plain',
      'back\\slash',
      'literal\\ntext',
      "line1\nline2",
      'comma,here',
      'semicolon;here',
      'colon:here',
      "mixed\\,;:\nend",
      'unknown\\qescape'
    ]

    values.each do |value|
      assert_equal value, @escaping.unesc(@escaping.esc(value)), value.inspect
    end
  end

  def test_backslash_is_escaped_before_other_sequences
    assert_equal 'back\\\\slash', @escaping.esc_str('back\\slash')
    assert_equal 'literal\\\\ntext', @escaping.esc_str('literal\\ntext')
    assert_equal 'line1\\nline2', @escaping.esc_str("line1\nline2")
  end

  def test_legacy_colon_escape_and_uppercase_newline_are_still_accepted
    assert_equal 'legacy:colon', @escaping.unesc_str('legacy\\:colon')
    assert_equal "line1\nline2", @escaping.unesc_str('line1\\Nline2')
  end

  def test_csv_split_handles_an_escaped_backslash_before_the_separator
    values = ['ends-with-backslash\\', 'comma,value', 'tail']

    assert_equal values, @escaping.unesc_csv_to_arr(@escaping.esc_arr_to_csv(values))
  end

  def test_ssv_split_handles_an_escaped_backslash_before_the_separator
    values = ['ends-with-backslash\\', 'semicolon;value', 'tail']

    assert_equal values, @escaping.unesc_ssv_to_arr(@escaping.esc_arr_to_ssv(values))
  end
end
