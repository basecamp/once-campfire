require_relative "production"

Rails.application.configure do
  config.assume_ssl = false
  config.force_ssl  = false
  config.action_cable.disable_request_forgery_protection = true

  config.after_initialize do
    if defined?(Rails::Server) && User.none?
      Account.create!(name: "Campfire")

      password_digest = User.new(password: "password").password_digest
      users = (1..10000).map do |i|
        email_address = "user#{i}@example.com"
        {
          name: "User #{i}",
          role: i == 1 ? :administrator : :member,
          email_address:,
          normalized_email_address: User.normalize_email_address(email_address),
          password_digest: password_digest
        }
      end
      User.insert_all(users)

      sessions = User.all.map do |user|
        {
          user_id: user.id,
          user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
                      "(KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36",
          ip_address: "127.0.0.1",
          last_active_at: Time.now,
          token: "a" * 19 + user.id.to_s.rjust(5, "0")
        }
      end
      Session.insert_all(sessions)

      creator_id = User.first.id

      rooms = (0..200).map { |i| { name: "Room #{i}", creator_id: creator_id, type: "Rooms::Closed" } }
      Room.insert_all(rooms)

      Room.all.each_with_index do |room, index|
        user_ids = User.where("MOD(#{index}, id) = 0").ids
        memberships = user_ids.map { |user_id| { room_id: room.id, user_id: user_id } }
        Membership.insert_all(memberships)
      end
    end
  end
end
