# Rails waits for ffmpeg however long it takes, and a video's preview is drawn inside the request that posts it.
# This previewer gives ffmpeg a wall-clock limit, kills it past that, and reports a failed preview, so the message
# is posted without one.
class TimeLimitedVideoPreviewer < ActiveStorage::Previewer::VideoPreviewer
  TIME_LIMIT = 10 # seconds

  private
    def capture(*argv, to:)
      to.binmode

      open_tempfile do |err|
        IO.popen(argv, in: IO::NULL, err: err) do |out|
          Timeout.timeout(TIME_LIMIT) { IO.copy_stream(out, to) }
        rescue Timeout::Error
          Process.kill :KILL, out.pid
          raise ActiveStorage::PreviewError, "#{argv.first} took longer than #{TIME_LIMIT} seconds"
        end
        err.rewind

        unless $?.success?
          raise ActiveStorage::PreviewError, "#{argv.first} failed (status #{$?.exitstatus}): #{err.read.to_s.chomp}"
        end
      end

      to.rewind
    end
end
