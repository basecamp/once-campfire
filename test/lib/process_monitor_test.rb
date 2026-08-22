require "test_helper"
require "erb"
require "rbconfig"
require "timeout"

load Rails.root.join("bin/boot") unless defined?(ProcessMonitor)

class ProcessMonitorTest < ActiveSupport::TestCase
  class FakeStatus
    attr_reader :termsig

    def initialize(success, termsig: nil)
      @success = success
      @termsig = termsig
    end

    def success?
      @success
    end

    def signaled?
      !termsig.nil?
    end
  end

  class FakeProcess
    attr_reader :name, :pid, :status, :started, :terminated, :termination_signal, :killed

    def initialize(name: "web", status: FakeStatus.new(true), finished: true, &on_start)
      @name = name
      @status = status
      @finished = finished
      @on_start = on_start
      @expected_signals = []
    end

    def start
      @started = true
      @on_start&.call
    end

    def terminate(signal = "TERM")
      @terminated = true
      @termination_signal = signal
      @expected_signals << Signal.list.fetch(signal.to_s.delete_prefix("SIG"))
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

    def acceptable_exit?
      acceptable_status?(status)
    end

    def acceptable_status?(status)
      status&.success? || (status&.signaled? && @expected_signals.include?(status.termsig))
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

  test "uses a shutdown default long enough for bounded delivery retries" do
    assert_equal 60, ProcessMonitor::DEFAULT_SHUTDOWN_TIMEOUT
  end

  test "rejects a nonpositive configured shutdown timeout" do
    assert_raises(ArgumentError) do
      ProcessMonitor.new("unused", shutdown_timeout: 0)
    end
  end

  test "installs signal supervision without starting runtime processes" do
    YAML.expects(:load_file).with("Procfile").returns({})
    Signal.expects(:trap).with("INT")
    Signal.expects(:trap).with("TERM")

    ProcessMonitor.new("Procfile", autostart: false)
  end

  test "resque concurrency requires a positive integer" do
    template = ERB.new(Rails.root.join("config/resque-pool.yml").read)
    previous = ENV["JOB_CONCURRENCY"]

    %w[ 0 -1 1.5 ].each do |value|
      ENV["JOB_CONCURRENCY"] = value
      assert_raises(ArgumentError) { template.result }
    end
    ENV["JOB_CONCURRENCY"] = "2"
    assert_equal({ "default" => 2 }, YAML.safe_load(template.result))
  ensure
    previous ? ENV["JOB_CONCURRENCY"] = previous : ENV.delete("JOB_CONCURRENCY")
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

  test "accepts only a signal that was successfully issued by the supervisor" do
    expected = MonitoredProcess.new("worker", "worker command")
    expected.instance_variable_set(:@pid, 4321)
    Process.expects(:kill).with("TERM", -4321).returns(1)
    expected.terminate
    expected.record_exit FakeStatus.new(false, termsig: Signal.list.fetch("TERM"))

    not_issued = MonitoredProcess.new("worker", "worker command")
    not_issued.instance_variable_set(:@pid, 4322)
    Process.expects(:kill).with("TERM", -4322).raises(Errno::ESRCH)
    not_issued.terminate
    not_issued.record_exit FakeStatus.new(false, termsig: Signal.list.fetch("TERM"))

    assert expected.acceptable_exit?
    assert_not not_issued.acceptable_exit?
  end

  test "database preparation is spawned in its own process group and reaped" do
    monitor = ProcessMonitor.allocate
    monitor.instance_variable_set(:@procs, [])
    monitor.instance_variable_set(:@shutdown_timeout, 60)
    monitor.instance_variable_set(:@kill_timeout, 5)
    monitor.instance_variable_set(:@clock, -> { 100.0 })
    monitor.instance_variable_set(:@sleeper, ->(*) { })
    status = FakeStatus.new(true)
    environment = { "LOCK_FD" => "3" }
    Process.expects(:spawn)
      .with(environment, "./bin/rails", "db:prepare", close_others: false, pgroup: true)
      .returns(4321)
    Process.expects(:waitpid2).with(-4321, Process::WNOHANG).twice
      .returns([ 4321, status ], nil)
    Process.expects(:waitpid2).with(-1, Process::WNOHANG).raises(Errno::ECHILD)
    Process.expects(:kill).with(0, -4321).raises(Errno::ESRCH)

    assert monitor.run_preparation(environment, "./bin/rails", "db:prepare", close_others: false)
  end

  test "an interrupt is forwarded to database preparation and makes preparation fail" do
    monitor = ProcessMonitor.allocate
    monitor.instance_variable_set(:@procs, [])
    monitor.instance_variable_set(:@shutdown_timeout, 60)
    monitor.instance_variable_set(:@kill_timeout, 5)
    monitor.instance_variable_set(:@clock, -> { 100.0 })
    monitor.instance_variable_set(:@sleeper, lambda do |*|
      monitor.instance_variable_set(:@interrupted, true)
      monitor.send(:shut_down, "INT")
    end)
    status = FakeStatus.new(false, termsig: Signal.list.fetch("INT"))
    Process.expects(:spawn)
      .with({}, "./bin/rails", "db:prepare", close_others: false, pgroup: true)
      .returns(4321)
    Process.expects(:waitpid2).with(-4321, Process::WNOHANG).times(3)
      .returns(nil, [ 4321, status ], nil)
    Process.expects(:waitpid2).with(-1, Process::WNOHANG).twice.raises(Errno::ECHILD)
    Process.expects(:kill).with("INT", -4321)
    Process.expects(:kill).with(0, -4321).raises(Errno::ESRCH)

    assert_not monitor.run_preparation({}, "./bin/rails", "db:prepare", close_others: false)
    assert monitor.interrupted?
  end

  test "reaps adopted descendants by process group without losing leader status" do
    monitor = ProcessMonitor.allocate
    process = MonitoredProcess.new("worker", "worker command")
    process.instance_variable_set(:@pid, 4321)
    direct_status = FakeStatus.new(true)
    adopted_status = FakeStatus.new(false)
    monitor.instance_variable_set(:@procs, [ process ])
    Process.expects(:waitpid2).with(-4321, Process::WNOHANG).times(3)
      .returns([ 9876, adopted_status ], [ 4321, direct_status ], nil)
    Process.expects(:waitpid2).with(-1, Process::WNOHANG).raises(Errno::ECHILD)

    monitor.send(:reap_children)

    assert process.exited?
    assert_same direct_status, process.status
    assert_not process.acceptable_exit?
  end

  test "ignores a successfully reaped child outside monitored process groups" do
    monitor = ProcessMonitor.allocate
    process = MonitoredProcess.new("worker", "worker command")
    process.instance_variable_set(:@pid, 4321)
    direct_status = FakeStatus.new(true)
    unrelated_status = FakeStatus.new(true)
    monitor.instance_variable_set(:@procs, [ process ])
    Process.expects(:waitpid2).with(-4321, Process::WNOHANG).twice
      .returns([ 4321, direct_status ], nil)
    Process.expects(:waitpid2).with(-1, Process::WNOHANG).twice
      .returns([ 9876, unrelated_status ], nil)

    monitor.send(:reap_children)

    assert process.acceptable_exit?
    assert_not monitor.send(:unexpected_unattributed_descendant_exit?)
  end

  test "accepts an adopted descendant killed by a signal issued to its process group" do
    process = MonitoredProcess.new("worker", "worker command")
    process.instance_variable_set(:@pid, 4321)
    Process.expects(:kill).with("TERM", -4321).returns(1)

    process.terminate
    process.record_exit FakeStatus.new(true)
    process.record_descendant_exit FakeStatus.new(false, termsig: Signal.list.fetch("TERM"))

    assert process.acceptable_exit?
  end

  test "rejects clean shutdown when a nested worker fails and its leader succeeds" do
    workers = MonitoredProcess.new("workers", [ RbConfig.ruby, "-e", "sleep 0.3" ])
    nested_pid = nil
    workers.start(out: File::NULL, err: File::NULL)
    # PID 1 sees an adopted worker as a direct child, so joining a real child to
    # the leader's group reproduces the relevant wait semantics portably.
    nested_pid = Process.spawn(
      RbConfig.ruby, "-e", "exit! 23", pgroup: workers.pid, out: File::NULL, err: File::NULL
    )
    monitor = ProcessMonitor.allocate
    monitor.instance_variable_set(:@procs, [ workers, FakeProcess.new(name: "redis") ])
    monitor.instance_variable_set(:@shutdown_requested, true)

    Timeout.timeout(5) do
      loop do
        monitor.send(:reap_children)
        break if workers.finished?

        sleep ProcessMonitor::POLL_INTERVAL
      end
    end

    assert workers.status.success?
    _stdout, stderr = capture_io do
      assert_raises(SystemExit) { monitor.send(:validate_shutdown!) }
    end
    assert_match "exited unsuccessfully", stderr
  ensure
    begin
      Process.kill("KILL", -workers.pid) if workers&.pid
    rescue Errno::ESRCH
      nil
    end
    [ nested_pid, workers&.pid ].compact.each do |pid|
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
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

  test "accepts the exact signal issued to non-Redis writers after Redis exits successfully" do
    monitor = ProcessMonitor.allocate
    web = FakeProcess.new(name: "web", status: FakeStatus.new(false, termsig: Signal.list.fetch("TERM")))
    dispatcher = FakeProcess.new(name: "dispatcher", status: FakeStatus.new(true))
    web.terminate("TERM")
    processes = [
      web,
      FakeProcess.new(name: "redis", status: FakeStatus.new(true)),
      dispatcher
    ]
    monitor.instance_variable_set(:@procs, processes)

    assert monitor.send(:validate_shutdown!)
  end

  test "rejects a child exit 1 after shutdown was requested" do
    monitor = ProcessMonitor.allocate
    web = FakeProcess.new(name: "web", status: FakeStatus.new(false))
    web.terminate("TERM")
    monitor.instance_variable_set(:@procs, [
      web, FakeProcess.new(name: "redis", status: FakeStatus.new(true))
    ])

    _stdout, stderr = capture_io do
      assert_raises(SystemExit) { monitor.send(:validate_shutdown!) }
    end
    assert_match "processes exited unsuccessfully: web", stderr
  end

  test "rejects SIGSEGV after shutdown was requested" do
    monitor = ProcessMonitor.allocate
    web = FakeProcess.new(name: "web", status: FakeStatus.new(false, termsig: Signal.list.fetch("SEGV")))
    web.terminate("TERM")
    monitor.instance_variable_set(:@procs, [
      web, FakeProcess.new(name: "redis", status: FakeStatus.new(true))
    ])

    _stdout, stderr = capture_io do
      assert_raises(SystemExit) { monitor.send(:validate_shutdown!) }
    end
    assert_match "processes exited unsuccessfully: web", stderr
  end

  test "rejects a signal the supervisor did not issue" do
    monitor = ProcessMonitor.allocate
    web = FakeProcess.new(name: "web", status: FakeStatus.new(false, termsig: Signal.list.fetch("INT")))
    web.terminate("TERM")
    monitor.instance_variable_set(:@procs, [
      web, FakeProcess.new(name: "redis", status: FakeStatus.new(true))
    ])

    _stdout, stderr = capture_io do
      assert_raises(SystemExit) { monitor.send(:validate_shutdown!) }
    end
    assert_match "processes exited unsuccessfully: web", stderr
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
