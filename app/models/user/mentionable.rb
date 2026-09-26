module User::Mentionable
  include ActionText::Attachable

  MENTION_CONTENT_TYPE = "application/vnd.campfire.mention"

  def attachable_content_type
    MENTION_CONTENT_TYPE
  end

  def to_attachable_partial_path
    "users/mention"
  end

  def attachable_plain_text_representation(caption)
    "@#{name}"
  end
end
