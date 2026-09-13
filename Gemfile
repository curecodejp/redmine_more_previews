# Dependencies already provided by Redmine core should not be redeclared here.
# This avoids Bundler conflicts when Redmine changes dependency versions.

#
# Load converters' Gemfiles
#
Dir.glob File.expand_path("../converters/*/{Gemfile,PluginGemfile}", __FILE__) do |file|
  eval_gemfile file
end
