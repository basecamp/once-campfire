module ContentLimits
  class Exceeded < StandardError; end

  # The longest server-generated ID is a 50-byte webhook reply ID.
  CLIENT_MESSAGE_ID_BYTES = 64
  MESSAGE_BODY_BYTES = 64.kilobytes
  ATTACHMENT_BYTES = 100.megabytes
  WEBHOOK_RESPONSE_BYTES = ATTACHMENT_BYTES
  REQUEST_BODY_BYTES = ATTACHMENT_BYTES + 2.megabytes
  MAXIMUM_CONFIGURED_REQUEST_BODY_BYTES = ATTACHMENT_BYTES + 16.megabytes
  READ_CHUNK_BYTES = 16.kilobytes

  def self.verify!(bytes, maximum:, description: "content")
    return if bytes <= maximum

    raise Exceeded, "#{description} exceeds the #{maximum}-byte limit"
  end

  def self.read(io, maximum:, description: "content")
    content = +"".b
    append = ->(chunk) do
      content << chunk
      verify! content.bytesize, maximum:, description:
    end

    if io.respond_to?(:read_body)
      io.read_body { |chunk| append.call(chunk) }
    else
      loop do
        chunk = io.read([ READ_CHUNK_BYTES, maximum - content.bytesize + 1 ].min)
        break if chunk.nil? || chunk.empty?

        append.call chunk
      end
    end
    content
  end

  def self.request_body_bytes(env = ENV)
    bytes = Integer(env.fetch("MAX_REQUEST_BODY", REQUEST_BODY_BYTES).to_s, 10)
    unless bytes.between?(REQUEST_BODY_BYTES, MAXIMUM_CONFIGURED_REQUEST_BODY_BYTES)
      raise ArgumentError,
        "MAX_REQUEST_BODY must be between #{REQUEST_BODY_BYTES} and #{MAXIMUM_CONFIGURED_REQUEST_BODY_BYTES} bytes"
    end

    bytes
  rescue ArgumentError => error
    raise ArgumentError, "Invalid MAX_REQUEST_BODY: #{error.message}"
  end
end
