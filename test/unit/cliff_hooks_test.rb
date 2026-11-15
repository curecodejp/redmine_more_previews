# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# Cliff's hooks should be registered once, even though older plugin releases
# shipped a second set of Ruby hook classes in lib/hooks/.
class CliffHooksTest < ActiveSupport::TestCase
  HOOKS = {
    preview_attachment_top:              'CliffLib::Hooks::CliffEmlTopHook',
    preview_repository_entry_top:        'CliffLib::Hooks::CliffEmlTopHook',
    preview_attachment_contextual:       'CliffLib::Hooks::CliffEmlContextualHook',
    preview_repository_entry_contextual: 'CliffLib::Hooks::CliffEmlContextualHook'
  }.freeze

  def test_each_cliff_view_hook_has_exactly_one_namespaced_listener
    HOOKS.each do |hook, expected|
      cliff_listeners = listeners_for_cliff(hook)
      assert_equal [expected], cliff_listeners.map { |listener| listener.class.name },
                   "unexpected or duplicate Cliff listeners for #{hook}"
    end
  end

  private

  def listeners_for_cliff(hook)
    Redmine::Hook.hook_listeners(hook).select do |listener|
      %w[CliffEmlTopHook CliffEmlContextualHook].include?(listener.class.name.to_s.split('::').last)
    end
  end
end
