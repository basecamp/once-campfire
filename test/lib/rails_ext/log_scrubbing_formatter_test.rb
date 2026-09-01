require "test_helper"

class LogScrubbingFormatterTest < ActiveSupport::TestCase
  setup { @formatter = LogScrubbingFormatter.new }

  test "redacts the bot key path segment from a request log line" do
    line = format(%(Started POST "/rooms/1/5-Ab3xK9mQz1Rt/messages" for 203.0.113.10))
    assert_includes line, "/rooms/1/[FILTERED]/messages"
    assert_not_includes line, "Ab3xK9mQz1Rt"
  end

  test "redacts the bot key reflected in a pagination Link header" do
    line = format(%(Link: <https://campfire.example.com/rooms/42/7-Zt9QmK1xz3Ab/messages?before=99>; rel="next"))
    assert_includes line, "/rooms/42/[FILTERED]/messages?before=99"
    assert_not_includes line, "Zt9QmK1xz3Ab"
  end

  test "redacts every occurrence on a line" do
    line = format("/rooms/1/5-Ab3xK9mQz1Rt/messages and /rooms/2/6-Cd4yL0nR2St7/messages/9/boosts")
    assert_not_includes line, "Ab3xK9mQz1Rt"
    assert_not_includes line, "Cd4yL0nR2St7"
    assert_equal 2, line.scan("[FILTERED]").length
  end

  test "leaves non-bot room paths untouched" do
    line = format(%(Started GET "/rooms/1/messages" for 203.0.113.10))
    assert_includes line, "/rooms/1/messages"
    assert_not_includes line, "[FILTERED]"
  end

  test "preserves surrounding log content" do
    line = format("hello")
    assert_includes line, "hello"
  end

  test "scrubs through the TaggedLogging + STDOUT logger stack as production wires it" do
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
      .tap  { |logger| logger.formatter = LogScrubbingFormatter.new }
      .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

    logger.tagged("req-123") { logger.info(%(Started POST "/rooms/1/5-Ab3xK9mQz1Rt/messages")) }

    output = io.string
    assert_includes output, "[req-123]"
    assert_includes output, "/rooms/1/[FILTERED]/messages"
    assert_not_includes output, "Ab3xK9mQz1Rt"
  end

  private
    def format(message)
      @formatter.call("INFO", Time.now, "app", message)
    end
end
