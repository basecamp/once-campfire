class StagedUpload
  MARKER_KEY = "campfire_staged_upload"
  OWNER_METADATA_KEY = "campfire_staged_upload_user_id"
  GRACE_PERIOD = 24.hours
  SWEEP_BATCH_SIZE = 100

  class LimitedIO
    def initialize(io, maximum)
      @io = io
      @maximum = maximum
      @bytes_read = 0
    end

    def read(*arguments)
      @io.read(*arguments).tap do |chunk|
        if chunk
          @bytes_read += chunk.bytesize
          ContentLimits.verify! @bytes_read, maximum: @maximum, description: "attachment"
        end
      end
    end

    def rewind
      @bytes_read = 0
      @io.rewind
    end

    def binmode
      @io.binmode unless @io.is_a?(StringIO)
      self
    end

    def method_missing(name, ...)
      @io.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @io.respond_to?(name, include_private) || super
    end
  end

  class << self
    def with(attachable, maximum: ContentLimits::ATTACHMENT_BYTES)
      blob = stage(attachable, maximum:)
      yield blob
    rescue StandardError
      discard blob
      raise
    end

    def stage(attachable, maximum: ContentLimits::ATTACHMENT_BYTES, owner_id: nil)
      return if attachable.blank?

      if attachable.is_a?(ActiveStorage::Blob)
        verify_size! attachable, maximum:
        attachable.open { }
        return attachable
      end

      upload = upload_attributes(attachable)
      io = LimitedIO.new(upload.fetch(:io), maximum)
      if io.respond_to?(:size) && (size = io.size)
        verify_size! size, maximum:
      end
      metadata = upload.fetch(:metadata, {}).to_h.merge(MARKER_KEY => true)
      metadata.delete OWNER_METADATA_KEY
      metadata[OWNER_METADATA_KEY] = Integer(owner_id) if owner_id
      blob = ActiveStorage::Blob.build_after_unfurling(**upload.merge(io:, metadata:))
      ContentLimits.verify! blob.byte_size, maximum:, description: "attachment"
      blob.save!
      blob.upload_without_unfurling(io)
      blob.open { }
      blob
    rescue StandardError
      discard blob
      raise
    end

    def verify_size!(attachable_or_size, maximum: ContentLimits::ATTACHMENT_BYTES)
      size = if attachable_or_size.is_a?(ActiveStorage::Blob)
        attachable_or_size.byte_size
      elsif attachable_or_size.respond_to?(:tempfile)
        attachable_or_size.tempfile.size
      elsif attachable_or_size.respond_to?(:to_h)
        io = attachable_or_size.to_h.symbolize_keys.fetch(:io)
        io.size if io.respond_to?(:size)
      else
        attachable_or_size
      end
      ContentLimits.verify! size, maximum:, description: "attachment" if size
    end

    def discard(blob)
      return unless staged?(blob)

      purge_if_unattached! blob.id, before: Time.current
    end

    def attach!(attached, blob)
      attached.attach blob
      attachment = attached.attachment
      return attachment if attachment&.persisted? && attachment.blob_id == blob.id

      raise ActiveRecord::RecordInvalid, attached.record
    end

    def sweep_abandoned!(before: GRACE_PERIOD.ago, limit: SWEEP_BATCH_SIZE, fault_after_delete: nil)
      abandoned(before:).limit(limit).pluck(:id).each do |id|
        purge_if_unattached! id, before:, fault_after_delete:
      end
    end

    def purge_if_unattached!(id, before:, fault_after_delete: nil)
      ActiveStorage::Blob.transaction do
        blob = ActiveStorage::Blob.lock.find_by(id:)
        if !staged?(blob) || blob.created_at > before || ActiveStorage::Attachment.exists?(blob_id: blob.id)
          false
        else
          blob.service.delete blob.key
          blob.service.delete_prefixed "variants/#{blob.key}/"
          raise "staged upload bytes remain after deletion" if blob.service.exist?(blob.key)

          fault_after_delete&.call(blob)
          blob.destroy!
          true
        end
      end
    end

    private
      def abandoned(before:)
        ActiveStorage::Blob.where(created_at: ..before)
          .where("json_extract(metadata, '$.#{MARKER_KEY}') = 1")
          .where.not(id: ActiveStorage::Attachment.select(:blob_id))
          .order(:created_at, :id)
      end

      def staged?(blob)
        blob.is_a?(ActiveStorage::Blob) && blob.metadata.fetch(MARKER_KEY, false) == true
      end

      def upload_attributes(attachable)
        if attachable.respond_to?(:tempfile)
          {
            io: attachable.tempfile,
            filename: attachable.original_filename,
            content_type: attachable.content_type
          }
        elsif attachable.respond_to?(:to_h) && (attributes = attachable.to_h.symbolize_keys).key?(:io)
          attributes.slice(:io, :filename, :content_type, :metadata, :service_name, :identify)
        else
          raise ArgumentError, "unsupported attachment upload"
        end
      end
  end
end
