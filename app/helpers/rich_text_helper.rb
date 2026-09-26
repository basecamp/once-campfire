module RichTextHelper
  def rich_text_data_actions
    # submitByKeyboard runs in the capture phase so it can submit on Enter
    # before the editor turns the keystroke into a newline
    "lexxy:change->typing-notifications#start keydown->composer#submitByKeyboard:capture"
  end

  def mention_prompt_tag(room)
    tag.lexxy_prompt trigger: "@", name: "mention", src: autocompletable_users_path(room_id: room.id),
      "remote-filtering": true, "empty-results": "No matches"
  end

  # The editor keeps an attachment's content as it finds it, so every
  # attachment is rebuilt from its attachable before editing: a Trix-era
  # embed carries its details as node attributes the editor doesn't
  # round-trip, a mention edited under Trix carries the generic content type
  # the editor doesn't permit, and a hand-written embed carries whatever
  # markup the author put there.
  def editable_body(message)
    fragment = ActionText::Fragment.wrap(message.body.body_before_type_cast)

    transformed = fragment.replace(ActionText::Attachment.tag_name) do |node|
      attachment = ActionText::Attachment.from_node(node)

      node.tap do |n|
        n["content-type"] = attachment.attachable.attachable_content_type
        n["content"] = render_action_text_attachment(attachment)
      end
    end

    ActionText::RichText.new(body: transformed.to_html)
  end
end
