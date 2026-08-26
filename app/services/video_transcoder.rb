require "streamio-ffmpeg"
require "tempfile"
require "timeout"

class VideoTranscoder
  # Videos larger than this are attached as-is to avoid tying up request workers with long transcodes.
  MAX_INPUT_SIZE = 200.megabytes
  MAX_DURATION = 1.hour
  MAX_TRANSCODE_TIME = 5.minutes
  MP4_MAJOR_BRANDS = %w[ isom iso2 iso3 iso4 iso5 iso6 iso8 iso9 mp41 mp42 mp71 avc1 avc2 avc3 avc4 m4v dash cmfc cmff ].freeze

  # Raised when a video upload fails to transcode.
  class TranscodeError < StandardError; end

  def self.call(io)
    new(io).call
  end

  def self.cleanup(attachment)
    io = attachment[:io] if attachment.is_a?(Hash)
    io.close! if io.respond_to?(:close!)
  end

  def initialize(io)
    @io = io
  end

  def call
    return io unless video?
    return io if too_large?

    movie = probe_movie
    return io if compatible_encoding?(movie)
    ensure_duration_supported!(movie)

    transcoded_io(movie)
  end

  private
    attr_reader :io

    def video?
      io.content_type&.starts_with?("video/")
    end

    # Only mp4 uploads can be attached as-is, and only when their encoding is
    # already browser-compatible: h264 video and aac (or no) audio.
    def probe_movie
      FFMPEG::Movie.new(io.path)
    rescue FFMPEG::Error, Errno::ENOENT, RuntimeError => error
      raise TranscodeError, error.message
    end

    def compatible_encoding?(movie)
      return false unless io.content_type == "video/mp4"

      movie.valid? &&
        MP4_MAJOR_BRANDS.include?(movie.format_tags&.[](:major_brand).to_s.strip.downcase) &&
        movie.video_codec == "h264" &&
        movie.colorspace == "yuv420p" &&
        (movie.audio_codec.nil? || movie.audio_codec == "aac")
    end

    def too_large?
      if io.size > MAX_INPUT_SIZE
        Rails.logger.info "Skipping video transcoding: input exceeds #{MAX_INPUT_SIZE} bytes"
        true
      end
    end

    def ensure_duration_supported!(movie)
      return unless movie.duration > MAX_DURATION

      Rails.logger.info "Rejecting video transcoding: duration exceeds #{MAX_DURATION} seconds"
      raise TranscodeError, "Video exceeds maximum duration of #{MAX_DURATION} seconds"
    end

    def transcoded_io(movie)
      output = Tempfile.new([ "transcoded_", ".mp4" ])
      output.binmode

      options = {
        video_codec: "libx264",
        audio_codec: "aac",
        x264_preset: "medium",
        custom: [ "-movflags", "+faststart", "-crf", 23, "-pix_fmt", "yuv420p" ]
      }

      Timeout.timeout(MAX_TRANSCODE_TIME) do
        movie.transcode(output.path, options) do |progress|
          Rails.logger.info "Transcoding progress: #{(progress * 100).round}%"
        end
      end
      output.rewind

      result = {
        io: output,
        filename: "#{original_basename}.mp4",
        content_type: "video/mp4"
      }
      output = nil
      result
    rescue => error
      Rails.logger.error "Video transcoding failed: #{error.message}"
      raise TranscodeError, error.message
    ensure
      output&.close!
    end

    def original_basename
      basename = File.basename(io.original_filename.to_s, ".*").presence
      basename || "video"
    end
end
