class AddArchiveAndBacklitFieldsToRooms < ActiveRecord::Migration[8.2]
  def change
    add_column :rooms, :archived_at, :datetime
    add_column :rooms, :backlit_project_id, :string
    add_column :rooms, :backlit_kind, :string
    add_index :rooms, :archived_at
    add_index :rooms, [ :backlit_project_id, :backlit_kind ], unique: true, where: "backlit_project_id IS NOT NULL AND backlit_kind IS NOT NULL"
  end
end
