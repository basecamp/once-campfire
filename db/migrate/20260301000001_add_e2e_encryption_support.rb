class AddE2eEncryptionSupport < ActiveRecord::Migration[8.2]
  def change
    # Store user's identity public key (ECDH P-256, exported as JWK JSON)
    add_column :users, :identity_public_key, :text

    # Store encrypted message data alongside ActionText body
    add_column :messages, :encrypted, :boolean, default: false, null: false
    add_column :messages, :encrypted_body, :text
    add_column :messages, :encryption_nonce, :string
    add_column :messages, :sender_public_key, :string

    # Room-level encryption settings
    add_column :rooms, :encrypted, :boolean, default: false, null: false

    # Per-membership encrypted room key (room key encrypted with member's public key)
    add_column :memberships, :encrypted_room_key, :text
    add_column :memberships, :room_key_nonce, :string
  end
end
