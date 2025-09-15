# Admin Rake Tasks

This document describes the administrative rake tasks available for managing users in the Campfire chat system.

## Available Tasks

### User Management

#### `rake admin:delete_user[identifier,censor]`
Completely removes a user from the system with options for message handling.

**Parameters:**
- `identifier`: User's email, name, or ID
- `censor`: Either `censor` or `delete` (default: `delete`)

**Options:**
- `censor`: Replaces all user messages with "[Message content removed by administrator]"
- `delete`: Permanently deletes all user messages

**Examples:**
```bash
# Delete user and all their messages
rake 'admin:delete_user[user@example.com,delete]'

# Delete user but censor their messages
rake 'admin:delete_user[john.doe,censor]'

# Delete user by ID
rake 'admin:delete_user[123,delete]'
```

#### `rake admin:disable_user[identifier]`
Deactivates a user without deleting their data.

**Parameters:**
- `identifier`: User's email, name, or ID

**What it does:**
- Sets `active` to `false`
- Removes user from all rooms (except direct rooms)
- Clears push subscriptions and searches
- Clears all sessions
- Modifies email address to prevent re-registration

**Examples:**
```bash
rake 'admin:disable_user[user@example.com]'
rake 'admin:disable_user[john.doe]'
rake 'admin:disable_user[123]'
```

#### `rake admin:reset_password[identifier,password]`
Resets a user's password and clears all sessions.

**Parameters:**
- `identifier`: User's email, name, or ID
- `password`: New password

**Examples:**
```bash
rake 'admin:reset_password[user@example.com,newpassword123]'
rake 'admin:reset_password[john.doe,securepass]'
```

#### `rake admin:lock_user[identifier]`
Locks out a user by deactivating them and clearing all sessions.

**Parameters:**
- `identifier`: User's email, name, or ID

**What it does:**
- Deactivates the user
- Clears all active sessions
- Disconnects from ActionCable

**Examples:**
```bash
rake 'admin:lock_user[user@example.com]'
rake 'admin:lock_user[john.doe]'
```

#### `rake admin:unlock_user[identifier]`
Unlocks/reactivates a previously locked user.

**Parameters:**
- `identifier`: User's email, name, or ID

**What it does:**
- Reactivates the user (sets `active` to `true`)
- Restores original email address if it was modified during deactivation
- User can log in again

**Examples:**
```bash
rake 'admin:unlock_user[user@example.com]'
rake 'admin:unlock_user[john.doe]'
```

### Information Tasks

#### `rake admin:list_users`
Lists all users with basic information.

**Output includes:**
- User ID, name, email, role, active status, message count

#### `rake admin:show_user[identifier]`
Shows detailed information about a specific user.

**Parameters:**
- `identifier`: User's email, name, or ID

**Information displayed:**
- Basic user details (ID, name, email, role, etc.)
- Statistics (messages, rooms, boosts, sessions, etc.)
- Bot-specific information (if applicable)

#### `rake admin:censor_messages[identifier]`
Censors all messages from a user without deactivating them.

**Parameters:**
- `identifier`: User's email, name, or ID

**What it does:**
- Replaces all message content with "[Message content removed by administrator]"
- Preserves message timestamps and other metadata

## User Identification

Tasks accept users by:
- **Email address**: `user@example.com`
- **Name**: `John Doe` (partial matches supported)
- **ID**: `123` (numeric only)

When multiple users match a name search, the task will list all matches and ask for clarification.

## Safety Features

- All destructive operations are wrapped in database transactions
- User confirmation is required for destructive operations
- Detailed output shows what will be affected before proceeding
- Sessions are cleared to force re-authentication after password resets

## Examples

### Complete User Removal
```bash
# Remove user and delete all messages
rake 'admin:delete_user[spam@example.com,delete]'

# Remove user but keep censored message history
rake 'admin:delete_user[spam@example.com,censor]'
```

### Temporary Suspension
```bash
# Disable user temporarily
rake 'admin:disable_user[problematic@example.com]'

# Lock out user immediately
rake 'admin:lock_user[problematic@example.com]'

# Unlock user later
rake 'admin:unlock_user[problematic@example.com]'
```

### Password Issues
```bash
# Reset password for locked out user
rake 'admin:reset_password[user@example.com,newpassword123]'
```

### Investigation
```bash
# List all users
rake admin:list_users

# Get detailed user info
rake 'admin:show_user[user@example.com]'

# Censor messages without deactivating user
rake 'admin:censor_messages[user@example.com]'
```

## User Management Concepts

### Disable vs Lock User

Understanding when to use `disable_user` vs `lock_user` is important for proper user management:

#### **Disable User** (`rake admin:disable_user`)
**Comprehensive cleanup** - Removes user from all rooms (except direct rooms)
- **Clears all data** - Removes push subscriptions, searches, and sessions
- **Disconnects from chat** - Closes ActionCable connections
- **Prevents re-registration** - Modifies email address to prevent account reuse
- **Sets inactive status** - Marks user as `active: false`

**Use case:** Permanent or long-term user removal from the system

#### **Lock User** (`rake admin:lock_user`)
**Immediate access removal** - Disconnects from ActionCable and clears sessions
- **Sets inactive status** - Marks user as `active: false`
- **Prevents re-registration** - Modifies email address to prevent account reuse
- **Preserves room memberships** - User stays in rooms but can't access them
- **Preserves data** - Keeps push subscriptions, searches, and other data

**Use case:** Temporary suspension or immediate access restriction

#### **Key Differences Summary:**

| Aspect | Disable User | Lock User |
|--------|-------------|-----------|
| **Room Memberships** | ❌ Removed (except direct) | ✅ Preserved |
| **Push Subscriptions** | ❌ Deleted | ✅ Preserved |
| **Search History** | ❌ Deleted | ✅ Preserved |
| **Sessions** | ❌ Deleted | ❌ Deleted |
| **ActionCable** | ❌ Disconnected | ❌ Disconnected |
| **Email Address** | ❌ Modified | ❌ Modified |
| **Active Status** | ❌ False | ❌ False |
| **Reversibility** | ✅ Yes (unlock) | ✅ Yes (unlock) |

#### **When to Use Each:**

**Use Disable User when:**
- User is leaving the organization permanently
- You want to completely remove their presence from the system
- GDPR compliance requires data deletion
- User has violated policies and needs complete removal

**Use Lock User when:**
- Temporary suspension (investigation, vacation, etc.)
- Immediate access restriction needed
- You want to preserve their data for potential restoration
- Quick response to suspicious activity

**Both Support Unlock:**
Both disabled and locked users can be restored using `rake admin:unlock_user`, which:
- Reactivates the user (`active: true`)
- Restores original email address
- Allows user to log in again

The main difference is that **disabled users** lose their room memberships and data, while **locked users** retain their memberships and data but just can't access the system.

## Notes

- All tasks require the Rails environment to be loaded
- Tasks will exit with error codes if user is not found
- Direct room memberships are preserved during user deletion/deactivation
- Bot users can be managed with the same tasks
- All operations are logged and provide detailed feedback
