require "test_helper"
require "vips"
require "tempfile"

# libvips selects a loader from a file's actual bytes, not from its declared content type. These
# tests pin which loader is selected for each file type under the app's configured loader policy
# (config/initializers/vips.rb).
class VipsLoaderPolicyTest < ActiveSupport::TestCase
  # Header bytes are enough for libvips to identify a format; native types are encoded live, exotic
  # ones are represented by their magic bytes.
  FTYP_AVIF = "\x00\x00\x00\x1cftypavif\x00\x00\x00\x00avifmif1miaf".b
  FTYP_HEIC = "\x00\x00\x00\x1cftypheic\x00\x00\x00\x00heicmif1miaf".b
  test "loads PNG" do
    assert_equal "VipsForeignLoadPngFile", loader_for(encode("png"))
  end

  test "loads GIF" do
    assert_equal "VipsForeignLoadNsgifFile", loader_for(encode("gif"))
  end

  test "loads JPEG" do
    assert_equal "VipsForeignLoadJpegFile", loader_for(encode("jpg"))
  end

  test "loads TIFF" do
    assert_equal "VipsForeignLoadTiffFile", loader_for(encode("tif"))
  end

  test "loads WebP" do
    assert_equal "VipsForeignLoadWebpFile", loader_for(encode("webp"))
  end

  test "loads AVIF" do
    assert_equal "VipsForeignLoadHeifFile", loader_for(FTYP_AVIF)
  end

  test "loads HEIC" do
    assert_equal "VipsForeignLoadHeifFile", loader_for(FTYP_HEIC)
  end

  test "blocks BMP through magickload" do
    assert_loader_blocked :magickload, ".bmp"
  end

  test "blocks PSD through magickload" do
    assert_loader_blocked :magickload, ".psd"
  end

  test "blocks ICO through magickload" do
    assert_loader_blocked :magickload, ".ico"
  end

  test "blocks SVG through svgload" do
    assert_loader_blocked :svgload, ".svg"
  end

  test "denies OpenSlide files through openslideload" do
    # OpenSlide files can segfault the embedded sqlite in forked parallel workers
    assert_loader_blocked :openslideload, ".svs"
  end

  test "denies FITS files through fitsload" do
    assert_loader_blocked :fitsload, ".fits"
  end

  test "denies MATLAB files through matload" do
    assert_loader_blocked :matload, ".mat"
  end

  test "denies NIFTI files through niftiload" do
    assert_loader_blocked :niftiload, ".nii"
  end

  test "denies RAW files through dcrawload" do
    assert_loader_blocked :dcrawload, ".raw"
  end

  test "denies VIPS files through vipsload" do
    assert_loader_blocked :vipsload, ".vips"
  end

  private
    # Invoke a specific libvips loader directly and assert it is refused because the
    # operation is blocked (rather than because the bytes are not a valid image).
    def assert_loader_blocked(operation, extension)
      Tempfile.create([ "blocked_loader", extension ], binmode: true) do |file|
        file.write "not an image"
        file.flush

        error = assert_raises(Vips::Error) { Vips::Image.public_send(operation, file.path) }
        actual = error.message.chomp

        # note that exception message may include multiple errors on separate lines,
        # so `^` and `$` anchors are used instead of `\A` and `\z`.
        if actual =~ /^VipsOperation: class \"#{operation}\" not found$/
          skip "libvips does not support #{operation} on this system"
        end
        assert_match(/^#{operation}: operation is blocked$/, actual)
      end
    end

    def encode(ext)
      Vips::Image.black(8, 8).add(128).cast("uchar").write_to_buffer(".#{ext}")
    end

    def loader_for(bytes)
      Tempfile.create(%w[loader_probe .img], binmode: true) do |file|
        file.write bytes
        file.flush
        Vips.vips_foreign_find_load(file.path)
      end
    end
end
