require "test_helper"

class VideoTranscoderTest < ActiveSupport::TestCase
  test "passes through non-video attachments unchanged" do
    upload = fake_upload(content_type: "image/jpeg")

    FFMPEG::Movie.expects(:new).never

    assert_same upload, VideoTranscoder.call(upload)
  end

  test "passes through mp4 uploads already encoded with h264/aac" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "aac")
    movie.expects(:transcode).never

    assert_same upload, VideoTranscoder.call(upload)
  end

  test "passes through silent mp4 uploads already encoded with h264" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: nil)
    movie.expects(:transcode).never

    assert_same upload, VideoTranscoder.call(upload)
  end

  test "passes through MP4 uploads with the avc1 brand" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "aac", format_tags: { major_brand: "avc1" })
    movie.expects(:transcode).never

    assert_same upload, VideoTranscoder.call(upload)
  end

  test "passes through MP4 uploads with the M4V brand" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "aac", format_tags: { major_brand: "M4V " })
    movie.expects(:transcode).never

    assert_same upload, VideoTranscoder.call(upload)
  end

  test "transcodes mp4 uploads with an incompatible video codec" do
    upload = fake_upload(content_type: "video/mp4", original_filename: "clip.mp4")

    movie = stub_movie(video_codec: "hevc", audio_codec: "aac")
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    with_transcoded_result(upload) do |result|
      assert_equal "clip.mp4", result[:filename]
      assert_equal "video/mp4", result[:content_type]
      assert_equal "transcoded mp4 data", result[:io].read
    end
  end

  test "transcodes mp4 uploads with an incompatible audio codec" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "opus")
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    with_transcoded_result(upload) do |result|
      assert_equal "video/mp4", result[:content_type]
    end
  end

  test "transcodes mp4 uploads with an incompatible container" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "aac", format_tags: { major_brand: "webm" })
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    with_transcoded_result(upload) do |result|
      assert_equal "video/mp4", result[:content_type]
    end
  end

  test "transcodes MP4-declared MOV uploads" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "aac", format_tags: { major_brand: "qt  " })
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    with_transcoded_result(upload) do |result|
      assert_equal "video/mp4", result[:content_type]
    end
  end

  test "transcodes mp4 uploads with an incompatible pixel format" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "aac", colorspace: "yuv444p")
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    with_transcoded_result(upload) do |result|
      assert_equal "video/mp4", result[:content_type]
    end
  end

  test "transcodes mp4 uploads that cannot be probed" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(valid: false)
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    with_transcoded_result(upload) do |result|
      assert_equal "video/mp4", result[:content_type]
    end
  end

  test "raises TranscodeError when the upload cannot be probed at all" do
    upload = fake_upload(content_type: "video/mp4")

    FFMPEG::Movie.stubs(:new).raises(FFMPEG::Error, "probe exploded")

    error = assert_raises(VideoTranscoder::TranscodeError) { VideoTranscoder.call(upload) }
    assert_equal "probe exploded", error.message
  ensure
    FFMPEG::Movie.unstub(:new)
  end

  test "raises TranscodeError when ffprobe output cannot be parsed" do
    upload = fake_upload(content_type: "video/mp4")

    FFMPEG::Movie.stubs(:new).raises(RuntimeError, "Could not parse output from FFProbe")

    error = assert_raises(VideoTranscoder::TranscodeError) { VideoTranscoder.call(upload) }
    assert_equal "Could not parse output from FFProbe", error.message
  ensure
    FFMPEG::Movie.unstub(:new)
  end

  test "skips transcoding videos larger than the maximum input size" do
    upload = fake_upload(content_type: "video/mp4", size: VideoTranscoder::MAX_INPUT_SIZE + 1)

    FFMPEG::Movie.expects(:new).never

    assert_same upload, VideoTranscoder.call(upload)
  end

  test "rejects transcoding videos longer than the maximum duration" do
    upload = fake_upload(content_type: "video/quicktime")

    movie = stub_movie(duration: VideoTranscoder::MAX_DURATION + 1)
    movie.expects(:transcode).never

    error = assert_raises(VideoTranscoder::TranscodeError) { VideoTranscoder.call(upload) }
    assert_equal "Video exceeds maximum duration of #{VideoTranscoder::MAX_DURATION} seconds", error.message
  end

  test "transcodes video uploads to an h264 mp4 and preserves the original filename" do
    upload = fake_upload(content_type: "video/quicktime", original_filename: "clip.mov")

    movie = stub_movie
    movie.expects(:transcode).with do |output_path, options|
      assert_equal({
        video_codec: "libx264",
        audio_codec: "aac",
        x264_preset: "medium",
        custom: [ "-movflags", "+faststart", "-crf", 23, "-pix_fmt", "yuv420p" ]
      }, options)
      File.binwrite(output_path, "transcoded mp4 data")
      true
    end

    with_transcoded_result(upload) do |result|
      assert_instance_of Tempfile, result[:io]
      assert_equal "clip.mp4", result[:filename]
      assert_equal "video/mp4", result[:content_type]
      assert_equal "transcoded mp4 data", result[:io].read
    end
  end

  test "falls back to a generic filename when the upload has none" do
    upload = fake_upload(content_type: "video/quicktime", original_filename: nil)

    movie = stub_movie
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    with_transcoded_result(upload) do |result|
      assert_equal "video.mp4", result[:filename]
    end
  end

  test "applies a hard timeout to transcoding" do
    upload = fake_upload(content_type: "video/quicktime")

    movie = stub_movie
    stub_transcode_success(movie, output_data: "transcoded mp4 data")
    Timeout.expects(:timeout).with(VideoTranscoder::MAX_TRANSCODE_TIME).yields

    with_transcoded_result(upload) do |result|
      assert_equal "transcoded mp4 data", result[:io].read
    end
  end

  test "raises TranscodeError and leaves no temp files behind when transcoding fails" do
    upload = fake_upload(content_type: "video/quicktime")

    movie = stub_movie
    stub_transcode_failure(movie, message: "ffmpeg exploded")

    output = Tempfile.new([ "transcoded_", ".mp4" ])
    output_path = output.path
    Tempfile.expects(:new).with([ "transcoded_", ".mp4" ]).returns(output)

    error = assert_raises(VideoTranscoder::TranscodeError) { VideoTranscoder.call(upload) }
    assert_equal "ffmpeg exploded", error.message
    assert_not File.exist?(output_path)
  ensure
    output&.close!
  end


  private
    def with_transcoded_result(upload)
      result = VideoTranscoder.call(upload)
      yield result
    ensure
      VideoTranscoder.cleanup(result)
    end

    def fake_upload(content_type:, data: "video data", original_filename: "clip.mov", size: data.bytesize)
      StringIO.new(data).tap do |io|
        io.define_singleton_method(:content_type) { content_type }
        io.define_singleton_method(:original_filename) { original_filename }
        io.define_singleton_method(:path) { File.join(Dir.tmpdir, "fake_upload_#{SecureRandom.hex}") }
        io.define_singleton_method(:size) { size }
      end
    end

    def stub_movie(video_codec: nil, audio_codec: nil, duration: 0, format_tags: { major_brand: "isom" }, colorspace: "yuv420p", valid: true)
      movie = mock("movie")
      movie.stubs(valid?: valid)
      movie.stubs(duration: duration)
      movie.stubs(format_tags: format_tags)
      movie.stubs(video_codec: video_codec)
      movie.stubs(colorspace: colorspace)
      movie.stubs(audio_codec: audio_codec)
      FFMPEG::Movie.stubs(:new).returns(movie)
      movie
    end

    def stub_transcode_success(movie, output_data:)
      movie.stubs(:transcode).with do |output_path, _options|
        File.binwrite(output_path, output_data)
        true
      end
    end

    def stub_transcode_failure(movie, message:)
      movie.stubs(:transcode).raises(RuntimeError, message)
    end
end
