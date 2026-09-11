require "application_system_test_case"
require "socket"

class UnfurlingLinksTest < ApplicationSystemTestCase
  setup do
    @website = Website.new
    @website.start
    RestrictedHTTP::PrivateNetworkGuard.stubs(:resolve).returns("127.0.0.1")

    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  teardown do
    @website.stop
  end

  test "a quote in the opengraph image URL cannot add attributes to the preview" do
    paste_into_composer @website.page_url

    assert_selector "trix-editor .og-embed__title", text: "A normal looking link"

    assert_equal @website.image_url, preview_image_attributes["src"]
    assert_empty preview_image_attributes.keys - %w[ src class alt ]
  end

  private
    def paste_into_composer(url)
      page.execute_script(<<~JS, url)
        const editor = document.querySelector("trix-editor")
        editor.focus()

        const clipboardData = new DataTransfer()
        clipboardData.setData("text/plain", arguments[0])
        editor.dispatchEvent(new ClipboardEvent("paste", { clipboardData, bubbles: true, cancelable: true }))
      JS
    end

    def preview_image_attributes
      page.evaluate_script(<<~JS)
        Object.fromEntries(Array.from(document.querySelector("trix-editor .og-embed__image img").attributes, attribute => [ attribute.name, attribute.value ]))
      JS
    end

    # Serves a page whose og:image URL carries a double quote, so an unescaped
    # preview closes the src attribute early and takes the rest as attributes.
    class Website
      def start
        @socket = TCPServer.new("127.0.0.1", 0)
        @thread = Thread.new { serve }
      end

      def stop
        @thread&.kill
        @socket&.close
      end

      def page_url
        "http://127.0.0.1:#{port}/page.html"
      end

      def image_url
        %(http://127.0.0.1:#{port}/image.png?from=" style="outline:9px solid red)
      end

      private
        def port
          @socket.addr[1]
        end

        def serve
          loop do
            client = @socket.accept
            Thread.new(client) { |connection| respond_to(connection) }
          end
        rescue IOError, Errno::EBADF
          nil
        end

        def respond_to(client)
          request_line = client.gets.to_s
          nil while (line = client.gets) && line != "\r\n"

          method, path = request_line.split(" ")

          if path.to_s.start_with?("/image.png")
            respond client, "image/png", method == "HEAD" ? "" : "not really a PNG"
          else
            respond client, "text/html", page
          end
        rescue IOError, Errno::ECONNRESET
          nil
        ensure
          client.close rescue nil
        end

        def respond(client, content_type, body)
          client.write "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        end

        def page
          <<~HTML
            <html><head>
              <meta property="og:url" content="https://example.com/harmless">
              <meta property="og:title" content="A normal looking link">
              <meta property="og:description" content="Nothing to see here">
              <meta property="og:image" content='#{image_url}'>
            </head><body>Hello</body></html>
          HTML
        end
    end
end
