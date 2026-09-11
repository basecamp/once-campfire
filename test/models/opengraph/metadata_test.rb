require "test_helper"

class Opengraph::MetadataTest < ActiveSupport::TestCase
  test "successful fetch" do
    body = <<~HTML
      <html>
        <head>
          <meta property="og:url" content="https://example.com">
          <meta property="og:title" content="Hey!">
          <meta property="og:description" content="Hello">
          <meta property="og:image" content="https://example.com/image.png">
        </head>
      </html>
    HTML

    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: body, headers: { content_type: "text/html" })
    WebMock.stub_request(:head, "https://example.com/image.png").to_return(status: 200, headers: { content_type: "image/png" })

    metadata = Opengraph::Metadata.from_url("https://www.example.com")
    assert metadata.valid?

    assert_equal "https://example.com", metadata.url
    assert_equal "Hey!", metadata.title
    assert_equal "Hello", metadata.description
    assert_equal "https://example.com/image.png", metadata.image
  end

  test "missing opengraph meta tags" do
    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: "<html><head></head></html>", headers: { content_type: "text/html" })
    opengraph = Opengraph::Metadata.from_url("https://www.example.com")

    assert_not opengraph.valid?
    assert_equal [ "Title can't be blank", "Description can't be blank" ],  opengraph.errors.full_messages
  end

  test "URL uses the provided value if the returned value is missing" do
    body = <<~HTML
      <html>
        <head>
          <meta property="og:title" content="Hey!">
          <meta property="og:description" content="Hello">
          <meta property="og:image" content="https://example.com/image.png">
        </head>
      </html>
    HTML

    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: body, headers: { content_type: "text/html" })
    WebMock.stub_request(:head, "https://example.com/image.png").to_return(status: 200, headers: { content_type: "image/png" })

    metadata = Opengraph::Metadata.from_url("https://www.example.com")

    assert metadata.valid?
    assert_equal "https://www.example.com", metadata.url
  end

  test "URL uses the provided value if the returned value is invalid" do
    body = <<~HTML
      <html>
        <head>
          <meta property="og:url" content="/foo">
          <meta property="og:title" content="Hey!">
          <meta property="og:description" content="Hello">
          <meta property="og:image" content="https://example.com/image.png">
        </head>
      </html>
    HTML

    WebMock.stub_request(:get, "https://www.example.com/foo").to_return(status: 200, body: body, headers: { content_type: "text/html" })
    WebMock.stub_request(:head, "https://example.com/image.png").to_return(status: 200, headers: { content_type: "image/png" })

    metadata = Opengraph::Metadata.from_url("https://www.example.com/foo")

    assert metadata.valid?
    assert_equal "https://www.example.com/foo", metadata.url
  end

  test "missing response body" do
    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 403, body: "", headers: { content_type: "text/html" })
    assert_not Opengraph::Metadata.from_url("https://www.example.com").valid?
  end

  test "non html response" do
    WebMock.stub_request(:get, "https://www.example.com/image").to_return(status: 200, body: "[blob]", headers: { content_type: "image/jpeg" })
    assert_not Opengraph::Metadata.from_url("https://www.example.com/image").valid?
  end

  test "relative and invalid image URLs are ignored" do
    body = <<~HTML
      <html>
        <head>
          <meta property="og:url" content="https://example.com">
          <meta property="og:title" content="Hey!">
          <meta property="og:description" content="Hello">
          <meta property="og:image" content="%s">
        </head>
      </html>
    HTML

    [ "/image.png", "foo", "https/incorrect", "~/etc/password" ].each do |invalid_image_url|
      WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: body % invalid_image_url, headers: { content_type: "text/html" })
      opengraph = Opengraph::Metadata.from_url("https://www.example.com")

      assert opengraph.valid?
      assert_nil opengraph.image
    end
  end

  test "sanitize title and description" do
    body = <<~HTML
      <html>
        <head>
          <meta property="og:title" content="Hey!<script>alert('hi')</script>">
          <meta property="og:description" content="Hello<script>alert('hi')</script>">
          <meta property="og:image" content="https://example.com/image.png">
        </head>
      </html>
    HTML

    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: body, headers: { content_type: "text/html" })
    WebMock.stub_request(:head, "https://example.com/image.png").to_return(status: 200, headers: { content_type: "image/png" })

    metadata = Opengraph::Metadata.from_url("https://www.example.com")

    assert metadata.valid?
    assert_equal "Hey!alert('hi')", metadata.title
    assert_equal "Helloalert('hi')", metadata.description
  end

  test "remove encoded tags from title and description" do
    body = <<~HTML
      <html>
        <head>
          <meta property="og:title" content="Hey!&#x3c;&#x2f;&#x73;&#x63;&#x72;&#x69;&#x70;&#x74;&#x3e;&#x3c;&#x69;&#x6d;&#x67;&#x20;&#x73;&#x72;&#x63;&#x3d;&#x61;&#x20;&#x6f;&#x6e;&#x65;&#x72;&#x72;&#x6f;&#x72;&#x3d;&#x70;&#x72;&#x6f;&#x6d;&#x70;&#x74;&#x28;&#x31;&#x29;&#x3e;">
          <meta property="og:description" content="Hello&#x3c;&#x2f;&#x73;&#x63;&#x72;&#x69;&#x70;&#x74;&#x3e;&#x3c;&#x69;&#x6d;&#x67;&#x20;&#x73;&#x72;&#x63;&#x3d;&#x61;&#x20;&#x6f;&#x6e;&#x65;&#x72;&#x72;&#x6f;&#x72;&#x3d;&#x70;&#x72;&#x6f;&#x6d;&#x70;&#x74;&#x28;&#x32;&#x29;&#x3e;</script>">
          <meta property="og:image" content="https://example.com/image.png">
        </head>
      </html>
    HTML

    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: body, headers: { content_type: "text/html" })
    WebMock.stub_request(:head, "https://example.com/image.png").to_return(status: 200, headers: { content_type: "image/png" })

    metadata = Opengraph::Metadata.from_url("https://www.example.com")

    assert metadata.valid?
    assert_equal "Hey!", metadata.title
    assert_equal "Hello", metadata.description
  end

  test "a title or description that is entirely a markup tag is stripped to blank and rejected" do
    body = <<~HTML
      <html>
        <head>
          <meta property="og:title" content="<img src='x' onerror='alert(document.domain)'/>">
          <meta property="og:description" content="<img src='x' onerror='alert(document.domain)'/>">
          <meta property="og:image" content="https://example.com/image.png">
        </head>
      </html>
    HTML

    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: body, headers: { content_type: "text/html" })
    WebMock.stub_request(:head, "https://example.com/image.png").to_return(status: 200, headers: { content_type: "image/png" })

    metadata = Opengraph::Metadata.from_url("https://www.example.com")

    assert_not metadata.valid?
    assert_equal "", metadata.title
    assert_equal "", metadata.description
    assert_includes metadata.errors.full_messages, "Title can't be blank"
    assert_includes metadata.errors.full_messages, "Description can't be blank"
  end

  test "does not allow SVG content type for preview image" do
    body = <<~HTML
      <html>
        <head>
          <meta property="og:url" content="https://example.com">
          <meta property="og:title" content="Hey!">
          <meta property="og:description" content="Hello">
          <meta property="og:image" content="https://example.com/image.svg">
        </head>
      </html>
    HTML

    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: body, headers: { content_type: "text/html" })
    WebMock.stub_request(:head, "https://example.com/image.svg").to_return(status: 200, headers: { content_type: "image/svg+xml" })

    metadata = Opengraph::Metadata.from_url("https://www.example.com")
    assert metadata.valid?

    assert_nil metadata.image
  end
end
