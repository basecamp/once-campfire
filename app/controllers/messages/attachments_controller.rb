class Messages::AttachmentsController < ApplicationController
  include ActiveStorage::Streaming, RoomScoped

  RANGE_CHUNK_SIZE = 1.megabyte
  FullStreamClosed = Class.new(StandardError)
  private_constant :FullStreamClosed

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  before_action :set_private_cache

  def show
    message = @room.messages.find(params[:message_id])
    attachment = message.attachment
    return not_found unless attachment.attached?

    representation = representation_for(message, attachment)
    if params[:representation].in?([ nil, "original" ]) && request.headers["Range"].present?
      send_blob_range_stream(representation, request.headers["Range"], disposition:)
    else
      send_blob_full_stream(representation, disposition:)
    end
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::InvariableError, ActiveStorage::UnpreviewableError
    raise if response.committed?

    not_found
  end

  private
    def representation_for(message, attachment)
      case params[:representation]
      when nil, "original"
        attachment.blob
      when "thumb"
        message.processed_attachment_representation(:thumb)
      when "video_preview"
        message.processed_attachment_preview(
          format: :webp,
          resize_to_limit: [ Message::THUMBNAIL_MAX_WIDTH, Message::THUMBNAIL_MAX_HEIGHT ]
        ).processed
      else
        raise ActionController::BadRequest, "unknown attachment representation"
      end
    end

    def disposition
      params[:disposition] == "attachment" ? :attachment : :inline
    end

    def send_blob_range_stream(blob, range_header, disposition:)
      ranges = Rack::Utils.get_byte_ranges(range_header, blob.byte_size)
      return range_not_satisfiable(blob.byte_size) unless ranges&.one? && ranges.first

      range = ranges.first
      first_chunk_end = [ range.begin + RANGE_CHUNK_SIZE - 1, range.end ].min
      first_chunk = download_exact_chunk(blob, range.begin..first_chunk_end)

      response.status = :partial_content
      response.headers["Accept-Ranges"] = "bytes"
      response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{blob.byte_size}"
      response.headers["Content-Length"] = range.size.to_s

      send_stream(
        filename: blob.filename.sanitized,
        disposition: blob.forced_disposition_for_serving || disposition,
        type: blob.content_type_for_serving
      ) do |stream|
        stream.write first_chunk
        offset = first_chunk_end + 1
        while offset <= range.end
          chunk_end = [ offset + RANGE_CHUNK_SIZE - 1, range.end ].min
          stream.write download_exact_chunk(blob, offset..chunk_end)
          offset = chunk_end + 1
        end
      end
    end

    def send_blob_full_stream(blob, disposition:)
      download = Fiber.new(blocking: true) do
        blob.download { |chunk| Fiber.yield chunk }
        nil
      end
      chunk = download.resume

      send_stream(
        filename: blob.filename.sanitized,
        disposition: blob.forced_disposition_for_serving || disposition,
        type: blob.content_type_for_serving
      ) do |stream|
        while chunk
          stream.write chunk
          chunk = download.resume
        end
      end
    ensure
      begin
        download.raise FullStreamClosed if download&.alive?
      rescue FullStreamClosed
      end
    end

    def download_exact_chunk(blob, range)
      blob.download_chunk(range).tap do |chunk|
        raise ActiveStorage::FileNotFoundError unless chunk&.bytesize == range.size
      end
    end

    def range_not_satisfiable(size)
      response.headers["Accept-Ranges"] = "bytes"
      response.headers["Content-Range"] = "bytes */#{size}"
      head :range_not_satisfiable
    end

    def set_private_cache
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["Vary"] = response.headers["Vary"].to_s.split(",").map(&:strip).push("Cookie").uniq.join(", ")
    end

    def not_found
      set_private_cache
      response.delete_header("Accept-Ranges")
      response.delete_header("Content-Range")
      response.delete_header("Content-Length")
      head :not_found
    end
end
