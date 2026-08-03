require "test_helper"

load Rails.root.join("bin/boot") unless defined?(ProcessMonitor)

class ProcessMonitorTest < ActiveSupport::TestCase
  class FakeStatus
    def initialize(success)
      @success = success
    end

    def success?
      @success
    end
  end

  class FakeProcess
    attr_reader :name, :status, :started, :terminated, :killed

    def initialize(name: "web", status: FakeStatus.new(true), finished: true, &on_start)
      @name = name
      @status = status
      @finished = finished
      @on_start = on_start
    end

    def start
      @started = true
      @on_start&.call
    end

    def terminate
      @terminated = true
    end

    def kill
      @killed = true
    end

    def finished?
      @finished
    end

    def finish!
      @finished = true
    end
  end

  test "does not start more processes after shutdown begins" do
    monitor = ProcessMonitor.allocate
    first = FakeProcess.new { monitor.instance_variable_set(:@shutdown_requested, true) }
    second = FakeProcess.new
    monitor.instance_variable_set(:@procs, [ first, second ])

    monitor.send(:start_processes)

    assert first.started
    assert first.terminated
    assert_not second.started
  end

  test "escalates every process group after the graceful deadline" do
    now = 100.0
    monitor = ProcessMonitor.allocate
    processes = [ FakeProcess.new, FakeProcess.new ]
    monitor.instance_variable_set(:@procs, processes)
    monitor.instance_variable_set(:@shutdown_timeout, 25)
    monitor.instance_variable_set(:@kill_timeout, 5)
    monitor.instance_variable_set(:@clock, -> { now })

    monitor.send(:shut_down)
    assert processes.all?(&:terminated)
    assert_equal 125.0, monitor.instance_variable_get(:@shutdown_deadline)

    now = 126.0
    monitor.send(:enforce_shutdown_deadline)
    assert processes.all?(&:killed)
    assert_equal 131.0, monitor.instance_variable_get(:@kill_deadline)
  end

  test "terminates Redis after dependent processes finish" do
    monitor = ProcessMonitor.allocate
    worker = FakeProcess.new(name: "worker", finished: false)
    redis = FakeProcess.new(name: "redis", finished: false)
    monitor.instance_variable_set(:@procs, [ worker, redis ])
    monitor.instance_variable_set(:@shutdown_timeout, 25)
    monitor.instance_variable_set(:@clock, -> { 100.0 })

    monitor.send(:shut_down)

    assert worker.terminated
    assert_not redis.terminated

    worker.finish!
    monitor.send(:terminate_redis_if_ready)

    assert redis.terminated
  end

  test "monitored processes are spawned and signaled as process groups" do
    Process.expects(:spawn).with("worker command", pgroup: true).returns(4321)
    Process.expects(:kill).with("TERM", -4321)
    Process.expects(:kill).with("KILL", -4321)
    process = MonitoredProcess.new("worker", "worker command")

    process.start
    process.terminate
    process.kill
  end

  test "reaps adopted descendants without losing direct child status" do
    monitor = ProcessMonitor.allocate
    process = MonitoredProcess.new("worker", "worker command")
    process.instance_variable_set(:@pid, 4321)
    direct_status = FakeStatus.new(true)
    adopted_status = FakeStatus.new(false)
    monitor.instance_variable_set(:@procs, [ process ])
    Process.expects(:waitpid2).with(-1, Process::WNOHANG).times(3)
      .returns([ 9876, adopted_status ], [ 4321, direct_status ], nil)

    monitor.send(:reap_children)

    assert process.exited?
    assert_same direct_status, process.status
  end

  test "a reaped leader is not finished while descendants remain in its process group" do
    process = MonitoredProcess.new("worker", "worker command")
    process.instance_variable_set(:@pid, 4321)
    process.instance_variable_set(:@reaped, true)
    Process.expects(:kill).with(0, -4321).returns(1)

    assert_not process.finished?
  end

  test "a reaped process is finished after its process group disappears" do
    process = MonitoredProcess.new("worker", "worker command")
    process.instance_variable_set(:@pid, 4321)
    process.instance_variable_set(:@reaped, true)
    Process.expects(:kill).with(0, -4321).raises(Errno::ESRCH)

    assert process.finished?
  end

  test "accepts signaled non-Redis writers after Redis exits successfully" do
    monitor = ProcessMonitor.allocate
    processes = [
      FakeProcess.new(name: "web", status: FakeStatus.new(false)),
      FakeProcess.new(name: "redis", status: FakeStatus.new(true)),
      FakeProcess.new(name: "dispatcher", status: FakeStatus.new(false))
    ]
    monitor.instance_variable_set(:@procs, processes)

    assert monitor.send(:validate_shutdown!)
  end

  test "rejects a nonzero Redis exit during requested shutdown" do
    monitor = ProcessMonitor.allocate
    monitor.instance_variable_set(:@procs, [
      FakeProcess.new(name: "web"),
      FakeProcess.new(name: "redis", status: FakeStatus.new(false))
    ])

    error = nil
    _stdout, stderr = capture_io do
      error = assert_raises(SystemExit) { monitor.send(:validate_shutdown!) }
    end
    assert_equal 1, error.status
    assert_match "Redis did not exit successfully", stderr
  end

  test "rejects shutdown that required SIGKILL even when every group stopped" do
    monitor = ProcessMonitor.allocate
    monitor.instance_variable_set(:@procs, [ FakeProcess.new(name: "redis") ])
    monitor.instance_variable_set(:@forced_shutdown, true)

    _stdout, stderr = capture_io do
      assert_raises(SystemExit) { monitor.send(:validate_shutdown!) }
    end
    assert_match "graceful shutdown timed out", stderr
  end

  test "rejects process groups still alive after the kill timeout" do
    monitor = ProcessMonitor.allocate
    monitor.instance_variable_set(:@procs, [
      FakeProcess.new(name: "redis", finished: false)
    ])

    _stdout, stderr = capture_io do
      assert_raises(SystemExit) { monitor.send(:validate_shutdown!) }
    end
    assert_match "did not stop after forced termination", stderr
  end
end
