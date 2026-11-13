# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# A key of a translation that English does not have is never looked up: it is
# misspelt (Label_… for label_…, do_do_not_…), and the text is shown in English.
class LocaleKeysTest < ActiveSupport::TestCase
  ROOT = File.expand_path('../..', __dir__)

  # the names of languages, which each language may name apart
  LANGUAGE_NAMES = /\Avcard\.LANG_VALUE\./

  def test_each_key_of_a_translation_is_a_key_in_english
    dirs = Dir[File.join(ROOT, '{config,converters/*/config}/locales')]
    assert_operator dirs.size, :>, 1
    dirs.each do |dir|
      english = keys(YAML.load_file(File.join(dir, 'en.yml')).values.first)
      Dir[File.join(dir, '*.yml')].each do |file|
        unknown = keys(YAML.load_file(file).values.first) - english
        unknown.reject! { |key| key.match?(LANGUAGE_NAMES) }
        assert_empty unknown, file.delete_prefix("#{ROOT}/")
      end
    end
  end

  private

  def keys(hash, path = [])
    hash.flat_map { |key, value| value.is_a?(Hash) ? keys(value, path + [key]) : [(path + [key]).join('.')] }
  end
end
