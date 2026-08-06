# The rich text editor produces formatting that Rails' default Action Text
# sanitizer strips on render. The additions are declared once in
# ContentFilters, shared by every sanitization layer.
Rails.application.config.to_prepare do
  defaults = Class.new.include(ActionText::ContentHelper).new

  ActionText::ContentHelper.allowed_tags =
    (ActionText::ContentHelper.allowed_tags || defaults.sanitizer_allowed_tags) | ContentFilters::EDITOR_FORMATTING_TAGS
  ActionText::ContentHelper.allowed_attributes =
    (ActionText::ContentHelper.allowed_attributes || defaults.sanitizer_allowed_attributes) | ContentFilters::EDITOR_FORMATTING_ATTRIBUTES
end
