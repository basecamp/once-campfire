class BanCleanupBlobEntry < ApplicationRecord
  belongs_to :ban_cleanup_intent

  validates :blob_id, :key, :service_name, presence: true
end
