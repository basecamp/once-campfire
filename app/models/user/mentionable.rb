module User::Mentionable
  include ActionText::Attachable

  MENTION_CONTENT_TYPE = "application/vnd.campfire.mention"

  def attachable_content_type
    MENTION_CONTENT_TYPE
  end

  def to_attachable_partial_path
    "users/mention"
  end

  # How a mention appears inside the editor, matching the prompt's editor template.
  def to_editor_content_attachment_partial_path
    "users/mention"
  end

  def attachable_plain_text_representation(caption)
    "@#{name}"
  end
end
