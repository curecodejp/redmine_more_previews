# frozen_string_literal: true

module RedmineMorePreviews
  module Patches
    module SettingsControllerPatch
      # Redmine saves plugin settings as-is. Reject unsupported Libre formats on
      # POST, so an invalid setting cannot disable previews until corrected.
      def plugin
        if request.post? && params[:id] == 'redmine_more_previews'
          formats = params.dig(:settings, :converter, :libre, :mime_types)
          if formats.present? && !valid_libre_formats?(formats)
            flash[:error] = l(:error_more_previews_invalid_libre_format)
            return redirect_to(plugin_settings_path(params[:id]))
          end
          unreadable = unreadable_maggie_formats(params.dig(:settings, :converter, :maggie))
          if unreadable.any?
            flash[:error] = l(:error_more_previews_unreadable_image_format, :formats => unreadable.join(', '))
            return redirect_to(plugin_settings_path(params[:id]))
          end
        end
        super
      end

      private

      # Maggie's HEIC/HEIF and TIFF previews need a coder ImageMagick may lack:
      # enabling them there is refused. The form sends the format checkboxes of
      # a converter that is off, so only an enabled Maggie is checked.
      def unreadable_maggie_formats(maggie)
        return [] unless settings_hash?(maggie) && maggie[:active].to_s == '1' && defined?(::Maggie)

        formats = maggie[:mime_types]
        return [] unless settings_hash?(formats)

        enabled = formats.each_pair.select {|_ext, config| settings_hash?(config) && config[:active].to_s == '1'}.map(&:first)
        ::Maggie.unreadable_formats(enabled)
      end

      # a String answers [] too: malformed parameters are not checked here
      def settings_hash?(value)
        value.is_a?(ActionController::Parameters) || value.is_a?(Hash)
      end

      def valid_libre_formats?(formats)
        return false unless formats.respond_to?(:each_pair)

        supported = RedmineMorePreviews::Converter.find(:libre).mime_types
        formats.each_pair.all? do |extension, config|
          entry = supported[extension.to_s.to_sym]
          next false unless entry && config.respond_to?(:key?) && config.respond_to?(:[])

          !config.key?('format') || Array(entry[:formats]).map(&:to_s).include?(config['format'])
        end
      end
    end
  end
end

unless SettingsController.ancestors.include?(RedmineMorePreviews::Patches::SettingsControllerPatch)
  SettingsController.prepend(RedmineMorePreviews::Patches::SettingsControllerPatch)
end
