require "net/http"

module RestrictedHTTP
  module ResponseHeaderGuard
    extend self

    MAXIMUM_LINE_BYTES = 8 * 1024
    MAXIMUM_TOTAL_BYTES = 64 * 1024
    MAXIMUM_HEADER_LINES = 100
    CONTEXT_KEY = :restricted_http_response_header_guard

    class Exceeded < StandardError; end

    class Context
      def start_response!
        @parsing = true
        @status_line = true
        @total_bytes = 0
        @header_lines = 0
      end

      def finish_response!
        @parsing = false
      end

      def parsing?
        @parsing
      end

      def verify_pending_line!(bytes)
        raise Exceeded, "HTTP response header line exceeded #{MAXIMUM_LINE_BYTES} bytes" if bytes > MAXIMUM_LINE_BYTES
        if @total_bytes + bytes > MAXIMUM_TOTAL_BYTES
          raise Exceeded, "HTTP response headers exceeded #{MAXIMUM_TOTAL_BYTES} bytes"
        end
      end

      def record_line!(line)
        verify_pending_line! line.bytesize
        @total_bytes += line.bytesize

        if @status_line
          @status_line = false
        elsif line == "\n" || line == "\r\n"
          finish_response!
        else
          @header_lines += 1
          if @header_lines > MAXIMUM_HEADER_LINES
            raise Exceeded, "HTTP response headers exceeded #{MAXIMUM_HEADER_LINES} lines"
          end
        end
      end
    end

    module ResponseReader
      def read_new(socket)
        context = ResponseHeaderGuard.current_context
        context&.start_response!
        super
      ensure
        context&.finish_response!
      end
    end

    module BoundedReaduntil
      def readuntil(terminator, ignore_eof = false)
        context = ResponseHeaderGuard.current_context
        return super unless context&.parsing? && terminator == "\n"

        offset = @rbuf_offset
        begin
          until index = @rbuf.index(terminator, offset)
            context.verify_pending_line!(@rbuf.bytesize - @rbuf_offset)
            offset = @rbuf.bytesize
            rbuf_fill
          end
          rbuf_consume(index + terminator.bytesize - @rbuf_offset).tap { context.record_line!(_1) }
        rescue EOFError
          raise unless ignore_eof

          rbuf_consume.tap { context.record_line!(_1) unless _1.empty? }
        end
      end
    end

    def with_limits
      previous_context = Thread.current[CONTEXT_KEY]
      Thread.current[CONTEXT_KEY] = Context.new
      yield
    ensure
      Thread.current[CONTEXT_KEY] = previous_context
    end

    def current_context
      Thread.current[CONTEXT_KEY]
    end

    def install!
      response_reader = Net::HTTPResponse.singleton_class
      response_reader.prepend ResponseReader unless response_reader < ResponseReader
      Net::BufferedIO.prepend BoundedReaduntil unless Net::BufferedIO < BoundedReaduntil
    end
  end
end

RestrictedHTTP::ResponseHeaderGuard.install!
