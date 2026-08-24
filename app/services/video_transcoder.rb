require "streamio-ffmpeg"

class VideoTranscoder
  # Videos larger than this are attached as-is to avoid tying up request workers with long transcodes.
  MAX_INPUT_SIZE = 200.megabytes

  # Raised when a video upload fails to transcode.
  class TranscodeError < StandardError; end

  def self.call(io)
    new(io).call
  end

  def initialize(io)
    @io = io
  end

  def call
    return io unless video?
    return io if compatible_encoding?

    if too_large?
      Rails.logger.info "Skipping video transcoding: input exceeds #{MAX_INPUT_SIZE} bytes"
      io
    else
      transcoded_io
    end
  end

  private
    attr_reader :io

    def video?
      io.content_type&.starts_with?("video/")
    end

    # Only mp4 uploads can be attached as-is, and only when their encoding is
    # already browser-compatible: h264 video and aac (or no) audio.
    def compatible_encoding?
      return false unless io.content_type == "video/mp4"

      movie = FFMPEG::Movie.new(io.path)
      movie.valid? &&
        movie.video_codec == "h264" &&
        (movie.audio_codec.nil? || movie.audio_codec == "aac")
    rescue FFMPEG::Error, Errno::ENOENT
      false # unprovable input falls through to transcoding, which fails cleanly
    end

    def too_large?
      io.size > MAX_INPUT_SIZE
    end

    def transcoded_io
      output_path = File.join(Dir.tmpdir, "transcoded_#{SecureRandom.hex}.mp4")

      movie = FFMPEG::Movie.new(io.path)

      options = {
        video_codec: "libx264",
        audio_codec: "aac",
        movflags: "+faststart",
        preset: "medium",
        crf: 23
      }

      movie.transcode(output_path, options) do |progress|
        Rails.logger.info "Transcoding progress: #{(progress * 100).round}%"
      end

      {
        io: StringIO.new(File.binread(output_path)),
        filename: "#{original_basename}.mp4",
        content_type: "video/mp4"
      }
    rescue => error
      Rails.logger.error "Video transcoding failed: #{error.message}"
      raise TranscodeError, error.message
    ensure
      File.delete(output_path) if output_path && File.exist?(output_path)
    end

    def original_basename
      basename = File.basename(io.original_filename.to_s, ".*").presence
      basename || "video"
    end
end
