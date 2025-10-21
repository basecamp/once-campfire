class ContentFilters::MarkdownFilter < ActionText::Content::Filter
  def applicable?
    contains_markdown?(content.to_plain_text)
  end

  def apply
    # Process the entire content as markdown
    plain_text = content.to_plain_text
    html = markdown_to_html(plain_text)
    
    # Replace the entire fragment content with the HTML
    fragment.update do |source|
      source.inner_html = html
    end
  end

  private

  def contains_markdown?(text)
    # Check for common markdown patterns
    text.match?(/\*\*.*\*\*|__.*__|\*.*\*|_.*_|`.*`|#{Regexp.escape("```")}.*#{Regexp.escape("```")}|^#{Regexp.escape("#")}|^#{Regexp.escape("-")}|^#{Regexp.escape("*")}|^#{Regexp.escape("1.")}|\[.*\]\(.*\)/)
  end

  def markdown_to_html(text)
    renderer = Redcarpet::Render::HTML.new(
      filter_html: false,
      no_images: false,
      no_links: false,
      no_styles: false,
      safe_links_only: false,
      with_toc_data: false,
      hard_wrap: true,
      link_attributes: { target: "_blank" }
    )
    
    markdown = Redcarpet::Markdown.new(renderer, {
      autolink: true,
      disable_indented_code_blocks: false,
      fenced_code_blocks: true,
      footnotes: false,
      highlight: false,
      no_intra_emphasis: false,
      space_after_headers: false,
      strikethrough: true,
      superscript: false,
      tables: true,
      underline: true
    })
    
    markdown.render(text)
  end
end
