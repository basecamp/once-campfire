json.cache! user do
  json.(user, :id, :name, :role)

  json.avatar_url fresh_user_avatar_url(user)
end
