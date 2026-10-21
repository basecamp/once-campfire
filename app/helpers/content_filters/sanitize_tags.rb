class ContentFilters::SanitizeTags < ActionText::Content::Filter
  ALLOWED_TAGS = %w[ a abbr acronym address b big blockquote br cite code dd del dfn div dl dt em h1 h2 h3 h4 h5 h6 hr i ins kbd li ol
    p pre samp small span strong sub sup time tt ul var ] + ContentFilters::EDITOR_FORMATTING_TAGS +
    [ ActionText::Attachment.tag_name, "figure", "figcaption" ]
  ALLOWED_TAG_NAMES = ALLOWED_TAGS.to_set

  def applicable?
    true
  end

  # Removes every element whose tag isn't allowed, along with its content.
  # Checking names in a set is much cheaper than matching a selector of
  # fifty :not() clauses against each element.
  def apply
    fragment.update do |source|
      source.css("*").each do |node|
        node.remove unless ALLOWED_TAG_NAMES.include?(node.name)
      end
    end
  end
end
