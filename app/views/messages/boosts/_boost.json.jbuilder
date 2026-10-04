# The booster is rendered inside this cache, so its own fragment can never bust it. Key on both.
json.cache! [ boost, boost.booster ] do
  json.(boost, :id, :content)

  json.created_at boost.created_at.utc

  json.booster boost.booster, partial: "users/user", as: :user

  json.message do
    json.id boost.message_id
    json.url room_message_url(boost.message.room, boost.message)
  end
end
