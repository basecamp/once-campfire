class AddPresentationVersionToMessages < ActiveRecord::Migration[8.2]
  def up
    add_column :messages, :presentation_version, :integer, default: 0
    create_table :message_presentation_sequences do |t|
      t.integer :value, null: false, default: 0
    end

    Message::PresentationVersion.backfill!(connection)
    Message::PresentationVersion.install!(connection)
  end

  def down
    Message::PresentationVersion.uninstall!(connection)
    drop_table :message_presentation_sequences
    remove_column :messages, :presentation_version
  end
end
