module Message::Attachment
  extend ActiveSupport::Concern

  THUMBNAIL_MAX_WIDTH = 1200
  THUMBNAIL_MAX_HEIGHT = 800
  DERIVATIVE_USER_METADATA_KEY = "campfire_derivative_user_id"
  DERIVATIVE_SOURCE_METADATA_KEY = "campfire_derivative_source_blob_id"

  included do
    has_one_attached :attachment do |attachable|
      attachable.variant :thumb, resize_to_limit: [ THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT ]
    end
  end

  module ClassMethods
    def create_with_attachment!(attributes)
      attributes = attributes.to_h.symbolize_keys
      client_message_id = attributes[:client_message_id]
      creator = attributes[:creator] || Current.user || new.creator
      ContentLimits.verify! client_message_id.to_s.bytesize,
        maximum: ContentLimits::CLIENT_MESSAGE_ID_BYTES, description: "client message ID"
      ContentLimits.verify! attributes[:body].to_s.bytesize,
        maximum: ContentLimits::MESSAGE_BODY_BYTES, description: "message body"
      StagedUpload.verify_size! attributes[:attachment] if attributes[:attachment].present?
      if client_message_id.present? && existing = find_by(client_message_id:)
        StagedUpload.discard attributes[:attachment]
        return resolve_client_message_retry(existing, creator)
      end

      attachment = attributes.delete(:attachment)
      message = User::MutationFence.with(creator.id) do
        User.lock_active! creator
        staged_blob = StagedUpload.stage(attachment, owner_id: creator.id)

        begin
          transaction(requires_new: true) do
            create! attributes.merge(attachment: staged_blob)
          end
        rescue ActiveRecord::RecordNotUnique
          StagedUpload.discard staged_blob
          raise unless client_message_id.present?

          return resolve_client_message_retry(find_by!(client_message_id:), creator)
        rescue StandardError
          StagedUpload.discard staged_blob
          raise
        end
      end

      message.tap(&:process_attachment)
    end

    private
      def resolve_client_message_retry(existing, creator)
        unless existing.creator_id == creator.id
          raise Message::ClientMessageIdConflict, "client message ID is already used in this room"
        end

        existing.tap(&:perform_reliable_effects)
      end
  end

  def attachment?
    attachment.attached?
  end

  def process_attachment
    with_attachment_processing_lock do |current_attachment|
      ensure_attachment_analyzed current_attachment
      process_attachment_thumbnail current_attachment
    end
  rescue StandardError => error
    Rails.logger.error "Attachment derivative processing failed message_id=#{id} error=#{error.class.name}"
  end

  def processed_attachment_representation(name)
    with_attachment_processing_lock do |current_attachment|
      process_representation current_attachment.representation(name), source_blob_id: current_attachment.blob_id
    end || raise(ActiveStorage::FileNotFoundError)
  end

  def processed_attachment_preview(**transformations)
    with_attachment_processing_lock do |current_attachment|
      process_representation current_attachment.preview(**transformations), source_blob_id: current_attachment.blob_id
    end || raise(ActiveStorage::FileNotFoundError)
  end

  private
    def with_attachment_processing_lock
      User::MutationFence.with(creator_id) do
        current_attachment = attachment_for_processing
        yield current_attachment, nil if current_attachment
      end
    end

    def attachment_for_processing
      User.transaction do
        locked_creator = User.lock.find_by(id: creator_id)
        next unless locked_creator&.active?

        current_message = self.class.lock.find_by(id:)
        current_message.attachment if current_message&.attachment&.attached?
      end
    end

    def ensure_attachment_analyzed(current_attachment)
      current_attachment.analyze
    end

    def process_attachment_thumbnail(current_attachment)
      source_blob_id = current_attachment.blob_id
      case
      when current_attachment.video?
        process_representation current_attachment.preview(format: :webp), source_blob_id:
      when current_attachment.representable?
        process_representation current_attachment.representation(:thumb), source_blob_id:
      end
    end

    def process_representation(representation, source_blob_id:)
      case representation
      when ActiveStorage::VariantWithRecord
        process_tracked_variant representation, source_blob_id:
      when ActiveStorage::Preview
        process_preview representation, source_blob_id:
      else
        representation.processed
      end
    end

    def process_tracked_variant(variant, source_blob_id:)
      return variant if variant.image.present?

      staged_blob = nil
      variant.blob.open do |input|
        variant.variation.transform(input) do |output|
          staged_blob = stage_derivative(
            { io: output, filename: variant.filename, content_type: variant.content_type },
            service_name: variant.blob.service_name, source_blob_id:
          )
        end
      end

      variant if publish_variant(variant, staged_blob, source_blob_id:)
    ensure
      StagedUpload.discard staged_blob if staged_blob
    end

    def process_preview(preview, source_blob_id:)
      unless preview.image.attached?
        staged_blob = nil
        previewer = ActiveStorage.previewers.find { _1.accept? preview.blob }.new(preview.blob)
        previewer.preview(service_name: preview.blob.service_name) do |attachable|
          staged_blob = stage_derivative(
            attachable, service_name: preview.blob.service_name, source_blob_id:
          )
        end
        return unless publish_preview(preview.blob, staged_blob, source_blob_id:)
      end

      if preview.variation.transformations.present?
        image_blob = preview.blob.reload.preview_image.blob
        return unless process_representation image_blob.variant(preview.variation), source_blob_id:
      end
      preview
    ensure
      StagedUpload.discard staged_blob if staged_blob
    end

    def stage_derivative(attachable, service_name:, source_blob_id:)
      attributes = attachable.to_h.symbolize_keys.slice(:io, :filename, :content_type, :metadata, :identify)
      metadata = attributes.fetch(:metadata, {}).to_h.merge(
        DERIVATIVE_USER_METADATA_KEY => creator_id,
        DERIVATIVE_SOURCE_METADATA_KEY => source_blob_id
      )
      StagedUpload.stage attributes.merge(service_name:, identify: false, metadata:), owner_id: creator_id
    end

    def publish_variant(variant, staged_blob, source_blob_id:)
      self.class.transaction do
        next false unless processing_target_available?(source_blob_id)

        variant_blob = ActiveStorage::Blob.lock.find_by(id: variant.blob.id)
        next false unless variant_blob

        record = variant_blob.variant_records.create_or_find_by!(variation_digest: variant.variation.digest)
        StagedUpload.attach! record.image, staged_blob unless record.image.attached?
        true
      end
    end

    def publish_preview(blob, staged_blob, source_blob_id:)
      self.class.transaction do
        next false unless processing_target_available?(source_blob_id)

        current_blob = ActiveStorage::Blob.lock.find_by(id: blob.id)
        next false unless current_blob

        StagedUpload.attach! current_blob.preview_image, staged_blob unless current_blob.preview_image.attached?
        true
      end
    end

    def processing_target_available?(source_blob_id)
      creator = User.lock.find_by(id: creator_id)
      return false unless creator&.active?

      current_message = self.class.lock.find_by(id:)
      current_message&.attachment&.blob_id == source_blob_id
    end
end
