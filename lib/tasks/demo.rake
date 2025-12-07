namespace :demo do
  desc "Generate demo data for development testing (users, rooms, messages, boosts)"
  task seed: :environment do
    require "securerandom"

    puts "Creating demo data..."

    # Ensure we have an account
    account = Account.first_or_create!(name: "Demo Campfire")
    puts "  Account: #{account.name}"

    password = "password123"
    password_digest = BCrypt::Password.create(password)

    # Create administrators
    admins = [
      { name: "Alice Admin", email_address: "admin@example.com", bio: "Team Lead" },
      { name: "Bob Boss", email_address: "admin2@example.com", bio: "Engineering Manager" }
    ].map do |attrs|
      User.find_or_create_by!(email_address: attrs[:email_address]) do |u|
        u.name = attrs[:name]
        u.password_digest = password_digest
        u.role = :administrator
        u.bio = attrs[:bio]
      end
    end
    puts "  Created #{admins.size} administrators"

    # Create regular members
    members = [
      { name: "Charlie Developer", email_address: "member@example.com", bio: "Full-stack developer" },
      { name: "Diana Designer", email_address: "member2@example.com", bio: "UI/UX Designer" },
      { name: "Eve Engineer", email_address: "member3@example.com", bio: "Backend Engineer" },
      { name: "Frank Frontend", email_address: "member4@example.com", bio: "Frontend Developer" },
      { name: "Grace Guru", email_address: "member5@example.com", bio: "DevOps" },
      { name: "Henry Helper", email_address: "member6@example.com", bio: "Support Engineer" },
      { name: "Iris Intern", email_address: "member7@example.com", bio: "Engineering Intern" },
      { name: "Jack Junior", email_address: "member8@example.com", bio: "Junior Developer" }
    ].map do |attrs|
      User.find_or_create_by!(email_address: attrs[:email_address]) do |u|
        u.name = attrs[:name]
        u.password_digest = password_digest
        u.role = :member
        u.bio = attrs[:bio]
      end
    end
    puts "  Created #{members.size} members"

    all_users = admins + members

    # Create a bot user
    bot = User.find_or_create_by!(name: "Demo Bot") do |u|
      u.role = :bot
      u.bot_token = User.generate_bot_token
    end
    puts "  Created bot: #{bot.name}"

    # Create Open Rooms (everyone has access)
    open_rooms = [
      { name: "General", creator: admins.first },
      { name: "Random", creator: admins.first },
      { name: "Announcements", creator: admins.last }
    ].map do |attrs|
      Rooms::Open.find_or_create_by!(name: attrs[:name]) do |r|
        r.creator = attrs[:creator]
      end
    end
    puts "  Created #{open_rooms.size} open rooms"

    # Create Closed Rooms (invite-only)
    closed_rooms = []

    # Engineering room - all devs
    engineering_members = all_users.select { |u| u.bio&.match?(/engineer|developer|devops/i) }
    engineering_room = Rooms::Closed.find_or_create_by!(name: "Engineering") do |r|
      r.creator = admins.first
    end
    engineering_room.memberships.grant_to(engineering_members)
    closed_rooms << engineering_room

    # Design room - designers only
    design_members = all_users.select { |u| u.bio&.match?(/design/i) } + [admins.first]
    design_room = Rooms::Closed.find_or_create_by!(name: "Design") do |r|
      r.creator = admins.first
    end
    design_room.memberships.grant_to(design_members)
    closed_rooms << design_room

    # Leadership room - admins only
    leadership_room = Rooms::Closed.find_or_create_by!(name: "Leadership") do |r|
      r.creator = admins.first
    end
    leadership_room.memberships.grant_to(admins)
    closed_rooms << leadership_room

    # Project Alpha - mixed team
    project_members = all_users.sample(5) | admins
    project_room = Rooms::Closed.find_or_create_by!(name: "Project Alpha") do |r|
      r.creator = admins.first
    end
    project_room.memberships.grant_to(project_members)
    closed_rooms << project_room

    puts "  Created #{closed_rooms.size} closed rooms"

    # Create Direct Rooms between some users
    direct_rooms = []
    user_pairs = [
      [admins[0], admins[1]],
      [admins[0], members[0]],
      [members[0], members[1]],
      [members[2], members[3]]
    ]

    user_pairs.each do |pair|
      # Set Current.user for creator default
      Current.user = pair.first
      room = Rooms::Direct.find_or_create_for(pair)
      direct_rooms << room
    end
    Current.user = nil
    puts "  Created #{direct_rooms.size} direct rooms"

    # Sample messages for different contexts
    general_messages = [
      "Good morning everyone!",
      "Hope everyone has a great day!",
      "Anyone up for coffee?",
      "Happy Friday!",
      "Remember, standup at 10am",
      "Just pushed the latest changes",
      "Can someone review my PR?",
      "The build is green!",
      "Thanks for the help earlier",
      "Lunch anyone?"
    ]

    engineering_messages = [
      "Just fixed that tricky bug in the authentication flow",
      "The new API endpoint is ready for testing",
      "Anyone else seeing slow queries on the dashboard?",
      "I'm refactoring the user service today",
      "The tests are passing now",
      "Can we discuss the database schema?",
      "Deployed v2.1 to staging",
      "Code review appreciated on PR #42",
      "Found a memory leak in the worker process",
      "The CI pipeline is much faster now!"
    ]

    design_messages = [
      "Here are the new mockups for the dashboard",
      "I updated the color palette",
      "What do you think about this layout?",
      "The new icons are ready",
      "Accessibility audit complete",
      "User testing results look promising",
      "Working on the mobile responsive design",
      "The design system is documented",
      "New component library is ready",
      "Feedback on the onboarding flow?"
    ]

    casual_messages = [
      "Hey! How's it going?",
      "Did you see the game last night?",
      "What are you working on?",
      "That meeting was interesting",
      "Let me know when you're free",
      "Thanks for your help!",
      "Got a minute to chat?",
      "Sounds good to me",
      "I'll take a look",
      "Perfect, thanks!"
    ]

    # Emoji reactions for boosts
    reactions = ["👍", "❤️", "🎉", "🚀", "💯", "👏", "🔥", "✨", "😄", "🙌"]

    # Add messages to open rooms
    puts "  Adding messages to rooms..."

    open_rooms.each do |room|
      room_users = room.users.to_a
      next if room_users.empty?

      15.times do |i|
        msg = room.messages.create!(
          creator: room_users.sample,
          body: general_messages.sample,
          client_message_id: SecureRandom.uuid,
          created_at: rand(7.days).seconds.ago
        )

        # Add some boosts
        if rand < 0.3
          rand(1..3).times do
            Boost.create(
              message: msg,
              booster: room_users.sample,
              content: reactions.sample
            )
          end
        end
      end
    end

    # Add messages to engineering room
    engineering_room.users.to_a.tap do |room_users|
      next if room_users.empty?

      20.times do
        msg = engineering_room.messages.create!(
          creator: room_users.sample,
          body: engineering_messages.sample,
          client_message_id: SecureRandom.uuid,
          created_at: rand(7.days).seconds.ago
        )

        if rand < 0.4
          rand(1..4).times do
            Boost.create(
              message: msg,
              booster: room_users.sample,
              content: reactions.sample
            )
          end
        end
      end
    end

    # Add messages to design room
    design_room.users.to_a.tap do |room_users|
      next if room_users.empty?

      12.times do
        msg = design_room.messages.create!(
          creator: room_users.sample,
          body: design_messages.sample,
          client_message_id: SecureRandom.uuid,
          created_at: rand(7.days).seconds.ago
        )

        if rand < 0.3
          rand(1..2).times do
            Boost.create(
              message: msg,
              booster: room_users.sample,
              content: reactions.sample
            )
          end
        end
      end
    end

    # Add messages to direct rooms
    direct_rooms.each do |room|
      room_users = room.users.to_a
      next if room_users.size < 2

      8.times do
        room.messages.create!(
          creator: room_users.sample,
          body: casual_messages.sample,
          client_message_id: SecureRandom.uuid,
          created_at: rand(3.days).seconds.ago
        )
      end
    end

    # Add a message with mentions
    if open_rooms.first && all_users.size >= 2
      mentioned_user = members.first
      open_rooms.first.messages.create!(
        creator: admins.first,
        body: "<div>Hey <mention data-user-id=\"#{mentioned_user.id}\">@#{mentioned_user.name}</mention>, can you take a look at this?</div>",
        client_message_id: SecureRandom.uuid,
        created_at: 1.hour.ago
      )
    end

    puts ""
    puts "Demo data created successfully!"
    puts ""
    puts "Summary:"
    puts "  - #{User.administrator.count} administrators"
    puts "  - #{User.member.count} members"
    puts "  - #{User.bot.count} bots"
    puts "  - #{Rooms::Open.count} open rooms"
    puts "  - #{Rooms::Closed.count} closed rooms"
    puts "  - #{Rooms::Direct.count} direct rooms"
    puts "  - #{Message.count} messages"
    puts "  - #{Boost.count} boosts"
    puts ""
    puts "Login with any demo user:"
    puts "  Email: admin@example.com (admin) or member@example.com (member)"
    puts "  Password: #{password}"
  end

  desc "Clear all demo data (WARNING: destructive)"
  task clear: :environment do
    puts "Clearing all data..."

    Boost.delete_all
    Message.delete_all
    Membership.delete_all
    Room.delete_all
    Session.delete_all
    User.delete_all

    puts "All data cleared."
  end

  desc "Reset and regenerate demo data"
  task reset: [:clear, :seed]
end
