json.cache! message do
  json.(message, :id)

  json.created_at message.created_at.utc

  json.body do
    json.plain_text message.plain_text_body
    json.html message.body.to_s
  end

  json.selection_mode message.bot_action_selection_mode
  json.actions message.bot_actions

  json.creator message.creator, partial: "users/user", as: :user

  json.room do
    json.id message.room_id
  end

  json.url room_message_url(message.room, message)
end
