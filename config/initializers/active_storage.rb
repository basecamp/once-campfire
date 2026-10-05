ActiveSupport.on_load(:active_storage_blob) do
  ActiveStorage::DiskController.content_security_policy false, only: :show

  ActiveStorage::DiskController.after_action only: :show do
    response.set_header("Cache-Control", "max-age=3600, public")
  end
end
