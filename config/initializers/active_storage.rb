ActiveSupport.on_load(:active_storage_blob) do
  ActiveStorage::DiskController.after_action only: :show do
    response.set_header("Cache-Control", "private, no-store")
  end
end
