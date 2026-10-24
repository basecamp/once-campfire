class AddPresentationVersionToMessages < ActiveRecord::Migration[8.2]
  def up
    add_column :messages, :presentation_version, :integer, default: 0

    Message::PresentationVersion.backfill!(connection)
    Message::PresentationVersion.install!(connection)
  end

  def down
    Message::PresentationVersion.uninstall!(connection)
    remove_column :messages, :presentation_version
  end
end
