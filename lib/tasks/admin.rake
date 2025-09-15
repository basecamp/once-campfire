namespace :admin do
  desc "Delete a user completely or censor their messages"
  task :delete_user, [ :identifier, :censor ] => :environment do |t, args|
    identifier = args[:identifier]
    censor_messages = args[:censor] == "true" || args[:censor] == "censor"

    if identifier.blank?
      puts "Usage: rake admin:delete_user[<email|name|id>,<censor|delete>]"
      puts "  censor: Replace all user messages with '[Message content removed by administrator]'"
      puts "  delete: Permanently delete all user messages"
      exit 1
    end

    user = find_user(identifier)
    unless user
      exit 1
    end

    puts "Found user: #{user.name} (#{user.email_address})"
    puts "Role: #{user.role}"
    puts "Active: #{user.active?}"
    puts "Messages: #{user.messages.count}"

    if censor_messages
      puts "\nCensoring #{user.messages.count} messages..."
      user.admin_delete!(censor_messages: true)
      puts "✓ User deactivated and messages censored"
    else
      puts "\nDeleting #{user.messages.count} messages..."
      user.admin_delete!(censor_messages: false)
      puts "✓ User deactivated and messages deleted"
    end

    puts "User has been removed from all rooms and deactivated."
  end

  desc "Disable/deactivate a user"
  task :disable_user, [ :identifier ] => :environment do |t, args|
    identifier = args[:identifier]

    if identifier.blank?
      puts "Usage: rake admin:disable_user[<email|name|id>]"
      exit 1
    end

    user = find_user(identifier)
    unless user
      exit 1
    end

    puts "Found user: #{user.name} (#{user.email_address})"
    puts "Current status: #{user.active? ? 'Active' : 'Inactive'}"

    if user.active?
      puts "User is already deactivated."
      return
    end

    puts "Deactivating user..."
    user.deactivate
    puts "✓ User deactivated successfully"
    puts "User has been removed from all rooms and sessions cleared."
  end

  desc "Reset a user's password"
  task :reset_password, [ :identifier, :password ] => :environment do |t, args|
    identifier = args[:identifier]
    password = args[:password]

    if identifier.blank? || password.blank?
      puts "Usage: rake admin:reset_password[<email|name|id>,<new_password>]"
      exit 1
    end

    user = find_user(identifier)
    unless user
      exit 1
    end

    puts "Found user: #{user.name} (#{user.email_address})"
    puts "Resetting password..."

    user.update!(password: password)
    puts "✓ Password reset successfully"

    # Clear all sessions to force re-login
    user.sessions.delete_all
    puts "✓ All user sessions cleared"
  end

  desc "Lock out a user (disable + clear all sessions)"
  task :lock_user, [ :identifier ] => :environment do |t, args|
    identifier = args[:identifier]

    if identifier.blank?
      puts "Usage: rake admin:lock_user[<email|name|id>]"
      exit 1
    end

    user = find_user(identifier)
    unless user
      exit 1
    end

    puts "Found user: #{user.name} (#{user.email_address})"
    puts "Current status: #{user.active? ? 'Active' : 'Inactive'}"

    if user.deactivated?
      puts "User is already deactivated."
      exit 0
    end

    puts "Locking out user..."
    user.lock_out!
    puts "✓ User locked out successfully"
    puts "User has been deactivated and all sessions cleared."
  end

  desc "Unlock/reactivate a user"
  task :unlock_user, [ :identifier ] => :environment do |t, args|
    identifier = args[:identifier]

    if identifier.blank?
      puts "Usage: rake admin:unlock_user[<email|name|id>]"
      exit 1
    end

    user = find_user(identifier)
    unless user
      exit 1
    end

    puts "Found user: #{user.name} (#{user.email_address})"
    puts "Current status: #{user.active? ? 'Active' : 'Inactive'}"

    if user.active?
      puts "User is already active."
      exit 0
    end

    puts "Unlocking user..."
    user.unlock!
    puts "✓ User unlocked successfully"
    puts "User has been reactivated and can log in again."
  end

  desc "List all users with basic information"
  task list_users: :environment do
    puts "All Users:"
    puts "=" * 80
    printf "%-4s %-20s %-30s %-12s %-8s %-10s\n", "ID", "Name", "Email", "Role", "Active", "Messages"
    puts "-" * 80

    User.order(:id).each do |user|
      printf "%-4d %-20s %-30s %-12s %-8s %-10d\n",
        user.id,
        user.name.truncate(20),
        (user.email_address || "").truncate(30),
        user.role,
        user.active? ? "Yes" : "No",
        user.messages.count
    end

    puts "\nTotal users: #{User.count}"
    puts "Active users: #{User.active.count}"
    puts "Inactive users: #{User.where(active: false).count}"
  end

  desc "Show detailed information about a user"
  task :show_user, [ :identifier ] => :environment do |t, args|
    identifier = args[:identifier]

    if identifier.blank?
      puts "Usage: rake admin:show_user[<email|name|id>]"
      exit 1
    end

    user = find_user(identifier)
    unless user
      exit 1
    end

    puts "User Details:"
    puts "=" * 50
    puts "ID: #{user.id}"
    puts "Name: #{user.name}"
    puts "Email: #{user.email_address || 'Not set'}"
    puts "Role: #{user.role}"
    puts "Active: #{user.active? ? 'Yes' : 'No'}"
    puts "Bio: #{user.bio || 'Not set'}"
    puts "Created: #{user.created_at}"
    puts "Updated: #{user.updated_at}"
    puts ""
    puts "Statistics:"
    puts "  Messages: #{user.messages.count}"
    puts "  Rooms: #{user.rooms.count}"
    puts "  Boosts: #{user.boosts.count}"
    puts "  Sessions: #{user.sessions.count}"
    puts "  Push Subscriptions: #{user.push_subscriptions.count}"
    puts "  Searches: #{user.searches.count}"

    if user.bot?
      puts "  Bot Token: #{user.bot_token}"
      puts "  Webhook URL: #{user.webhook_url || 'Not set'}"
    end
  end

  desc "Censor all messages from a user"
  task :censor_messages, [ :identifier ] => :environment do |t, args|
    identifier = args[:identifier]

    if identifier.blank?
      puts "Usage: rake admin:censor_messages[<email|name|id>]"
      exit 1
    end

    user = find_user(identifier)
    unless user
      exit 1
    end

    message_count = user.messages.count
    puts "Found user: #{user.name} (#{user.email_address})"
    puts "Messages to censor: #{message_count}"

    if message_count == 0
      puts "User has no messages to censor."
      return
    end

    puts "Censoring #{message_count} messages..."
    user.censor_messages!
    puts "✓ All messages have been censored"
  end

  private

  def find_user(identifier)
    # Try to find by ID first (if it's numeric)
    if identifier.match?(/^\d+$/)
      user = User.find_by(id: identifier)
      if user
        return user
      else
        puts "No user found with ID: #{identifier}"
        return nil
      end
    end

    # Try to find by email address (including deactivated users)
    if identifier.include?("@")
      # First try exact match
      user = User.find_by(email_address: identifier)
      if user
        return user
      end

      # If not found, try to find by original email (for deactivated users)
      # Look for users with deactivated email pattern
      deactivated_users = User.where("email_address LIKE ?", "%-deactivated-%")
      deactivated_users.each do |u|
        original_email = u.email_address.gsub(/-deactivated-[^@]+@/, "@")
        if original_email == identifier
          return u
        end
      end

      puts "No user found with email: #{identifier}"
      return nil
    end

    # Try to find by name (case insensitive, partial match)
    users = User.where("LOWER(name) LIKE LOWER(?)", "%#{identifier}%")

    if users.empty?
      puts "No user found with name containing: #{identifier}"
      nil
    elsif users.count == 1
      users.first
    else
      puts "Multiple users found with name containing '#{identifier}':"
      users.each do |user|
        puts "  #{user.id}: #{user.name} (#{user.email_address})"
      end
      puts "Please be more specific or use the user ID."
      nil
    end
  end
end
