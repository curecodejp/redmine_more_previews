# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Cliff's hooks should be registered once, even though older plugin releases
# shipped a second set of Ruby hook classes in lib/hooks/.
class CliffHooksTest < ActiveSupport::TestCase
  HOOKS = {
    preview_attachment_top: {
      klass: 'CliffLib::Hooks::CliffEmlTopHook',
      partial: 'redmine_more_previews/hooks/cliff_preview_attachment_top'
    },
    preview_repository_entry_top: {
      klass: 'CliffLib::Hooks::CliffEmlTopHook',
      partial: 'redmine_more_previews/hooks/cliff_preview_repository_entry_top'
    },
    preview_attachment_contextual: {
      klass: 'CliffLib::Hooks::CliffEmlContextualHook',
      partial: 'redmine_more_previews/hooks/cliff_preview_attachment_contextual'
    },
    preview_repository_entry_contextual: {
      klass: 'CliffLib::Hooks::CliffEmlContextualHook',
      partial: 'redmine_more_previews/hooks/cliff_preview_repository_entry_contextual'
    }
  }.freeze

  class RenderRecorder
    attr_reader :options

    def render(options)
      @options = options
      'rendered'
    end
  end

  def test_each_cliff_view_hook_has_exactly_one_namespaced_listener
    HOOKS.each do |hook, expected|
      cliff_listeners = listeners_for_cliff(hook)
      assert_equal [expected.fetch(:klass)], cliff_listeners.map { |listener| listener.class.name },
                   "unexpected or duplicate Cliff listeners for #{hook}"
    end
  end

  def test_each_cliff_view_hook_renders_the_expected_partial_with_context
    HOOKS.each do |hook, expected|
      listener = listeners_for_cliff(hook).first
      assert listener, "missing Cliff listener for #{hook}"

      caller = RenderRecorder.new
      context = {hook_caller: caller, project: nil, attachment: nil, repository: nil}
      assert_equal ['rendered'], listener.public_send(hook, context)
      assert_equal expected.fetch(:partial), caller.options.fetch(:partial)
      assert_same context, caller.options.fetch(:locals)
    end
  end

  def test_cliff_conversion_templates_resolve_to_app_views
    views = RedmineMorePreviews::Converter.find(:cliff).path.views
    expected = File.expand_path('../../converters/cliff/app/views', __dir__)
    assert_equal expected, views
    %w(pre.html.erb headers.html.erb fields.html.erb attachments.html.erb).each do |name|
      assert File.file?(File.join(views, 'cliff', name)), name
    end
  end

  # Keep only one canonical version of each template. Cliff#eml, #save_headers,
  # #save_fields and #list resolve them through Converter#views (app/views),
  # not through the former lib/cliff copies.
  def test_cliff_erb_templates_exist_only_in_app_views
    root = File.expand_path('../../converters/cliff', __dir__)
    %w(pre.html.erb headers.html.erb fields.html.erb attachments.html.erb).each do |name|
      assert File.file?(File.join(root, 'app/views/cliff', name))
      refute File.file?(File.join(root, 'lib/cliff', name)),
             "obsolete library copy of #{name} must not shadow the canonical view"
    end
  end

  private

  def listeners_for_cliff(hook)
    Redmine::Hook.hook_listeners(hook).select do |listener|
      %w[CliffEmlTopHook CliffEmlContextualHook].include?(listener.class.name.to_s.split('::').last)
    end
  end
end
