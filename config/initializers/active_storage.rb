ActiveSupport.on_load(:active_storage_blob) do
  ActiveStorage::DiskController.after_action only: :show do
    response.set_header("Cache-Control", "private, no-store")
  end
end

message_attachment_analysis_guard = Module.new do
  private
    def analyze_blob_later
      super unless record_type == "Message" && name == "attachment"
    end
end

ActiveSupport.on_load(:active_storage_attachment) do
  prepend message_attachment_analysis_guard
end
