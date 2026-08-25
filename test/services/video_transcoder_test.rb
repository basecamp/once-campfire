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

  test "transcodes mp4 uploads with an incompatible video codec" do
    upload = fake_upload(content_type: "video/mp4", original_filename: "clip.mp4")

    movie = stub_movie(video_codec: "hevc", audio_codec: "aac")
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    result = VideoTranscoder.call(upload)

    assert_equal "clip.mp4", result[:filename]
    assert_equal "video/mp4", result[:content_type]
    assert_equal "transcoded mp4 data", result[:io].read
  end

  test "transcodes mp4 uploads with an incompatible audio codec" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "opus")
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    assert_equal "video/mp4", VideoTranscoder.call(upload)[:content_type]
  end

  test "transcodes mp4 uploads with an incompatible container" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "aac", container: "matroska,webm")
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    assert_equal "video/mp4", VideoTranscoder.call(upload)[:content_type]
  end

  test "transcodes mp4 uploads with an incompatible pixel format" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(video_codec: "h264", audio_codec: "aac", colorspace: "yuv444p")
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    assert_equal "video/mp4", VideoTranscoder.call(upload)[:content_type]
  end

  test "transcodes mp4 uploads that cannot be probed" do
    upload = fake_upload(content_type: "video/mp4")

    movie = stub_movie(valid: false)
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    assert_equal "video/mp4", VideoTranscoder.call(upload)[:content_type]
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
    upload = fake_upload(content_type: "video/quicktime", size: VideoTranscoder::MAX_INPUT_SIZE + 1)

    FFMPEG::Movie.expects(:new).never

    assert_same upload, VideoTranscoder.call(upload)
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

    result = VideoTranscoder.call(upload)

    assert_equal "clip.mp4", result[:filename]
    assert_equal "video/mp4", result[:content_type]
    assert_equal "transcoded mp4 data", result[:io].read
  end

  test "falls back to a generic filename when the upload has none" do
    upload = fake_upload(content_type: "video/quicktime", original_filename: nil)

    movie = stub_movie
    stub_transcode_success(movie, output_data: "transcoded mp4 data")

    assert_equal "video.mp4", VideoTranscoder.call(upload)[:filename]
  end

  test "raises TranscodeError and leaves no temp files behind when transcoding fails" do
    upload = fake_upload(content_type: "video/quicktime")

    movie = stub_movie
    stub_transcode_failure(movie, message: "ffmpeg exploded")

    temp_files_before = Dir.glob(temp_transcode_files).length

    error = assert_raises(VideoTranscoder::TranscodeError) { VideoTranscoder.call(upload) }
    assert_equal "ffmpeg exploded", error.message
    assert_equal temp_files_before, Dir.glob(temp_transcode_files).length
  end


  private
    def fake_upload(content_type:, data: "video data", original_filename: "clip.mov", size: data.bytesize)
      StringIO.new(data).tap do |io|
        io.define_singleton_method(:content_type) { content_type }
        io.define_singleton_method(:original_filename) { original_filename }
        io.define_singleton_method(:path) { File.join(Dir.tmpdir, "fake_upload_#{SecureRandom.hex}") }
        io.define_singleton_method(:size) { size }
      end
    end

    def stub_movie(video_codec: nil, audio_codec: nil, container: "mov,mp4,m4a,3gp,3g2,mj2", colorspace: "yuv420p", valid: true)
      movie = mock("movie")
      movie.stubs(valid?: valid)
      movie.stubs(container: container)
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

    def temp_transcode_files
      File.join(Dir.tmpdir, "transcoded_*")
    end
end
