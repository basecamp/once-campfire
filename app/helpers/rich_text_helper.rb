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
end
