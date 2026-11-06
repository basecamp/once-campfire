# A message's previews are made when it's posted, within limits, and the room links only to those (Message::Attachment).
# A representation URL asked for directly makes a missing one on that request instead, so past the pixel limit it
# serves only one that was made before.
module ActiveStoragePreviewLimits
  private
    def set_representation
      if Message::Attachment.too_many_pixels_to_preview?(@blob)
        representation = @blob.representation(params[:variation_key])

        if made?(representation)
          @representation = representation.processed
        else
          head :not_found
        end
      else
        super
      end
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      head :not_found
    end

    # A video's preview is a frame and a variant of it, and the frame can be drawn without the variant.
    def made?(representation)
      if representation.is_a?(ActiveStorage::Preview)
        representation.processed? && representation.image.variant(representation.variation).processed?
      else
        representation.processed?
      end
    end
end
