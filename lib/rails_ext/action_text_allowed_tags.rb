# The rich text editor produces formatting that Rails' default Action Text
# sanitizer strips on render. The additions are declared once in
# ContentFilters, shared by every sanitization layer.
#
# Applied as Action Text content loads, after the hooks that define the filters
# ContentFilters builds on, and again after each reload so changes reach it.
allow_editor_formatting = -> do
  defaults = Class.new.include(ActionText::ContentHelper).new

  ActionText::ContentHelper.allowed_tags =
    (ActionText::ContentHelper.allowed_tags || defaults.sanitizer_allowed_tags) | ContentFilters::EDITOR_FORMATTING_TAGS
  ActionText::ContentHelper.allowed_attributes =
    (ActionText::ContentHelper.allowed_attributes || defaults.sanitizer_allowed_attributes) | ContentFilters::EDITOR_FORMATTING_ATTRIBUTES
end

Rails.application.config.after_initialize do |app|
  ActiveSupport.on_load(:action_text_content) { allow_editor_formatting.call }
  app.reloader.to_prepare(&allow_editor_formatting)
end
