module ContentFilters
  TextMessagePresentationFilters = ActionText::Content::Filters.new(MarkdownFilter, RemoveSoloUnfurledLinkText, StyleUnfurledTwitterAvatars, SanitizeTags)
end
