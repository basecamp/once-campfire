require "test_helper"

class User::MutationFenceTest < ActiveSupport::TestCase
  test "readiness creates opens locks and removes a probe file" do
    assert User::MutationFence.ready?
    lock_root = User::MutationFence.send(:lock_root)
    assert_empty Dir[lock_root.join(".readiness-*.lock")]
  end

  test "readiness fails closed when a probe file cannot be opened" do
    File.stubs(:open).raises(Errno::EACCES, "denied")

    assert_not User::MutationFence.ready?
  end

  test "serializes the same user across processes" do
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    start_reader, start_writer = IO.pipe
    result_reader, result_writer = IO.pipe
    user_id = users(:bender).id
    child = fork do
      start_writer.close
      result_reader.close
      start_reader.read(1)
      User::MutationFence.with(user_id) { result_writer.write("1") }
      result_writer.close
      exit! 0
    end
    start_reader.close
    result_writer.close

    User::MutationFence.with(user_id) do
      start_writer.write("1")
      start_writer.close
      assert_nil IO.select([ result_reader ], nil, nil, 0.1)
    end

    assert IO.select([ result_reader ], nil, nil, 2)
    assert_equal "1", result_reader.read(1)
  ensure
    start_reader&.close unless start_reader&.closed?
    start_writer&.close unless start_writer&.closed?
    result_reader&.close unless result_reader&.closed?
    result_writer&.close unless result_writer&.closed?
    Process.wait(child) if child
  end

  test "contended nested user fences fail closed instead of deadlocking" do
    first_id, second_id = users(:david).id, users(:jason).id
    ready = Queue.new
    continue = Queue.new
    results = Queue.new
    workers = [ [ first_id, second_id ], [ second_id, first_id ] ].map do |outer_id, inner_id|
      Thread.new do
        User::MutationFence.with(outer_id) do
          ready << true
          continue.pop
          User::MutationFence.with(inner_id) { results << :acquired }
        end
      rescue StandardError => error
        results << error
      end
    end
    2.times { ready.pop }
    2.times { continue << true }
    workers.each { assert _1.join(2), "nested mutation fences deadlocked" }

    outcomes = 2.times.map { results.pop }
    assert outcomes.any? { _1.is_a?(User::MutationFence::Unavailable) }
  ensure
    2.times { continue << true } if continue
    workers&.each { _1.join(2) }
  end
end
