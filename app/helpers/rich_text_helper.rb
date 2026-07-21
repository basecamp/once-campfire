module RichTextHelper
  LEGACY_EMBED_SELECTOR = "action-text-attachment[content-type='#{ActionText::Attachment::OpengraphEmbed::OPENGRAPH_EMBED_CONTENT_TYPE}'][href]"

  def rich_text_data_actions
    # submitByKeyboard runs in the capture phase so it can submit on Enter
    # before the editor turns the keystroke into a newline
    "lexxy:change->typing-notifications#start keydown->composer#submitByKeyboard:capture"
  end

  def mention_prompt_tag(room)
    tag.lexxy_prompt trigger: "@", name: "mention", src: autocompletable_users_path(room_id: room.id),
      "remote-filtering": true, "empty-results": "No matches"
  end

  # Trix-era opengraph embeds carry their details as node attributes, which
  # the editor doesn't round-trip. Rendering them into the content attribute
  # lets the editor preserve them like any embed it created itself.
  def editable_body(message)
    fragment = ActionText::Fragment.wrap(message.body.body_before_type_cast)

    transformed = fragment.replace(LEGACY_EMBED_SELECTOR) do |node|
      node.tap { |n| n["content"] = render_action_text_attachment(ActionText::Attachment.from_node(n)) }
    end

    ActionText::RichText.new(body: transformed.to_html)
  end
end
