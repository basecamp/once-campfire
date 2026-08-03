require "set"

class BanCleanupIntent < ApplicationRecord
  include ReliableWork

  JOB_CLASS = RemoveBannedContentJob
  MESSAGE_BATCH_SIZE = 25
  OWNED_BLOB_BATCH_SIZE = 100
  PURGE_BATCH_SIZE = 25
  BLOB_ENTRY_UNIQUE_INDEX = "index_ban_cleanup_blob_entries_on_intent_and_blob"

  LeaseLost = Class.new(StandardError)
  private_constant :LeaseLost

  belongs_to :user
  has_many :blob_entries, class_name: "BanCleanupBlobEntry", dependent: :delete_all

  validates :generation, numericality: { only_integer: true, greater_than: 0 }

  scope :pending, -> { where(completed_at: nil, canceled_at: nil, failed_at: nil) }
  scope :dead_lettered, -> { where.not(failed_at: nil) }

  def perform!(lease_token)
    return false unless claim_for_processing!(lease_token)

    return true unless start_purge!(lease_token)

    snapshot_messages! lease_token
    snapshot_owned_blobs! lease_token
    purge_blobs! lease_token
    renew_lease! lease_token
    complete! lease_token
  rescue LeaseLost
    false
  rescue StandardError => error
    mark_retry_scheduled(error) if release_for_retry!(lease_token, error)
    raise
  end

  private
    def dead_letter_after_max_attempts?
      false
    end

    def start_purge!(lease_token)
      User.transaction do
        locked_user = User.lock.find(user_id)
        locked_intent = self.class.lock.find(id)
        ensure_current_lease! locked_intent, lease_token

        if locked_intent.purge_started_at?
          true
        elsif !locked_user.banned? || locked_user.ban_cleanup_generation != locked_intent.generation
          now = Time.current
          locked_intent.update!(
            canceled_at: now, lease_token: nil, enqueued_at: nil, started_at: nil,
            next_attempt_at: nil, updated_at: now
          )
          false
        else
          now = Time.current
          locked_intent.update!(
            purge_started_at: now,
            message_id_upper_bound: Message.where(creator_id: user_id).maximum(:id).to_i,
            blob_id_upper_bound: ActiveStorage::Blob.maximum(:id).to_i,
            started_at: now
          )
          true
        end
      end
    end

    def snapshot_messages!(lease_token)
      while snapshot_message_batch!(lease_token)
      end
    end

    def snapshot_message_batch!(lease_token)
      self.class.transaction do
        locked_intent = self.class.lock.find(id)
        ensure_current_lease! locked_intent, lease_token

        if locked_intent.messages_deleted_at?
          false
        else
          message_ids = Message.lock.where(
            creator_id: user_id, id: ..locked_intent.message_id_upper_bound
          ).order(:id).limit(MESSAGE_BATCH_SIZE).pluck(:id)
          now = Time.current
          if message_ids.empty?
            locked_intent.update!(messages_deleted_at: now, started_at: now)
            false
          else
            record_blob_entries!(blob_entries_for_messages(message_ids), now:)
            Message.where(id: message_ids).order(:id).each(&:destroy!)
            locked_intent.update!(started_at: Time.current)
            true
          end
        end
      end
    end

    def snapshot_owned_blobs!(lease_token)
      while snapshot_owned_blob_batch!(lease_token)
      end
    end

    def snapshot_owned_blob_batch!(lease_token)
      self.class.transaction do
        locked_intent = self.class.lock.find(id)
        ensure_current_lease! locked_intent, lease_token

        if locked_intent.snapshot_completed_at?
          false
        else
          candidate_ids = ActiveStorage::Blob.where(
            id: (locked_intent.owned_blob_id_cursor + 1)..locked_intent.blob_id_upper_bound
          ).order(:id).limit(OWNED_BLOB_BATCH_SIZE).ids
          now = Time.current
          if candidate_ids.empty?
            locked_intent.update!(
              owned_blob_id_cursor: locked_intent.blob_id_upper_bound,
              snapshot_completed_at: now, started_at: now
            )
            false
          else
            blob_ids = owned_blob_ids(candidate_ids)
            record_blob_entries!(blob_entries_for_blob_ids(blob_ids), now:)
            locked_intent.update!(owned_blob_id_cursor: candidate_ids.max, started_at: Time.current)
            true
          end
        end
      end
    end

    def owned_blob_ids(candidate_ids)
      source_owner = <<~SQL.squish
        (json_extract(active_storage_blobs.metadata, '$.#{StagedUpload::MARKER_KEY}') = 1
          AND json_extract(active_storage_blobs.metadata, '$.#{StagedUpload::OWNER_METADATA_KEY}') = ?
          AND NOT EXISTS (
            SELECT 1 FROM active_storage_attachments
            WHERE active_storage_attachments.blob_id = active_storage_blobs.id
          ))
      SQL
      derivative_owner = <<~SQL.squish
        json_extract(active_storage_blobs.metadata,
          '$.#{Message::Attachment::DERIVATIVE_USER_METADATA_KEY}') = ?
      SQL

      ActiveStorage::Blob.where(id: candidate_ids)
        .where("#{source_owner} OR #{derivative_owner}", user_id, user_id).ids
    end

    def blob_entries_for_messages(message_ids)
      rich_text_ids = ActionText::RichText.where(record_type: "Message", record_id: message_ids).ids
      blob_ids = ActiveStorage::Attachment.where(record_type: "Message", record_id: message_ids).pluck(:blob_id)
      blob_ids.concat ActiveStorage::Attachment.where(
        record_type: "ActionText::RichText", record_id: rich_text_ids
      ).pluck(:blob_id)
      blob_entries_for_blob_ids blob_ids
    end

    def blob_entries_for_blob_ids(blob_ids)
      entries = []
      seen = Set.new
      frontier = blob_ids.uniq.sort
      while frontier.any?
        blobs = ActiveStorage::Blob.where(id: frontier)
          .includes(:preview_image_blob, variant_records: :image_blob).index_by(&:id)
        next_frontier = []
        frontier.each do |blob_id|
          next if seen.include?(blob_id) || !(blob = blobs[blob_id])

          seen << blob_id
          entries << { blob_id: blob.id, key: blob.key, service_name: blob.service_name }
          next_frontier << blob.preview_image_blob&.id
          next_frontier.concat blob.variant_records.filter_map { _1.image_blob&.id }
        end
        frontier = next_frontier.compact.uniq.sort
      end
      entries
    end

    def record_blob_entries!(entries, now: Time.current)
      return if entries.empty?

      rows = entries.map do |entry|
        entry.merge(ban_cleanup_intent_id: id, created_at: now, updated_at: now)
      end
      BanCleanupBlobEntry.insert_all rows, unique_by: BLOB_ENTRY_UNIQUE_INDEX
    end

    def purge_blobs!(lease_token)
      loop do
        renew_lease! lease_token
        entry_ids = blob_entries.order(:id).limit(PURGE_BATCH_SIZE).ids
        break if entry_ids.empty?

        entry_ids.each { purge_blob_entry! _1, lease_token }
      end
    end

    def purge_blob_entry!(entry_id, lease_token)
      ActiveStorage::Blob.transaction do
        locked_intent = self.class.lock.find(id)
        ensure_current_lease! locked_intent, lease_token
        entry = BanCleanupBlobEntry.lock.find_by(id: entry_id, ban_cleanup_intent_id: id)
        next true unless entry

        blob = ActiveStorage::Blob.lock.find_by(id: entry.blob_id, key: entry.key)
        unless blob&.attachments&.exists?
          service = ActiveStorage::Blob.services.fetch(entry.service_name)
          service.delete entry.key
          service.delete_prefixed "variants/#{entry.key}/"
          raise "banned attachment bytes remain after deletion" if service.exist?(entry.key)

          blob&.destroy!
        end
        entry.destroy!
        locked_intent.update!(started_at: Time.current)
        true
      end
    end

    def renew_lease!(lease_token)
      now = Time.current
      renewed = self.class.pending.where(id:, lease_token:).update_all(started_at: now, updated_at: now)
      raise LeaseLost unless renewed == 1

      true
    end

    def ensure_current_lease!(intent, lease_token)
      unless intent.lease_token == lease_token && !intent.completed_at? && !intent.canceled_at? && !intent.failed_at?
        raise LeaseLost
      end
    end
end
