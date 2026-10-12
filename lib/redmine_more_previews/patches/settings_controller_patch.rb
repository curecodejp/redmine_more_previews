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
            flash[:error] = 'Invalid LibreOffice conversion format; settings were not saved.'
            return redirect_to(plugin_settings_path(params[:id]))
          end
        end
        super
      end

      private

      def valid_libre_formats?(formats)
        return false unless formats.respond_to?(:each_pair)

        supported = RedmineMorePreviews::Converter.find(:libre).mime_types
        formats.all? do |extension, config|
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
