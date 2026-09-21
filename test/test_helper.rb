# frozen_string_literal: true

# Load the Redmine helper
require File.expand_path(File.dirname(__FILE__) + '/../../../test/test_helper')

module RedmineMorePreviews
  module TestHelper
    # Marks an archive entry that should be written as a symlink to +target+.
    Symlink = Struct.new(:target)

    def symlink_to(target = '/etc/hostname')
      Symlink.new(target)
    end

    # Builds a zip archive at +path+ from a hash of entry name => content
    # (a String, or symlink_to(target) for a symlink entry).
    def build_zip(path, entries)
      Zip::File.open(path, create: true) do |zip|
        entries.each do |name, content|
          if content.is_a?(Symlink)
            zip.add(name, symlink_source(content.target))
          elsif name.end_with?('/')
            zip.mkdir(name.chomp('/'))
          else
            zip.get_output_stream(name) { |io| io.write(content) }
          end
        end
      end
      path
    end

    # Builds a (non-compressed) tar archive at +path+.
    def build_tar(path, entries)
      File.open(path, 'wb') do |file|
        Gem::Package::TarWriter.new(file) do |tar|
          entries.each do |name, content|
            if content.is_a?(Symlink)
              tar.add_symlink(name, content.target, 0o644)
            else
              tar.add_file_simple(name, 0o644, content.bytesize) { |io| io.write(content) }
            end
          end
        end
      end
      path
    end

    # Builds a gzip compressed tar archive at +path+.
    def build_tgz(path, entries)
      tar = build_tar("#{path}.tar", entries)
      Zlib::GzipWriter.open(path) { |gz| gz.write(File.binread(tar)) }
      File.delete(tar)
      path
    end

    def zippy_worker(options = {})
      RedmineMorePreviews::Converter.find(:zippy).worker(
        { preview_format: 'html', object: {} }.merge(options)
      )
    end

    private

    def symlink_source(target)
      dir = Dir.mktmpdir('rmp-symlink')
      link = File.join(dir, 'link')
      File.symlink(target, link)
      link
    end
  end
end
