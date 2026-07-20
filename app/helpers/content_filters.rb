module ContentFilters
  # Formatting the rich text editor produces that Rails' sanitizers don't
  # allow by default. A message passes through three sanitization layers on
  # its way to the screen, and each builds on this list:
  #
  #   * SanitizeTags strips disallowed markup from the message body
  #   * Action Text sanitizes the rendered content (lib/rails_ext/action_text_allowed_tags.rb)
  #   * auto_link re-sanitizes the final html (MessagesHelper#message_presentation)
  EDITOR_FORMATTING_TAGS = %w[ s u mark ]
  EDITOR_FORMATTING_ATTRIBUTES = %w[ data-language ]

  TextMessagePresentationFilters = ActionText::Content::Filters.new(RemoveSoloUnfurledLinkText, StyleUnfurledTwitterAvatars, SanitizeTags)
end
