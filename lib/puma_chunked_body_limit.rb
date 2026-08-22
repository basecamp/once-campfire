require "puma/client"

module PumaChunkedBodyLimit
  AFFECTED_VERSION = Gem::Version.new("7.2.1")
  BodyLimitExceeded = Class.new(StandardError)

  module ClientPatch
    private
      def setup_chunked_body(body)
        super
      rescue BodyLimitExceeded
        reject_oversized_chunked_body
      end

      def read_chunked_body
        super
      rescue BodyLimitExceeded
        reject_oversized_chunked_body
      end

      def write_chunk(chunk)
        if above_http_content_limit(@chunked_content_length + chunk.bytesize)
          raise BodyLimitExceeded
        end

        super
      end

      def reject_oversized_chunked_body
        @http_content_length_limit_exceeded = true
        @env[Puma::Const::HTTP_CONNECTION] = Puma::Const::CLOSE
        @buffer = nil
        @body = Puma::Client::EmptyBody
        set_ready
        true
      end
  end

  if Gem.loaded_specs.fetch("puma").version == AFFECTED_VERSION
    Puma::Client.prepend(ClientPatch) unless Puma::Client < ClientPatch
  end
end
