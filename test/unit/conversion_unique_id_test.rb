# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# unique_id, for the authors of converters: the attachment's id, or for a
# repository entry its file in its revision
class ConversionUniqueIdTest < ActiveSupport::TestCase
  def test_unique_id_of_a_repository_entry_names_its_file_and_revision
    entry = lambda do
      Redmine::Scm::Adapters::Entry.new(
        :name => 'a.md', :path => 'doc/a.md', :kind => 'file', :size => 10,
        :lastrev => Redmine::Scm::Adapters::Revision.new(:identifier => 'abc123')
      )
    end
    repository = stub(:project => nil)
    repository.stubs(:preview_entry).with('doc/a.md', 'abc123').returns(entry.call).then.returns(entry.call)
    object = {:type => :repository, :object => repository, :path => 'doc/a.md', :rev => 'abc123'}

    assert_equal 'a-md-doc-a-md-file-10-abc123', worker(object).unique_id
    # the same file looked up again has the same id
    assert_equal 'a-md-doc-a-md-file-10-abc123', worker(object).unique_id
  end

  def test_unique_id_of_a_missing_repository_entry_is_nil
    repository = stub(:project => nil, :preview_entry => nil)
    assert_nil worker({:type => :repository, :object => repository, :path => 'gone.md', :rev => nil}).unique_id
  end

  private

  def worker(object)
    RedmineMorePreviews::Converter.find(:pass).worker(
      preview_format: 'txt', object: object, target: File.join(Dir.tmpdir, 'rmp-unique-id', 'preview.txt', 'index.txt')
    )
  end
end
