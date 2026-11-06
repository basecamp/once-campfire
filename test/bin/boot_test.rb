require "test_helper"

class BootScriptTest < ActiveSupport::TestCase
  # Stands in for a Procfile process: records when it starts and how it ends. Exits on its own
  # once exit-NAME exists, and leaves an orphan that exits 0.1 s later once orphan-NAME exists.
  FAKE_PROCESS = <<~RUBY
    name = ARGV.first
    terminated = orphaned = false
    trap("TERM") { terminated = true }

    record = ->(file, line) { File.open(file, "a") { |io| io.puts line } }
    record.call "events", "\#{name} started"

    until terminated || File.exist?("exit-\#{name}")
      if !orphaned && File.exist?("orphan-\#{name}")
        orphaned = true
        Process.wait fork { record.call "orphans", fork { sleep 0.1 }; exit! }
      end
      sleep 0.01
    end
    record.call "events", terminated ? "\#{name} got TERM" : "\#{name} exited"
  RUBY

  # In a container bin/boot is PID 1, which adopts orphans. A subreaper adopts them the same way.
  ADOPTING_ORPHANS = <<~RUBY
    require "fiddle"
    PR_SET_CHILD_SUBREAPER = 36
    prctl = Fiddle::Function.new(Fiddle::Handle::DEFAULT["prctl"], [ Fiddle::TYPE_INT ] + [ Fiddle::TYPE_LONG ] * 4, Fiddle::TYPE_INT)
    prctl.call(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0).zero? or abort "prctl failed"
    exec RbConfig.ruby, *ARGV
  RUBY

  # As if started by a parent that ignores SIGCHLD, which exec keeps
  IGNORING_SIGCHLD = <<~RUBY
    trap("CLD", "IGNORE")
    exec RbConfig.ruby, *ARGV
  RUBY

  test "keeps its processes running when an orphan it adopted exits" do
    skip "adopting orphans outside PID 1 needs Linux and fiddle" unless RUBY_PLATFORM.include?("linux") && fiddle?

    events = boot(%w[ web workers ], wrapper: ADOPTING_ORPHANS) do |pid, dir|
      FileUtils.touch File.join(dir, "orphan-web")
      assert wait_until { lines_in(dir, "orphans").any? }, "no orphan was left"
      orphan = lines_in(dir, "orphans").first.to_i

      assert wait_until { [ "Z", nil ].include?(state_of(orphan)) }, "the orphan didn't exit"
      sleep 0.2
      assert_empty lines_in(dir, "events").grep(/TERM/), "the orphan's exit stopped the processes"
      assert wait_until { state_of(orphan).nil? }, "the orphan was left a zombie"

      Process.kill "TERM", pid
    end

    assert_includes events, "web got TERM"
    assert_includes events, "workers got TERM"
  end

  test "stops the other processes when one of them exits" do
    events = boot(%w[ web workers ]) { |pid, dir| FileUtils.touch File.join(dir, "exit-workers") }

    assert_includes events, "workers exited"
    assert_includes events, "web got TERM"
  end

  test "stops the other processes when one of them exits, though started with SIGCHLD ignored" do
    events = boot(%w[ web workers ], wrapper: IGNORING_SIGCHLD) { |pid, dir| FileUtils.touch File.join(dir, "exit-workers") }

    assert_includes events, "workers exited"
    assert_includes events, "web got TERM"
  end

  private
    def boot(names, wrapper: nil)
      Dir.mktmpdir do |dir|
        File.write File.join(dir, "fake_process.rb"), FAKE_PROCESS
        File.write File.join(dir, "Procfile"), names.map { |name| "#{name}: exec #{RbConfig.ruby} fake_process.rb #{name}" }.join("\n")

        command = [ RbConfig.ruby, *([ "-e", wrapper ] if wrapper), Rails.root.join("bin/boot").to_s ]
        pid = Bundler.with_unbundled_env { Process.spawn(*command, chdir: dir, pgroup: true) }

        exited = false
        begin
          assert wait_until { lines_in(dir, "events").count { |event| event.end_with?(" started") } == names.size }, "processes didn't start"
          yield pid, dir
          exited = wait_until { Process.wait(pid, Process::WNOHANG) }
          assert exited, "bin/boot didn't exit"

          lines_in(dir, "events")
        ensure
          # Once bin/boot has exited it has reaped every process; otherwise its process group goes, orphans included
          kill_group pid unless exited
        end
      end
    end

    def fiddle?
      Bundler.with_unbundled_env { system(RbConfig.ruby, "-e", "require 'fiddle'", err: File::NULL) }
    end

    def lines_in(dir, name)
      path = File.join(dir, name)
      File.exist?(path) ? File.readlines(path, chomp: true) : []
    end

    # The process's state letter from /proc ("Z" for a zombie), or nil once it's gone
    def state_of(pid)
      File.read("/proc/#{pid}/stat")[/\) (\w)/, 1]
    rescue Errno::ENOENT
      nil
    end

    def wait_until(timeout: 10)
      deadline = Time.now + timeout
      until (result = yield) || Time.now > deadline
        sleep 0.01
      end
      result
    end

    def kill_group(pid)
      Process.kill "KILL", -pid
      Process.wait pid
    rescue Errno::ESRCH, Errno::ECHILD
    end
end
