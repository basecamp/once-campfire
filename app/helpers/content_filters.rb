module ContentFilters
  TextMessagePresentationFilters = ActionText::Content::Filters.new(UrlTitleFilter, RemoveSoloUnfurledLinkText, StyleUnfurledTwitterAvatars, SanitizeTags)
end
