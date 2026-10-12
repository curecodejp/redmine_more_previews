# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'shellwords'

class LibreCommandTest < ActiveSupport::TestCase
  def setup
    @worker = Libre.allocate
    @worker.tmpdir = '/tmp/rmp libre'
  end

  def test_allowed_output_formats_remain_supported
    %w(html txt pdf png jpg).each do |format|
      @worker.preview_format = format
      command = @worker.soffice('/tmp/input.docx', '/tmp/lo profile')
      assert_equal format, Shellwords.split(command)[Shellwords.split(command).index('--convert-to') + 1]
    end
  end

  def test_unknown_and_shell_metacharacter_formats_are_rejected
    ['inline', 'xml', '', 'pdf;touch /tmp/unwanted', 'pdf$(id)', 'pdf\nwhoami'].each do |format|
      @worker.preview_format = format
      assert_raises(RedmineMorePreviews::Exceptions::ConverterBadArgument) do
        @worker.soffice('/tmp/input.docx', '/tmp/profile')
      end
    end
  end
end
