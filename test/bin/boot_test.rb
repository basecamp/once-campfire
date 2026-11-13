require "test_helper"

class BootScriptTest < ActiveSupport::TestCase
  # Stands in for a Procfile process: records when it starts, when it's asked to stop,
  # and how many TERMs it got by the time it exits. Exits on its own once exit-NAME exists.
  FAKE_PROCESS = <<~RUBY
    name, stop_delay = ARGV
    terms = 0
    trap("TERM") { terms += 1 }

    record = ->(file, line) { File.open(file, "a") { |io| io.puts line } }
    record.call "pids", Process.pid
    record.call "events", "\#{name} started"

    sleep 0.01 until terms > 0 || File.exist?("exit-\#{name}")

    if terms > 0
      record.call "events", "\#{name} stopping"
      sleep stop_delay.to_f
    end
    record.call "events", "\#{name} stopped"
    record.call "events", "\#{name} got \#{terms} TERM"
  RUBY

  test "stops redis once the processes that use it have exited" do
    events = boot(redis: 0, web: 0.2, workers: 0.4) { |pid| Process.kill "TERM", pid }

    assert_before events, "web stopped", "redis stopping"
    assert_before events, "workers stopped", "redis stopping"
  end

  test "asks each process to stop only once while the others exit" do
    events = boot(redis: 0, web: 0, workers: 0.5) { |pid| Process.kill "TERM", pid }

    assert_includes events, "workers got 1 TERM"
    assert_includes events, "redis got 1 TERM"
  end

  test "stops the others, redis last, when one process exits on its own" do
    events = boot(redis: 0, web: 0, workers: 0.2) { |pid, dir| FileUtils.touch File.join(dir, "exit-web") }

    assert_includes events, "web got 0 TERM"
    assert_before events, "workers stopped", "redis stopping"
  end

  test "stops in the same order when a terminal's Ctrl-C reaches its whole process group" do
    events = boot(redis: 0, web: 0.2, workers: 0.4) { |pid| Process.kill "INT", -pid }

    assert_before events, "web stopped", "redis stopping"
    assert_before events, "workers stopped", "redis stopping"
  end

  private
    def assert_before(events, earlier, later)
      assert_includes events, earlier
      assert_includes events, later
      assert_operator events.index(earlier), :<, events.index(later), "#{earlier.inspect} should come before #{later.inspect} in #{events}"
    end

    def boot(stop_delays)
      Dir.mktmpdir do |dir|
        File.write File.join(dir, "fake_process.rb"), FAKE_PROCESS
        File.write File.join(dir, "Procfile"), stop_delays.map { |name, delay|
          "#{name}: exec #{RbConfig.ruby} fake_process.rb #{name} #{delay}"
        }.join("\n")

        pid = Process.spawn(RbConfig.ruby, Rails.root.join("bin/boot").to_s, chdir: dir, pgroup: true)

        exited = false
        begin
          assert wait_until { lines_in(dir, "events").count { |event| event.end_with?(" started") } == stop_delays.size }, "processes didn't start"
          yield pid, dir
          exited = wait_until { Process.wait(pid, Process::WNOHANG) }
          assert exited, "bin/boot didn't exit"

          lines_in(dir, "events")
        ensure
          # Once bin/boot has exited it has reaped every process; otherwise they're left to kill
          kill_all [ pid, *lines_in(dir, "pids").map(&:to_i) ] unless exited
        end
      end
    end

    def lines_in(dir, name)
      path = File.join(dir, name)
      File.exist?(path) ? File.readlines(path, chomp: true) : []
    end

    def wait_until(timeout: 10)
      deadline = Time.now + timeout
      until (result = yield) || Time.now > deadline
        sleep 0.01
      end
      result
    end

    def kill_all(pids)
      pids.each do |pid|
        Process.kill "KILL", pid
      rescue Errno::ESRCH
      end
      Process.wait pids.first
    rescue Errno::ECHILD
    end
end
