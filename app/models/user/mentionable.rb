module User::Mentionable
  include ActionText::Attachable

  def to_attachable_partial_path
    "users/mention"
  end

  def attachable_plain_text_representation(caption)
    "@#{name}"
  end
end
