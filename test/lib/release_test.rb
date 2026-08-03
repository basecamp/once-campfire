require "test_helper"
require "rbconfig"
require "tmpdir"
require "yaml"

load Rails.root.join("bin/release")

class ReleaseTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  class SimulatedCrash < Exception; end
  CHANNEL_KEYS = %w[
    ghcr_minor ghcr_major ghcr_latest once_latest
    static_once-store-app-101 static_once-store-app-102 github_public github_latest
  ].freeze
  PHASE_KEYS = %w[
    tag draft workflow ghcr_immutable secondary_immutable static_immutable
    github_assets static_staging promotion_prepared promotion publication
  ].freeze

  class FakeLock
    attr_reader :journal

    def initialize(journal, invocation_lock: nil, mutation_status: nil)
      @journal = deep_copy(journal)
      @invocation_lock = invocation_lock
      @mutation_status = mutation_status
    end

    def assert_held!
      true
    end

    def write_journal(journal)
      journal["journal_revision"] = journal.fetch("journal_revision", 0) + 1
      @journal = deep_copy(journal)
    end

    def run_mutation!(*command, env: {})
      return @mutation_status if @mutation_status
      raise "No invocation lock configured" unless @invocation_lock

      @invocation_lock.run_mutation!(*command, env:)
    end

    private
      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
  end

  class ControlledFailureInput
    def initialize(gate)
      @gate = gate
    end

    def read(*)
      @gate.pop
      raise IOError, "injected mutation input failure"
    end

    alias_method :readpartial, :read
  end

  class ControlledFailureOutput
    def initialize(stream, gate)
      @stream = stream
      @gate = gate
    end

    def read(*)
      @gate.pop
      raise IOError, "injected mutation output failure"
    end

    def close
      @stream.close
    end

    def closed?
      @stream.closed?
    end
  end

  test "release journal rejects modified state" do
    journal = { "release" => { "tag" => "v1.2.3" }, "status" => "prepared" }
    envelope = ReleaseJournal.envelope(journal, key: "release-lock-token")
    envelope.fetch("journal")["status"] = "completed"

    assert_raises(ReleaseStateError) do
      ReleaseJournal.verify!(JSON.generate(envelope), key: "release-lock-token")
    end
  end

  test "release journal cannot be forged with the public lock owner value" do
    journal = { "lock_id" => "a" * 64, "status" => "prepared" }
    envelope = ReleaseJournal.envelope(journal, key: "independent release journal key")

    assert_raises(ReleaseStateError) do
      ReleaseJournal.verify!(JSON.generate(envelope), key: journal.fetch("lock_id"))
    end
  end

  test "release journal key is removed from inherited environment when read" do
    key = "k" * 32
    environment = {
      ReleaseJournal::KEY_ENVIRONMENT_VARIABLE => Base64.strict_encode64(key),
      "VISIBLE" => "value"
    }

    assert_equal key, ReleaseJournal.key_from_env(environment)
    assert_equal({ "VISIBLE" => "value" }, environment)
  end

  test "GitHub remote parsing accepts only canonical SSH and HTTPS URLs" do
    accepted = [
      "git@github.com:basecamp/once-campfire.git",
      "git@github.com:basecamp/once-campfire",
      "ssh://git@github.com/basecamp/once-campfire.git",
      "https://github.com/basecamp/once-campfire.git"
    ]
    rejected = [
      "/tmp/github.com/basecamp/once-campfire",
      "git@github.com.evil.example:basecamp/once-campfire.git",
      "https://github.com.evil.example/basecamp/once-campfire.git",
      "https://github.com@evil.example/basecamp/once-campfire.git",
      "https://evil.example/github.com/basecamp/once-campfire.git",
      "https://github.com/basecamp/once-campfire.git/extra",
      "git@github.com:attacker/once-campfire.git"
    ]

    accepted.each { assert_equal EXPECTED_REPOSITORY, canonical_github_repository(_1), _1 }
    rejected.each { assert_nil canonical_github_repository(_1), _1 }
  end

  test "release remote rejects an evil push URL even when its fetch URL is canonical" do
    stubs(:capture!).with("git", "remote", "get-url", "--all", "origin")
      .returns("https://github.com/basecamp/once-campfire.git")
    stubs(:capture!).with("git", "remote", "get-url", "--push", "--all", "origin")
      .returns("ssh://git@github.com.evil.example/basecamp/once-campfire.git")

    output = capture_io { assert_raises(SystemExit) { github_repository("origin") } }
    assert_match "every fetch and push URL", output.last
  end

  test "phase zero is a complete authenticated journal before later phases" do
    journal = {
      "lock_id" => "a" * 64,
      "journal_revision" => 0,
      "status" => "locked",
      "phase" => "phase_zero",
      "phases" => { "phase_zero" => { "status" => "completed" } }
    }
    lock = FakeLock.new(journal)

    start_release_phase! lock, lock.journal, "tag", "tag" => "v1.2.3"
    complete_release_phase! lock, lock.journal, "tag", "tag" => "v1.2.3"

    assert_equal "completed", lock.journal.dig("phases", "phase_zero", "status")
    assert_equal "completed", lock.journal.dig("phases", "tag", "status")
    assert_equal 2, lock.journal.fetch("journal_revision")
  end

  test "every release phase retains a resumable started checkpoint" do
    PHASE_KEYS.each do |phase|
      initial = phase_zero_journal.merge("lock_id" => "a" * 64)
      lock = FakeLock.new(initial)
      data = { "phase_key" => phase }

      start_release_phase! lock, lock.journal, phase, data
      interrupted = lock.journal
      assert_equal "started", interrupted.dig("phases", phase, "status")
      assert_equal data, interrupted.dig("phases", phase, "data")

      resumed = FakeLock.new(interrupted)
      complete_release_phase! resumed, resumed.journal, phase, data
      assert_equal "completed", resumed.journal.dig("phases", phase, "status")
      assert_equal data, resumed.journal.dig("phases", phase, "data")
    end
  end

  test "pending state accepts only an untouched authenticated phase-zero journal" do
    initial = phase_zero_journal
    lock_id = "a" * 64
    state = { lock_id:, journal: initial.merge("lock_id" => lock_id) }

    assert_nothing_raised do
      ReleaseLock.validate_pending_state!(state, initial)
    end

    state.fetch(:journal)["status"] = "prepared"
    assert_raises(ReleaseStateError) do
      ReleaseLock.validate_pending_state!(state, initial)
    end
  end

  test "pending state must match its authenticated lock ID" do
    initial = phase_zero_journal
    lock_id = "a" * 64
    state = { lock_id:, journal: initial.merge("lock_id" => "b" * 64) }

    assert_raises(ReleaseStateError) do
      ReleaseLock.validate_pending_state!(state, initial)
    end
  end

  test "reconciliation completes after a crash following every external channel mutation" do
    CHANNEL_KEYS.each do |faulting_step|
      states = CHANNEL_KEYS.to_h { [ _1, "previous:#{_1}" ] }
      lock = FakeLock.new(base_journal)
      channels = CHANNEL_KEYS.map { channel(_1, "previous:#{_1}", "target:#{_1}", states, []) }
      promotion = MovingChannelPromotion.new(
        lock:, journal: lock.journal, channels:,
        fault_after: ->(step) { raise SimulatedCrash if step == faulting_step }
      )

      assert_raises(SimulatedCrash) { promotion.converge!("complete") }
      assert_equal channels.find { _1.key == faulting_step }.target, states.fetch(faulting_step)
      interrupted = lock.journal
      marker = interrupted.fetch("mutation_in_flight")
      assert_equal faulting_step, marker.dig("target", "channel")

      assert_raises(ReleaseStateError) do
        MovingChannelPromotion.new(lock:, journal: interrupted, channels: channels_for(states)).converge!("complete")
      end
      settle_release_mutation!(
        lock:, journal: interrupted, reconciling: true, token: marker.fetch("token")
      )
      resumed = MovingChannelPromotion.new(lock:, journal: lock.journal, channels: channels_for(states))
      assert resumed.converge!("complete")
      CHANNEL_KEYS.each { assert_equal "target:#{_1}", states.fetch(_1) }
      assert_equal "completed", lock.journal.fetch("status")
      assert_equal CHANNEL_KEYS.sort, lock.journal.fetch("completed_steps").keys.sort
    end
  end

  test "explicit rollback restores every previous channel" do
    states = {
      "registry_latest" => "sha256:new",
      "static_host" => "campfire-1.2.3",
      "github_public" => "draft"
    }
    lock = FakeLock.new(base_journal)
    promotion = MovingChannelPromotion.new(lock:, journal: lock.journal, channels: channels_for(states))

    assert promotion.converge!("rollback")

    assert_equal "sha256:old", states.fetch("registry_latest")
    assert_equal "campfire-1.2.2", states.fetch("static_host")
    assert_equal "draft", states.fetch("github_public")
    assert_equal "rolled_back", lock.journal.fetch("status")
  end

  test "rollback is refused after public publication" do
    states = {
      "registry_latest" => "sha256:new",
      "static_host" => "campfire-1.2.3",
      "github_public" => "public"
    }
    lock = FakeLock.new(base_journal)
    promotion = MovingChannelPromotion.new(lock:, journal: lock.journal, channels: channels_for(states))

    assert_raises(ReleaseStateError) { promotion.converge!("rollback") }
    assert_equal "sha256:new", states.fetch("registry_latest")
  end

  test "unexpected third-party channel value stops without mutation" do
    states = {
      "registry_latest" => "sha256:someone-else",
      "static_host" => "campfire-1.2.2",
      "github_public" => "draft"
    }
    lock = FakeLock.new(base_journal)
    writes = []
    channels = channels_for(states, writes:)

    assert_raises(ReleaseStateError) do
      MovingChannelPromotion.new(lock:, journal: lock.journal, channels:).converge!("complete")
    end
    assert_empty writes
  end

  test "moving channels compare immediately before write and re-read after settlement" do
    reads = [ "old", "raced" ]
    writes = []
    release_channel = ReleaseChannel.new(
      key: "registry", previous: "old", target: "new",
      read: -> { reads.shift || "raced" },
      write: ->(value, _runner) { writes << value }
    )

    error = assert_raises(ReleaseStateError) do
      MovingChannelPromotion.new(
        lock: FakeLock.new(base_journal), journal: base_journal, channels: [ release_channel ]
      ).converge!("complete")
    end
    assert_match "compare-before-write", error.message
    assert_empty writes
  end

  test "lock cleanup atomically retains a terminal tombstone before its fault point" do
    successful_status = stub(success?: true)
    commands = []
    Open3.stubs(:capture3).with do |*arguments|
      commands << arguments.last
      true
    end.returns([ "", "", successful_status ])
    observed_steps = []
    state = ReleaseLock.state_from_snapshot(history_snapshot(history_chain(1)), key: history_key)
    lock = ReleaseLock.new(
      "a" * 64, "/releases/.campfire-release.lock", "journal-key", initial_state: state
    )
    lock.stubs(:read_journal).returns({ "lock_id" => "a" * 64, "status" => "completed" })
    lock.stubs(:write_journal).returns(true)

    assert_raises(SimulatedCrash) do
      lock.release(fault_after: ->(step) {
        observed_steps << step
        raise SimulatedCrash
      })
    end

    assert_equal [ "lock_cleanup" ], observed_steps
    assert_includes commands.sole, "renameat2"
    assert_not_includes commands.sole, "rm /releases/.campfire-release.lock.released-"
  end

  test "lock cleanup refuses a nonterminal journal" do
    lock = ReleaseLock.new("a" * 64, "/releases/.campfire-release.lock", "journal-key")
    lock.stubs(:read_journal).returns({ "lock_id" => "a" * 64, "status" => "converging" })
    Open3.expects(:capture3).never

    assert_raises(ReleaseStateError) { lock.release }
  end

  test "immutable journal history publishes absent or complete bytes at every shell boundary" do
    ReleaseAtomicPublisher::HISTORY_BOUNDARIES.each do |boundary|
      Dir.mktmpdir("release-history-boundary") do |directory|
        source = "authenticated-history-entry\n"
        canonical = File.join(directory, "journal-history-entry.json")
        staging = File.join(directory, ".journal-history.stage-entry")

        assert_raises(ReleaseStateError, boundary) do
          local_publisher.publish_history_file!(
            canonical:, staging:, source:, fault_after: boundary
          )
        end

        linked = ReleaseAtomicPublisher::HISTORY_BOUNDARIES.index(boundary) >=
          ReleaseAtomicPublisher::HISTORY_BOUNDARIES.index("history_linked")
        assert_equal linked, File.exist?(canonical), boundary
        assert_equal source, File.binread(canonical) if linked
      end
    end
  end

  test "immutable journal history rejects truncated stdin before publication" do
    Dir.mktmpdir("release-history-truncated") do |directory|
      canonical = File.join(directory, "journal-history-entry.json")
      staging = File.join(directory, ".journal-history.stage-entry")
      source = "authenticated-history-entry\n"

      assert_raises(ReleaseStateError) do
        local_publisher.publish_history_file!(
          canonical:, staging:, source:, stream: source.byteslice(0, 8)
        )
      end

      assert_not File.exist?(canonical)
      assert_equal source.byteslice(0, 8), File.binread(staging)
    end
  end

  test "immutable journal publication never replaces an existing history path" do
    Dir.mktmpdir("release-history-no-clobber") do |directory|
      canonical = File.join(directory, "journal-history-entry.json")
      staging = File.join(directory, ".journal-history.stage-entry")
      File.write canonical, "concurrent-history\n"

      assert_raises(ReleaseStateError) do
        local_publisher.publish_history_file!(
          canonical:, staging:, source: "replacement-history\n"
        )
      end

      assert_equal "concurrent-history\n", File.binread(canonical)
      assert_not File.exist?(staging)
    end
  end

  test "the prior commit CAS injection cannot overwrite or silently adopt an injected history file" do
    Dir.mktmpdir("release-history-commit-race") do |directory|
      canonical = File.join(directory, "journal-history-entry.json")
      staging = File.join(directory, ".journal-history.stage-entry")
      source = "authenticated-history-entry\n"
      injected = "injected-history\n"
      publisher = ReleaseAtomicPublisher.new(capture: ->(command, stream) {
        portable = portable_release_shell(command).sub(
          "boundary commit_publication_checked;",
          "boundary commit_publication_checked; printf %s #{Shellwords.escape(injected)} > #{Shellwords.escape(canonical)};"
        )
        Open3.capture3("bash", "-c", portable, stdin_data: stream)
      })

      assert_raises(ReleaseStateError) do
        publisher.publish_history_file!(canonical:, staging:, source:)
      end

      assert_equal injected, File.binread(canonical)
      assert_equal source, File.binread(staging)
    end
  end

  test "authenticated history selects only the unique highest unbroken revision" do
    history = history_chain(3)
    state = ReleaseLock.state_from_snapshot(history_snapshot(history), key: history_key)

    assert_equal 2, state.dig(:journal, "journal_revision")
    assert_equal history.last.fetch(:current_digest), state.fetch(:history_digest)
    assert_equal history.map { _1.fetch(:name) }, state.fetch(:history).map { _1.fetch(:name) }
  end

  test "authenticated history rejects forks duplicate revisions and gaps without erasing evidence" do
    genesis = history_chain(1).sole
    first = build_history_revision(
      revision: 1, prior_digest: genesis.fetch(:current_digest), publisher_id: "1" * 32,
      status: "first-writer"
    )
    second = build_history_revision(
      revision: 1, prior_digest: genesis.fetch(:current_digest), publisher_id: "2" * 32,
      status: "second-writer"
    )
    forked = [ genesis, first, second ]

    error = assert_raises(ReleaseStateError) do
      ReleaseLock.state_from_snapshot(history_snapshot(forked), key: history_key)
    end
    assert_match "forked at revision 1", error.message
    assert_equal 3, forked.length

    duplicate = [ genesis, first, first.merge ]
    assert_raises(ReleaseStateError) do
      ReleaseLock.state_from_snapshot(history_snapshot(duplicate), key: history_key)
    end

    revision_two = build_history_revision(
      revision: 2, prior_digest: genesis.fetch(:current_digest), publisher_id: "3" * 32,
      status: "gap"
    )
    gap = assert_raises(ReleaseStateError) do
      ReleaseLock.state_from_snapshot(history_snapshot([ genesis, revision_two ]), key: history_key)
    end
    assert_match "contains a gap", gap.message
  end

  test "concurrent writers from one expected revision preserve both successors and expose a fork" do
    genesis = history_chain(1).sole
    successors = [
      build_history_revision(
        revision: 1, prior_digest: genesis.fetch(:current_digest),
        publisher_id: "1" * 32, status: "first-writer"
      ),
      build_history_revision(
        revision: 1, prior_digest: genesis.fetch(:current_digest),
        publisher_id: "2" * 32, status: "second-writer"
      )
    ]

    Dir.mktmpdir("release-history-fork") do |directory|
      threads = successors.each_with_index.map do |entry, index|
        Thread.new do
          local_publisher.publish_history_file!(
            canonical: File.join(directory, entry.fetch(:name)),
            staging: File.join(directory, ".journal-history.stage-#{index}"),
            source: entry.fetch(:source)
          )
        end
      end
      threads.each(&:value)

      successors.each { assert File.file?(File.join(directory, _1.fetch(:name))) }
      assert_raises(ReleaseStateError) do
        ReleaseLock.state_from_snapshot(
          history_snapshot([ genesis, *successors ]), key: history_key
        )
      end
    end
  end

  test "a post-verification injected history entry is authenticated before it can become authoritative" do
    history = history_chain(2)
    injected = history.last.dup
    injected_source = JSON.parse(injected.fetch(:source))
    injected_source.fetch("journal")["status"] = "injected"
    injected[:source] = JSON.pretty_generate(injected_source) << "\n"
    injected[:file_sha256] = Digest::SHA256.hexdigest(injected.fetch(:source))
    injected[:bytes] = injected.fetch(:source).bytesize

    assert_raises(ReleaseStateError) do
      ReleaseLock.state_from_snapshot(history_snapshot([ history.first, injected ]), key: history_key)
    end
  end

  test "durable state rejects a deleted or hard-linked phase-zero artifact" do
    history = history_chain(2)
    missing = history_snapshot(history)
    missing.fetch(:artifacts).pop

    error = assert_raises(ReleaseStateError) do
      ReleaseLock.state_from_snapshot(missing, key: history_key)
    end
    assert_match "missing, duplicated, or unexpected", error.message

    linked = history_snapshot(history)
    linked.fetch(:artifacts).first[:nlink] = 2
    error = assert_raises(ReleaseStateError) do
      ReleaseLock.state_from_snapshot(linked, key: history_key)
    end
    assert_match "differs from authenticated state", error.message
  end

  test "explicit reconciliation refuses to recreate wholly deleted authenticated history" do
    error = assert_raises(ReleaseStateError) do
      ReleaseLock.assert_new_state_allowed!(require_existing: true)
    end

    assert_match "surviving authenticated release history", error.message
    assert ReleaseLock.assert_new_state_allowed!(require_existing: false)
  end

  test "global catalog preflight inventories authenticated active and terminal local operations" do
    active = { lock_id: "b" * 64, journal: { "status" => "prepared" } }
    tombstone = { lock_id: "a" * 64, journal: { "status" => "completed" } }
    tombstone_name = "#{ReleaseLock::TOMBSTONE_PREFIX}#{'a' * 64}"
    successful = stub(success?: true)
    command = nil
    ReleaseLock.stubs(:capture_remote).with do |candidate|
      command = candidate
      true
    end.returns([ "ACTIVE\n#{tombstone_name}\n", "", successful ])
    ReleaseLock.expects(:read_state).with(
      ReleaseLock.lock_directory, key: history_key, invocation_id: "1" * 32,
      cleanup_staging: false
    ).returns(active)
    ReleaseLock.expects(:read_state).with(
      File.join(EXPORT_DEPLOY_LOCATION, tombstone_name), key: history_key,
      invocation_id: "1" * 32, cleanup_staging: false
    ).returns(tombstone)

    states = ReleaseLock.operation_states(key: history_key, invocation_id: "1" * 32)

    assert_equal [ tombstone, active ], states
    assert_includes command, ReleaseLock.lock_directory
    assert_includes command, ReleaseLock::TOMBSTONE_PREFIX
    assert_includes command, ReleaseInvocationLock::OWNER_PATH
  end

  test "remote journal commits use a pinned stable state-lock inode" do
    lock_command = ReleaseInvocationLock.state_lock_command
    owner_guard = ReleaseLock.live_owner_guard("a" * 32)
    holder_command = ReleaseInvocationLock.holder_command("a" * 32)

    assert_includes lock_command, "flock -x 8"
    assert_includes lock_command, "/proc/$$/fd/8"
    assert_includes lock_command, ReleaseInvocationLock::STATE_LOCK_PATH
    assert_includes owner_guard, ReleaseInvocationLock::LOCK_PATH
    assert_includes owner_guard, ReleaseInvocationLock::STATE_LOCK_PATH
    assert_includes owner_guard, "stat -Lc '%d:%i'"
    assert_includes holder_command, "/proc/$$/fd/9"
    assert_includes holder_command, "printf '%s %s %s"
  end

  test "phase-zero publication preserves absent or complete canonical state at every shell boundary" do
    ReleaseAtomicPublisher::DIRECTORY_BOUNDARIES.each do |boundary|
      Dir.mktmpdir("release-phase-zero-boundary") do |directory|
        canonical = File.join(directory, ".campfire-release.lock")
        staging = File.join(directory, ".campfire-release.pending")
        owner_id = "a" * 64
        history = build_history_revision(revision: 0, prior_digest: ReleaseJournal::GENESIS_DIGEST)
        source = history.fetch(:source)
        stage_name = ReleaseLock.journal_stage_name(
          lock_id: owner_id, invocation_id: "1" * 32, revision: 0, source:, key: history_key
        )
        artifacts = write_phase_zero_artifacts(directory)

        assert_raises(ReleaseStateError, boundary) do
          local_publisher.publish_directory!(
            canonical:, staging:, owner_id:, journal_name: history.fetch(:name),
            journal_stage_name: stage_name, journal_source: source, artifacts:, fault_after: boundary
          )
        end

        published = ReleaseAtomicPublisher::DIRECTORY_BOUNDARIES.index(boundary) >=
          ReleaseAtomicPublisher::DIRECTORY_BOUNDARIES.index("renamed")
        assert_equal published, File.directory?(canonical), boundary
        if published
          assert_equal source, File.binread(File.join(canonical, history.fetch(:name))), boundary
          assert_equal "#{owner_id}\n", File.binread(File.join(canonical, ReleaseLock::OWNER_FILENAME)), boundary
          assert_equal(
            [ ReleaseLock::OWNER_FILENAME, history.fetch(:name), *artifacts.keys ].sort,
            Dir.children(canonical).sort,
            boundary
          )
          artifacts.each do |name, path|
            published_path = File.join(canonical, name)
            assert_equal File.binread(path), File.binread(published_path), boundary
            assert_equal 1, File.stat(published_path).nlink, boundary
          end
        end
      end
    end
  end

  test "phase-zero publication rejects truncated stdin before canonical rename" do
    Dir.mktmpdir("release-phase-zero-truncated") do |directory|
      canonical = File.join(directory, ".campfire-release.lock")
      staging = File.join(directory, ".campfire-release.pending")
      owner_id = "a" * 64
      history = build_history_revision(revision: 0, prior_digest: ReleaseJournal::GENESIS_DIGEST)
      source = history.fetch(:source)
      stage_name = ReleaseLock.journal_stage_name(
        lock_id: owner_id, invocation_id: "1" * 32, revision: 0, source:, key: history_key
      )
      artifacts = write_phase_zero_artifacts(directory)

      assert_raises(ReleaseStateError) do
        local_publisher.publish_directory!(
          canonical:, staging:, owner_id:, journal_name: history.fetch(:name),
          journal_stage_name: stage_name, journal_source: source, artifacts:,
          stream: source.byteslice(0, source.bytesize / 2)
        )
      end

      assert_not File.exist?(canonical)
      assert File.directory?(staging)
    end
  end

  test "phase-zero publication rechecks absence after an injected commit race" do
    Dir.mktmpdir("release-phase-zero-commit-race") do |directory|
      canonical = File.join(directory, ".campfire-release.lock")
      staging = File.join(directory, ".campfire-release.pending")
      owner_id = "a" * 64
      history = build_history_revision(revision: 0, prior_digest: ReleaseJournal::GENESIS_DIGEST)
      source = history.fetch(:source)
      stage_name = ReleaseLock.journal_stage_name(
        lock_id: owner_id, invocation_id: "1" * 32, revision: 0, source:, key: history_key
      )
      artifacts = write_phase_zero_artifacts(directory)
      publisher = ReleaseAtomicPublisher.new(capture: ->(command, stream) {
        portable = portable_release_shell(command).sub(
          "boundary publication_checked;",
          "boundary publication_checked; mkdir #{Shellwords.escape(canonical)}; " \
            "printf raced > #{Shellwords.escape(File.join(canonical, 'newer'))};"
        )
        input = stream.respond_to?(:read) ? stream.read : stream
        Open3.capture3("bash", "-c", portable, stdin_data: input)
      }, rename_noreplace: ->(source, destination) {
        "mv #{Shellwords.escape(source)} #{Shellwords.escape(destination)}"
      })

      assert_raises(ReleaseStateError) do
        publisher.publish_directory!(
          canonical:, staging:, owner_id:, journal_name: history.fetch(:name),
          journal_stage_name: stage_name, journal_source: source, artifacts:
        )
      end

      assert_equal "raced", File.read(File.join(canonical, "newer"))
    end
  end

  test "phase-zero directory publication uses atomic no-replace rename" do
    Dir.mktmpdir("release-phase-zero-no-replace") do |directory|
      history = build_history_revision(revision: 0, prior_digest: ReleaseJournal::GENESIS_DIGEST)
      source = history.fetch(:source)
      command = nil
      failed = stub(success?: false)
      publisher = ReleaseAtomicPublisher.new(capture: ->(candidate, _stream) {
        command = candidate
        [ "", "injected stop", failed ]
      })

      assert_raises(ReleaseStateError) do
        publisher.publish_directory!(
          canonical: File.join(directory, "canonical"), staging: File.join(directory, "staging"),
          owner_id: "a" * 64, journal_name: history.fetch(:name),
          journal_stage_name: ReleaseLock.journal_stage_name(
            lock_id: "a" * 64, invocation_id: "1" * 32, revision: 0, source:, key: history_key
          ),
          journal_source: source, artifacts: write_phase_zero_artifacts(directory)
        )
      end

      assert_includes command, "renameat2"
      assert_includes command, "-rbase64"
      assert_not_includes command, "mv -T"
      _stdout, stderr, status = Open3.capture3("bash", "-n", "-c", command)
      assert status.success?, stderr
    end
  end

  test "phase-zero publication refuses local bytes that changed after journal authentication" do
    Dir.mktmpdir("release-phase-zero-local-race") do |directory|
      history = build_history_revision(revision: 0, prior_digest: ReleaseJournal::GENESIS_DIGEST)
      source = history.fetch(:source)
      artifacts = write_phase_zero_artifacts(directory)
      expected = ReleaseLock.phase_zero_artifact_metadata(phase_zero_journal)
      File.binwrite(
        artifacts.fetch(ReleaseLock::PHASE_ZERO_ARTIFACT_FILENAMES.fetch("export")), "raced"
      )
      publisher = ReleaseAtomicPublisher.new(capture: ->(*) { flunk "remote publication must not start" })

      error = assert_raises(ReleaseStateError) do
        publisher.publish_directory!(
          canonical: File.join(directory, "canonical"), staging: File.join(directory, "staging"),
          owner_id: "a" * 64, journal_name: history.fetch(:name),
          journal_stage_name: ReleaseLock.journal_stage_name(
            lock_id: "a" * 64, invocation_id: "1" * 32, revision: 0, source:, key: history_key
          ),
          journal_source: source, artifacts:, expected_artifacts: expected
        )
      end

      assert_match "changed before publication", error.message
    end
  end

  test "no-replace rename works on Linux and fails closed elsewhere" do
    Dir.mktmpdir("release-rename-noreplace") do |directory|
      source = File.join(directory, "source")
      destination = File.join(directory, "destination")
      FileUtils.mkdir source

      unless RUBY_PLATFORM.include?("linux")
        _stdout, stderr, status = Open3.capture3(
          "bash", "-c", atomic_no_replace_rename_command(source, destination)
        )
        assert_equal 70, status.exitstatus
        assert_includes stderr, "renameat2(RENAME_NOREPLACE) is unavailable"
        assert File.directory?(source)
        assert_not File.exist?(destination)
        next
      end

      assert system("bash", "-c", atomic_no_replace_rename_command(source, destination))
      assert_not File.exist?(source)
      assert File.directory?(destination)

      raced_source = File.join(directory, "raced-source")
      FileUtils.mkdir raced_source
      assert_not system(
        "bash", "-c", atomic_no_replace_rename_command(raced_source, destination),
        out: File::NULL, err: File::NULL
      )
      assert File.directory?(raced_source)
      assert File.directory?(destination)
    end
  end

  test "concurrent reconcilers cannot both acquire the process-scoped live-owner lock" do
    Dir.mktmpdir("release-live-owner") do |directory|
      path = File.join(directory, "live.lock")
      first_id = "1" * 32
      second_id = "2" * 32
      first = ReleaseInvocationLock.acquire(
        invocation_id: first_id, command: local_lock_holder_command(path, first_id)
      )

      contender = Thread.new do
        ReleaseInvocationLock.acquire(
          invocation_id: second_id, command: local_lock_holder_command(path, second_id)
        )
      rescue ReleaseStateError => error
        error
      end
      assert_match "Another release invocation", contender.value.message

      first.release
      second = ReleaseInvocationLock.acquire(
        invocation_id: second_id, command: local_lock_holder_command(path, second_id)
      )
      assert second.release
    ensure
      first&.release if first&.instance_variable_get(:@wait_thread)
    end
  end

  test "concurrent complete and rollback reconcilers cannot both mutate a channel" do
    Dir.mktmpdir("release-live-convergence") do |directory|
      path = File.join(directory, "live.lock")
      states = { "registry" => "old" }
      writes = []
      mutation_started = Queue.new
      continue_complete = Queue.new
      first_id = "1" * 32
      second_id = "2" * 32

      complete_thread = Thread.new do
        live_lock = ReleaseInvocationLock.acquire(
          invocation_id: first_id, command: local_lock_holder_command(path, first_id)
        )
        channel = channel("registry", "old", "new", states, writes)
        MovingChannelPromotion.new(
          lock: FakeLock.new(base_journal), journal: base_journal,
          channels: [ channel ],
          fault_after: ->(_step) { mutation_started << true; continue_complete.pop }
        ).converge!("complete")
        live_lock.release
      ensure
        live_lock&.release if live_lock&.instance_variable_get(:@wait_thread)
      end
      mutation_started.pop

      rollback_error = Thread.new do
        live_lock = ReleaseInvocationLock.acquire(
          invocation_id: second_id, command: local_lock_holder_command(path, second_id)
        )
        channel = channel("registry", "old", "new", states, writes)
        MovingChannelPromotion.new(
          lock: FakeLock.new(base_journal), journal: base_journal, channels: [ channel ]
        ).converge!("rollback")
      rescue ReleaseStateError => error
        error
      ensure
        live_lock&.release if live_lock&.instance_variable_get(:@wait_thread)
      end.value

      continue_complete << true
      complete_thread.value

      assert_match "Another release invocation", rollback_error.message
      assert_equal "new", states.fetch("registry")
      assert_equal [ [ "registry", "new" ] ], writes
    end
  end

  test "Interrupt kills and reaps a fenced mutation group before releasing its live-owner lock" do
    Dir.mktmpdir("release-mutation-interrupt") do |directory|
      paths = mutation_process_paths(directory)
      live_lock = acquire_test_live_lock(directory)
      lock = FakeLock.new(base_journal, invocation_lock: live_lock)
      target_path = File.join(directory, "target")
      release_order = Queue.new
      group_pid = nil
      release_channel = ReleaseChannel.new(
        key: "github_public", previous: "draft", target: "public",
        read: -> { File.exist?(target_path) ? "public" : "draft" },
        write: ->(_value, runner) {
          mutate!(*stubborn_mutation_command(paths, mode: "run"), runner:)
          File.write target_path, "arrived"
        }
      )
      worker = Thread.new do
        error = begin
          MovingChannelPromotion.new(
            lock:, journal: lock.journal, channels: [ release_channel ]
          ).converge!("complete")
          nil
        rescue Exception => raised
          raised
        ensure
          release_order << [ process_group_alive?(group_pid), live_lock.held? ] if group_pid
          live_lock.release
        end
        error
      end

      wait_for_mutation_processes paths
      group_pid, group_id, descendant_pid, descendant_group = mutation_process_ids(paths)
      assert_equal group_pid, group_id
      assert_equal group_id, descendant_group
      assert_raises(ReleaseStateError) { live_lock.release }
      assert live_lock.held?

      worker.raise Interrupt
      error = worker.value

      assert_instance_of Interrupt, error
      assert_equal [ false, true ], release_order.pop
      assert_process_group_gone group_pid
      assert_includes File.readlines(paths.fetch(:terminated), chomp: true).map(&:to_i), descendant_pid
      assert_not File.exist?(target_path)
      marker = lock.journal.fetch("mutation_in_flight")
      assert_equal "github_public", marker.dig("target", "channel")
      assert_raises(ReleaseStateError) do
        settle_release_mutation!(
          lock:, journal: lock.journal, reconciling: false, token: marker.fetch("token")
        )
      end
    ensure
      kill_test_process_group group_pid
      release_test_live_lock live_lock
    end
  end

  test "SignalException kills and reaps a capture group before releasing its live-owner lock" do
    Dir.mktmpdir("release-capture-signal") do |directory|
      paths = mutation_process_paths(directory)
      live_lock = acquire_test_live_lock(directory)
      release_order = Queue.new
      group_pid = nil
      worker = Thread.new do
        error = begin
          live_lock.capture_mutation!(
            *stubborn_mutation_command(paths, mode: "read"), stdin_data: "complete input"
          )
          nil
        rescue Exception => raised
          raised
        ensure
          release_order << [ process_group_alive?(group_pid), live_lock.held? ] if group_pid
          live_lock.release
        end
        error
      end

      wait_for_mutation_processes paths
      group_pid, group_id, descendant_pid, descendant_group = mutation_process_ids(paths)
      assert_equal group_pid, group_id
      assert_equal group_id, descendant_group
      assert_raises(ReleaseStateError) { live_lock.release }

      worker.raise SignalException.new("TERM")
      error = worker.value

      assert_instance_of SignalException, error
      assert_equal "SIGTERM", error.message
      assert_equal [ false, true ], release_order.pop
      assert_process_group_gone group_pid
      assert_includes File.readlines(paths.fetch(:terminated), chomp: true).map(&:to_i), descendant_pid
    ensure
      kill_test_process_group group_pid
      release_test_live_lock live_lock
    end
  end

  test "live-owner release cannot pass a mutation launch before registration" do
    Dir.mktmpdir("release-mutation-registration") do |directory|
      launch_started = Queue.new
      continue_launch = Queue.new
      release_entered = Queue.new
      popen3 = Open3.method(:popen3)
      mutation_popen3 = lambda do |*command, **options|
        streams = popen3.call(*command, **options)
        launch_started << streams.last.pid
        continue_launch.pop
        streams
      end
      live_lock = acquire_test_live_lock(directory, mutation_popen3:)
      original_begin_release = live_lock.method(:begin_release!)
      live_lock.define_singleton_method(:begin_release!) do
        release_entered << true
        original_begin_release.call
      end
      worker = Thread.new do
        live_lock.capture_mutation!(RbConfig.ruby, "-e", "sleep 10")
      rescue Exception => error
        error
      end

      group_pid = launch_started.pop
      release_attempt = Thread.new do
        live_lock.release
      rescue ReleaseStateError => error
        error
      end
      release_entered.pop
      continue_launch << true

      error = release_attempt.value
      assert_instance_of ReleaseStateError, error
      assert_match "mutation process groups remain active", error.message
      assert live_lock.held?

      worker.raise Interrupt
      assert_instance_of Interrupt, worker.value
      assert_process_group_gone group_pid
      assert live_lock.release
    ensure
      continue_launch << true
      worker&.raise(Interrupt) if worker&.alive?
      worker&.join
      kill_test_process_group group_pid
      release_test_live_lock live_lock
    end
  end

  test "capture input failures terminate the complete mutation process group" do
    Dir.mktmpdir("release-capture-input-error") do |directory|
      paths = mutation_process_paths(directory)
      live_lock = acquire_test_live_lock(directory)
      failure_gate = Queue.new
      worker = Thread.new do
        live_lock.capture_mutation!(
          *stubborn_mutation_command(paths, mode: "read"),
          stdin_data: ControlledFailureInput.new(failure_gate)
        )
      rescue Exception => error
        error
      end

      wait_for_mutation_processes paths
      group_pid, = mutation_process_ids(paths)
      failure_gate << true
      error = worker.value

      assert_instance_of IOError, error
      assert_equal "injected mutation input failure", error.message
      assert_process_group_gone group_pid
      assert live_lock.held?
      assert live_lock.release
    ensure
      kill_test_process_group group_pid
      release_test_live_lock live_lock
    end
  end

  test "capture read failures terminate the complete mutation process group" do
    Dir.mktmpdir("release-capture-read-error") do |directory|
      paths = mutation_process_paths(directory)
      failure_gate = Queue.new
      popen3 = Open3.method(:popen3)
      mutation_popen3 = lambda do |*command, **options|
        stdin, stdout, stderr, waiter = popen3.call(*command, **options)
        [ stdin, ControlledFailureOutput.new(stdout, failure_gate), stderr, waiter ]
      end
      live_lock = acquire_test_live_lock(directory, mutation_popen3:)
      worker = Thread.new do
        live_lock.capture_mutation!(*stubborn_mutation_command(paths, mode: "run"))
      rescue Exception => error
        error
      end

      wait_for_mutation_processes paths
      group_pid, = mutation_process_ids(paths)
      failure_gate << true
      error = worker.value

      assert_instance_of IOError, error
      assert_equal "injected mutation output failure", error.message
      assert_process_group_gone group_pid
      assert live_lock.held?
      assert live_lock.release
    ensure
      kill_test_process_group group_pid
      release_test_live_lock live_lock
    end
  end

  test "a successful mutation leader cannot leave a descendant running or settle its journal" do
    Dir.mktmpdir("release-mutation-descendant") do |directory|
      paths = mutation_process_paths(directory)
      live_lock = acquire_test_live_lock(directory)
      lock = FakeLock.new(base_journal, invocation_lock: live_lock)
      release_channel = ReleaseChannel.new(
        key: "github_public", previous: "draft", target: "public",
        read: -> { "draft" },
        write: ->(_value, runner) {
          mutate!(*stubborn_mutation_command(paths, mode: "exit"), runner:)
        }
      )

      error = assert_raises(ReleaseMutationUnsettled) do
        MovingChannelPromotion.new(
          lock:, journal: lock.journal, channels: [ release_channel ]
        ).converge!("complete")
      end
      group_pid, = mutation_process_ids(paths)

      assert_match "outlived its direct child", error.message
      assert_process_group_gone group_pid
      marker = lock.journal.fetch("mutation_in_flight")
      assert_equal "github_public", marker.dig("target", "channel")
      assert_raises(ReleaseStateError) do
        ReleaseMutationFence.ensure_settled! lock.journal
      end
      assert live_lock.release
    ensure
      kill_test_process_group group_pid
      release_test_live_lock live_lock
    end
  end

  test "a successful capture leader cannot leave a descendant running" do
    Dir.mktmpdir("release-capture-descendant") do |directory|
      paths = mutation_process_paths(directory)
      live_lock = acquire_test_live_lock(directory)

      error = assert_raises(ReleaseStateError) do
        live_lock.capture_mutation!(*stubborn_mutation_command(paths, mode: "exit"))
      end
      group_pid, = mutation_process_ids(paths)

      assert_match "outlived its direct child", error.message
      assert_process_group_gone group_pid
      assert live_lock.held?
      assert live_lock.release
    ensure
      kill_test_process_group group_pid
      release_test_live_lock live_lock
    end
  end

  test "live-lock loss between channel check and write kills the child and requires settled reconciliation" do
    Dir.mktmpdir("release-live-mutation") do |directory|
      holder_path = File.join(directory, "live.lock")
      started_path = File.join(directory, "started")
      target_path = File.join(directory, "target")
      live_lock = ReleaseInvocationLock.acquire(
        invocation_id: "1" * 32,
        command: local_lock_holder_command(holder_path, "1" * 32)
      )
      lock = FakeLock.new(base_journal, invocation_lock: live_lock)
      child = <<~RUBY
        File.write ARGV.fetch(0), Process.pid
        sleep 10
        File.write ARGV.fetch(1), "arrived"
      RUBY
      release_channel = ReleaseChannel.new(
        key: "github_public", previous: "draft", target: "public",
        read: -> { File.exist?(target_path) ? "public" : "draft" },
        write: ->(_value, runner) {
          mutate! RbConfig.ruby, "-e", child, started_path, target_path, runner:
        }
      )
      result = Thread.new do
        MovingChannelPromotion.new(
          lock:, journal: lock.journal, channels: [ release_channel ]
        ).converge!("complete")
      rescue StandardError => error
        error
      end

      Timeout.timeout(5) { sleep 0.01 until File.size?(started_path) }
      group_pid = File.read(started_path).to_i
      terminate_test_live_lock_holder live_lock
      error = result.value

      assert_instance_of ReleaseLiveLockLost, error
      assert_process_group_gone group_pid
      assert_not File.exist?(target_path)
      marker = lock.journal.fetch("mutation_in_flight")
      assert_equal "github_public", marker.dig("target", "channel")
      assert_raises(ReleaseStateError) do
        MovingChannelPromotion.new(
          lock: FakeLock.new(lock.journal), journal: lock.journal, channels: [ release_channel ]
        ).converge!("complete")
      end
    ensure
      kill_test_process_group group_pid
      release_test_live_lock live_lock
    end
  end

  test "live-lock loss before immutable history linking kills the publishing child" do
    Dir.mktmpdir("release-live-journal") do |directory|
      holder_path = File.join(directory, "live.lock")
      started_path = File.join(directory, "started")
      canonical = File.join(directory, "journal-history-entry.json")
      staging = File.join(directory, ".journal-history.stage-entry")
      source = "authenticated-history-entry\n"
      live_lock = ReleaseInvocationLock.acquire(
        invocation_id: "1" * 32,
        command: local_lock_holder_command(holder_path, "1" * 32)
      )
      publisher = ReleaseAtomicPublisher.new(capture: ->(command, stream) {
        portable = portable_release_shell(command).sub(
          "boundary publication_checked;",
          "boundary publication_checked; printf '%s\\n' \"$$\" > #{Shellwords.escape(started_path)}; sleep 10;"
        )
        live_lock.capture_mutation!("bash", "-c", portable, stdin_data: stream)
      })
      result = Thread.new do
        publisher.publish_history_file!(canonical:, staging:, source:)
      rescue StandardError => error
        error
      end

      Timeout.timeout(5) { sleep 0.01 until File.size?(started_path) }
      group_pid = File.read(started_path).to_i
      terminate_test_live_lock_holder live_lock

      assert_instance_of ReleaseLiveLockLost, result.value
      assert_process_group_gone group_pid
      assert_not File.exist?(canonical)
    ensure
      kill_test_process_group group_pid
      release_test_live_lock live_lock
    end
  end

  test "only explicit reconciliation with the authenticated token settles an in-flight mutation" do
    journal = base_journal.merge(
      "mutation_in_flight" => {
        "token" => "a" * 32,
        "kind" => "moving_channel",
        "target" => { "channel" => "github_public", "value" => "public" },
        "started_at" => "2026-08-01T12:00:00Z"
      }
    )
    lock = FakeLock.new(journal)

    assert_raises(ReleaseStateError) do
      settle_release_mutation!(lock:, journal:, reconciling: false, token: "a" * 32)
    end
    assert_raises(ReleaseStateError) do
      settle_release_mutation!(lock:, journal:, reconciling: true, token: "b" * 32)
    end
    assert settle_release_mutation!(lock:, journal:, reconciling: true, token: "a" * 32)
    assert_nil lock.journal["mutation_in_flight"]
    assert_equal "a" * 32, lock.journal.fetch("settled_mutations").sole.fetch("token")
  end

  test "a launched child that exits without verified settlement leaves the mutation unresolved" do
    states = { "github_public" => "draft" }
    lock = FakeLock.new(base_journal, mutation_status: stub(success?: false))
    release_channel = ReleaseChannel.new(
      key: "github_public", previous: "draft", target: "public",
      read: -> { states.fetch("github_public") },
      write: ->(_value, runner) { mutate! "gh", "release", "edit", runner: }
    )

    assert_raises(ReleaseMutationUnsettled) do
      MovingChannelPromotion.new(
        lock:, journal: lock.journal, channels: [ release_channel ]
      ).converge!("complete")
    end
    assert_equal "github_public", lock.journal.dig("mutation_in_flight", "target", "channel")
    assert_equal "draft", states.fetch("github_public")
  end

  test "authenticated phase-zero notes can be recovered on another host" do
    journal = phase_zero_journal
    assert_equal journal.fetch("release_notes"), authenticated_release_notes(journal)

    journal["release_notes"] = "different notes"
    assert_raises(ReleaseStateError) { authenticated_release_notes(journal) }
  end

  test "reconciliation rematerializes the exact authenticated phase-zero artifacts" do
    state = ReleaseLock.state_from_snapshot(history_snapshot(history_chain(2)), key: history_key)
    sources = phase_zero_artifact_sources
    commands = []
    ReleaseLock.stubs(:receive_remote_artifact!).with do |command, destination, expected|
      commands << command
      source = sources.values.find { Digest::SHA256.hexdigest(_1) == expected.fetch(:digest) }
      File.binwrite destination, source
      true
    end

    Dir.mktmpdir("release-phase-zero-materialize") do |directory|
      export = File.join(directory, "campfire-1.2.3.zip")
      checksum = "#{export}.sha256"

      assert ReleaseLock.materialize_phase_zero_artifacts!(
        state:, destinations: { "export" => export, "checksum" => checksum },
        invocation_id: "1" * 32
      )

      assert_equal sources.fetch("export"), File.binread(export)
      assert_equal sources.fetch("checksum"), File.binread(checksum)
      assert_equal 2, commands.length
      commands.each do |command|
        assert_includes command, "/proc/$$/fd/7"
        assert_includes command, "stat -Lc %h"
        assert_includes command, "sha256sum"
      end
    end
  end

  test "ordinary invocation refuses public state and existing tags without authenticated reconciliation" do
    assert_raises(ReleaseStateError) do
      validate_release_entry!(**release_entry_arguments(release_public: true))
    end
    assert_raises(ReleaseStateError) do
      validate_release_entry!(**release_entry_arguments(existing_tag_sha: "c" * 40))
    end
    assert_raises(ReleaseStateError) do
      validate_release_entry!(**release_entry_arguments(
        resuming: true, existing_tag_sha: "c" * 40
      ))
    end
  end

  test "a new release rejects stale main even when its SHA is an ancestor" do
    error = assert_raises(ReleaseStateError) do
      validate_release_entry!(**release_entry_arguments(
        remote_main_sha: "d" * 40, release_sha_ancestor_of_main: true
      ))
    end

    assert_match "new release must start from current main", error.message
  end

  test "interrupted reconciliation accepts its authenticated ancestor after main advances" do
    assert validate_release_entry!(**release_entry_arguments(
      reconciling: true, reconcile_sha: "c" * 40,
      existing_tag_sha: "c" * 40, remote_main_sha: "d" * 40,
      release_sha_ancestor_of_main: true
    ))
  end

  test "reconciliation rejects a wrong SHA diverged history and tag mismatch" do
    wrong_sha = assert_raises(ReleaseStateError) do
      validate_release_entry!(**release_entry_arguments(
        reconciling: true, reconcile_sha: "d" * 40
      ))
    end
    assert_match "RELEASE_RECONCILE_SHA must equal HEAD", wrong_sha.message

    diverged = assert_raises(ReleaseStateError) do
      validate_release_entry!(**release_entry_arguments(
        reconciling: true, reconcile_sha: "c" * 40,
        remote_main_sha: "d" * 40, release_sha_ancestor_of_main: false
      ))
    end
    assert_match "remain an ancestor of current main", diverged.message

    tag_mismatch = assert_raises(ReleaseStateError) do
      validate_release_entry!(**release_entry_arguments(
        reconciling: true, reconcile_sha: "c" * 40,
        existing_tag_sha: "e" * 40
      ))
    end
    assert_match "signed release tag does not point at HEAD", tag_mismatch.message
  end

  test "post-workflow freshness permits the authenticated ancestor during reconciliation" do
    sha = "c" * 40
    remote_main = "d" * 40
    stubs(:run!).with("git", "fetch", "origin", "main", "--tags")
    stubs(:capture!).with("git", "rev-parse", "origin/main").returns(remote_main)
    stubs(:capture!).with("git", "tag", "--list", "v*").returns("")
    stubs(:capture!).with(
      "git", "rev-list", "-n", "1", "v1.2.3", allow_failure: true
    ).returns(sha)
    stubs(:git_ancestor?).with(sha, remote_main).returns(true)
    stubs(:remote_tag_sha).with("origin", "v1.2.3").returns(sha)
    stubs(:verify_tag_signature!).with("v1.2.3", "f" * 40)

    assert revalidate_release_source!(
      remote: "origin", sha:, version: "1.2.3", tag: "v1.2.3",
      signer_fingerprint: "f" * 40, reconciling: true
    )
  end

  test "a phase-zero journal acquired by this invocation is validated without being mistaken for stale state" do
    expected_release = phase_zero_journal.fetch("release")
    state = { journal: phase_zero_journal }

    assert_raises(ReleaseStateError) do
      validate_durable_release_entry!(
        state:, expected_release:, reconciling: false, settled_mutation_token: ""
      )
    end
    assert validate_durable_release_entry!(
      state:, expected_release:, reconciling: false, settled_mutation_token: "",
      expected_anchor_set: test_anchor_set, acquired: true
    )

    assert_raises(ReleaseStateError) do
      validate_durable_release_entry!(
        state:, expected_release:, reconciling: false, settled_mutation_token: "",
        expected_anchor_set: test_anchor_set.merge("sha256" => "e" * 64), acquired: true
      )
    end

    state.fetch(:journal).fetch("release")["sha"] = "d" * 40
    assert_raises(ReleaseStateError) do
      validate_durable_release_entry!(
        state:, expected_release:, reconciling: false, settled_mutation_token: "", acquired: true
      )
    end
  end

  test "resume and reconciliation modes are mutually exclusive" do
    assert_raises(ReleaseStateError) do
      validate_release_entry!(**release_entry_arguments(
        reconciling: true, resuming: true,
        reconcile_sha: "c" * 40,
        existing_tag_sha: "c" * 40
      ))
    end
  end

  test "reconciliation never dispatches a replacement same-SHA workflow" do
    assert_raises(ReleaseStateError) do
      workflow_dispatch_required!(
        reconciling: true, candidates: [], phase_previously_started: true
      )
    end
    assert_not workflow_dispatch_required!(reconciling: true, candidates: [ 123 ])
    assert workflow_dispatch_required!(reconciling: false, candidates: [])
    assert workflow_dispatch_required!(
      reconciling: true, candidates: [], phase_previously_started: false,
      release_public: false
    )
    assert_raises(ReleaseStateError) do
      workflow_dispatch_required!(
        reconciling: true, candidates: [], phase_previously_started: false,
        release_public: true
      )
    end
  end

  test "reconciliation does not rerun a failed original workflow" do
    operation_nonce = "9" * 64
    run = [ {
      "databaseId" => 123, "headBranch" => "main", "headSha" => "c" * 40,
      "event" => "workflow_dispatch", "status" => "completed", "conclusion" => "failure",
      "displayTitle" => workflow_dispatch_title(
        tag: "v1.2.3", sha: "c" * 40, operation_nonce:
      )
    } ]
    status = stub(success?: true)
    Open3.stubs(:capture3).returns([ JSON.generate(run), "", status ])

    output = capture_io do
      assert_raises(SystemExit) do
        wait_for_workflow!(
          repository: "basecamp/once-campfire", event: "workflow_dispatch",
          sha: "c" * 40, branch: "main", release_tag: "v1.2.3", operation_nonce:,
          allow_rerun: false
        )
      end
    end
    assert_match "will not rebuild", output.last
  end

  test "ordinary workflow retry waits for the incremented attempt instead of accepting stale failure" do
    operation_nonce = "9" * 64
    run = [ {
      "attempt" => 1, "databaseId" => 123, "headBranch" => "main", "headSha" => "c" * 40,
      "event" => "workflow_dispatch", "status" => "completed", "conclusion" => "failure",
      "displayTitle" => workflow_dispatch_title(
        tag: "v1.2.3", sha: "c" * 40, operation_nonce:
      )
    } ]
    responses = [
      JSON.generate(run),
      JSON.generate("attempt" => 1, "status" => "completed", "conclusion" => "failure"),
      JSON.generate("attempt" => 2, "status" => "completed", "conclusion" => "success")
    ]
    stubs(:capture!).returns(*responses)
    expects(:run!).with("gh", "run", "rerun", "123", "--repo", "basecamp/once-campfire")
    stubs(:sleep)

    assert_equal 123, wait_for_workflow!(
      repository: "basecamp/once-campfire", event: "workflow_dispatch",
      sha: "c" * 40, branch: "main", release_tag: "v1.2.3", operation_nonce:
    )
  end

  test "workflow evidence is bound to the original run attempt" do
    operation_nonce = "9" * 64
    metadata = {
      "attempt" => 2, "conclusion" => "success", "databaseId" => 123,
      "event" => "workflow_dispatch", "headBranch" => "main", "headSha" => "c" * 40,
      "status" => "completed", "workflowName" => PUBLISH_WORKFLOW_NAME,
      "displayTitle" => workflow_dispatch_title(
        tag: "v1.2.3", sha: "c" * 40, operation_nonce:
      )
    }
    status = stub(success?: true)
    Open3.stubs(:capture3).returns([ JSON.generate(metadata), "", status ])

    assert_equal metadata, validated_workflow_run!(
      repository: "basecamp/once-campfire", run_id: 123, sha: "c" * 40,
      release_tag: "v1.2.3", operation_nonce:, attempt: 2
    )
    output = capture_io do
      assert_raises(SystemExit) do
        validated_workflow_run!(
          repository: "basecamp/once-campfire", run_id: 123, sha: "c" * 40,
          release_tag: "v1.2.3", operation_nonce:, attempt: 1
        )
      end
    end
    assert_match "run attempt changed", output.last
  end

  test "workflow selection requires one unique operation nonce match" do
    operation_nonce = "9" * 64
    candidate = {
      "attempt" => 1, "conclusion" => nil, "databaseId" => 123,
      "displayTitle" => workflow_dispatch_title(
        tag: "v1.2.3", sha: "c" * 40, operation_nonce:
      ),
      "event" => "workflow_dispatch", "headBranch" => "main", "headSha" => "c" * 40,
      "status" => "queued"
    }
    stubs(:capture!).returns(JSON.generate([ candidate, candidate.merge("databaseId" => 124) ]))

    output = capture_io do
      assert_raises(SystemExit) do
        wait_for_workflow!(
          repository: "basecamp/once-campfire", event: "workflow_dispatch",
          sha: "c" * 40, branch: "main", release_tag: "v1.2.3", operation_nonce:
        )
      end
    end
    assert_match "more than one", output.last
  end

  test "promotion keeps Object Lock release identity separate from workflow run identity" do
    release = phase_zero_journal.fetch("release")
    workflow_run = {
      "run_id" => "123", "run_attempt" => "2", "operation_nonce" => "9" * 64
    }
    contract = release_promotion_contract(
      release:, anchor_set: test_anchor_set, workflow_run:,
      artifacts: { "workflow_evidence_sha256" => "e" * 64 },
      channels: { "github_public" => { "target" => "public" } }
    )

    assert_equal %w[ repository sha tag version ], contract.fetch("release").keys.sort
    assert_equal release, contract.fetch("release")
    assert_equal workflow_run, contract.fetch("workflow_run")
    assert_not contract.fetch("release").key?("workflow_run_id")
  end

  test "pending workflow evidence resumes after every retention promotion fault" do
    Dir.mktmpdir("release-evidence-promotion") do |directory|
      source = "retained evidence\n"
      File.binwrite File.join(directory, "release-evidence.json"), source
      contract = {
        "format_version" => 1,
        "operation_nonce" => "9" * 64,
        "run_id" => "123",
        "run_attempt" => "1",
        "files" => {
          "release-evidence.json" => {
            "bytes" => source.bytesize, "sha256" => Digest::SHA256.hexdigest(source)
          }
        }
      }

      %w[ after_first_anchor after_both_anchors before_journal_promotion ].each do |boundary|
        lock = FakeLock.new(phase_zero_journal.merge("lock_id" => "a" * 64))
        anchors = Object.new
        anchors.define_singleton_method(:retain_pending_evidence!) do |journal:, directory:, fault_after:|
          raise "pending contract was not durable before retention" unless
            journal["workflow_evidence_pending"] == contract && !journal.key?("workflow_evidence")
          raise "wrong evidence source" unless File.binread(File.join(directory, "release-evidence.json")) == source

          fault_after.call "after_first_anchor"
          fault_after.call "after_both_anchors"
          true
        end

        assert_raises(SimulatedCrash, boundary) do
          retain_and_promote_workflow_evidence!(
            lock:, journal: lock.journal, anchors:, directory:, contract:,
            fault_after: ->(observed) { raise SimulatedCrash if observed == boundary }
          )
        end
        assert_equal contract, lock.journal.fetch("workflow_evidence_pending")
        assert_nil lock.journal["workflow_evidence"]

        assert retain_and_promote_workflow_evidence!(
          lock:, journal: lock.journal, anchors:, directory:, contract:
        )
        assert_equal contract, lock.journal.fetch("workflow_evidence")
        assert_not lock.journal.key?("workflow_evidence_pending")
      end
    end
  end

  test "workflow evidence enforces exact schemas hashes files and operation nonce" do
    Dir.mktmpdir("release-evidence-valid") do |directory|
      attributes = write_valid_release_evidence(directory)
      evidence = validate_release_evidence!(**attributes)
      assert_equal WORKFLOW_EVIDENCE_FORMAT_VERSION, evidence.fetch("format_version")
      assert_equal "9" * 64, evidence.fetch("operation_nonce")

      contract = workflow_evidence_contract(
        directory:, run_id: attributes.fetch(:run_id), run_attempt: attributes.fetch(:run_attempt),
        operation_nonce: attributes.fetch(:operation_nonce)
      )
      assert_equal RELEASE_EVIDENCE_INVENTORY, contract.fetch("files").keys.sort
      assert contract.fetch("files").values.all? { _1.fetch("sha256").match?(/\A[0-9a-f]{64}\z/) }
    end

    [
      :missing_field, :extra_field, :nested_field, :tampered_file, :missing_file,
      :extra_inventory_file, :wrong_nonce, :manifest_binding, :runtime_binding,
      :container_validation_binding
    ].each do |fault|
      Dir.mktmpdir("release-evidence-#{fault}") do |directory|
        attributes = write_valid_release_evidence(directory)
        evidence_path = File.join(directory, "release-evidence.json")
        case fault
        when :missing_field
          evidence = JSON.parse(File.binread(evidence_path))
          evidence.delete "promotion_requirements_sha256"
          File.binwrite evidence_path, JSON.pretty_generate(evidence) << "\n"
        when :extra_field
          evidence = JSON.parse(File.binread(evidence_path))
          evidence["unexpected"] = true
          File.binwrite evidence_path, JSON.pretty_generate(evidence) << "\n"
        when :nested_field
          recovery_path = File.join(directory, "recovery-amd64.json")
          recovery = JSON.parse(File.binread(recovery_path))
          recovery.fetch("signed_provenance").delete "source_ref"
          File.binwrite recovery_path, JSON.pretty_generate(recovery) << "\n"
          refresh_release_evidence_file_hash! directory, "recovery-amd64.json"
        when :tampered_file
          File.binwrite File.join(directory, "index-provenance.bundle.jsonl"), "tampered\n"
        when :missing_file
          FileUtils.rm_f File.join(directory, "upgrade-recovery-arm64.json")
        when :extra_inventory_file
          File.binwrite File.join(directory, "unexpected.json"), "{}\n"
        when :wrong_nonce
          attributes[:operation_nonce] = "8" * 64
        when :manifest_binding, :runtime_binding, :container_validation_binding
          recovery_path = File.join(directory, "recovery-amd64.json")
          recovery = JSON.parse(File.binread(recovery_path))
          case fault
          when :manifest_binding
            recovery["target_manifest_digest"] = "sha256:#{'0' * 64}"
          when :runtime_binding
            recovery["runtime_binding"] = "single-build-multi-export"
          when :container_validation_binding
            recovery["container_validation_sha256"] = "0" * 64
          end
          File.binwrite recovery_path, JSON.pretty_generate(recovery) << "\n"
          refresh_release_evidence_file_hash! directory, "recovery-amd64.json"
        end

        assert_raises(ReleaseStateError, fault) { validate_release_evidence!(**attributes) }
      end
    end
  end

  test "workflow evidence producer emits the exact release driver schema" do
    Dir.mktmpdir("release-evidence-producer") do |runner_temp|
      directory = File.join(runner_temp, "release-evidence")
      FileUtils.mkdir directory
      attributes = write_valid_release_evidence(directory)
      FileUtils.rm File.join(directory, "release-evidence.json")
      FileUtils.mkdir File.join(runner_temp, "digests")
      File.binwrite File.join(runner_temp, "digests/digest-amd64"), "sha256:#{'a' * 64}\n"
      File.binwrite File.join(runner_temp, "digests/digest-arm64"), "sha256:#{'b' * 64}\n"
      workflow = YAML.safe_load(Rails.root.join(".github/workflows/publish-image.yml").read, aliases: false)
      producer = workflow.dig("jobs", "manifest", "steps").find do |step|
        step["name"] == "Record release evidence"
      end.fetch("run")
      environment = {
        "RUNNER_TEMP" => runner_temp,
        "GITHUB_REPOSITORY" => attributes.fetch(:repository),
        "GITHUB_RUN_ID" => attributes.fetch(:run_id).to_s,
        "GITHUB_RUN_ATTEMPT" => attributes.fetch(:run_attempt).to_s,
        "OPERATION_NONCE" => attributes.fetch(:operation_nonce),
        "RELEASE_SHA" => attributes.fetch(:sha),
        "RELEASE_TAG" => attributes.fetch(:tag),
        "CANONICAL_IMAGE" => attributes.fetch(:image),
        "INDEX_DIGEST" => "sha256:#{'c' * 64}",
        "STAGING_REFERENCE" => "#{attributes.fetch(:image)}:staging-#{attributes.fetch(:run_id)}-#{attributes.fetch(:run_attempt)}"
      }

      _stdout, stderr, status = Open3.capture3(environment, "bash", "-c", producer)

      assert status.success?, stderr
      assert validate_release_evidence!(**attributes)
      canonical_promotion = {
        "authority" => "bin/release",
        "required_release_driver_evidence" => [
          "live no-overwrite registry probe bound to immutable aliases",
          "dual Object Lock anchor receipts for the authenticated journal head"
        ],
        "workflow_scope" => "attempt-scoped staging only"
      }
      assert_equal JSON.generate(canonical_promotion) << "\n",
        File.binread(File.join(directory, "promotion-requirements.json"))
    end
  end

  test "unexpected public GitHub release state is rejected unless an authenticated transition explains it" do
    release = { "isDraft" => false, "isPrerelease" => false }
    assert_raises(ReleaseStateError) do
      validate_observed_github_release_state!(journal: phase_zero_journal, release:)
    end

    prepared = phase_zero_journal.merge(
      "channels" => {
        "github_public" => {
          "kind" => "github_release", "previous" => "draft", "target" => "public"
        }
      },
      "mutation_in_flight" => {
        "target" => { "channel" => "github_public", "value" => "public" }
      }
    )
    assert validate_observed_github_release_state!(journal: prepared, release:)

    completed = prepared.except("mutation_in_flight").merge(
      "completed_steps" => { "github_public" => { "value" => "public" } }
    )
    assert_raises(ReleaseStateError) do
      validate_observed_github_release_state!(
        journal: completed, release: release.merge("isDraft" => true)
      )
    end
  end

  test "a draft becoming public after initial capture is rejected before promotion preparation" do
    Dir.mktmpdir("release-github-public-race") do |directory|
      notes_file = File.join(directory, "notes.md")
      asset = File.join(directory, "campfire-1.2.3.zip")
      File.binwrite notes_file, "release notes\n"
      File.binwrite asset, "release bytes\n"
      draft = github_release_metadata(notes_file, [ asset ], draft: true)
      public_release = github_release_metadata(notes_file, [ asset ], draft: false)
      stubs(:github_release).with("basecamp/once-campfire", "v1.2.3")
        .returns(draft, public_release)

      assert_equal "draft", authenticated_github_release_state!(
        journal: phase_zero_journal, repository: "basecamp/once-campfire", tag: "v1.2.3",
        notes_file:, asset_paths: [ asset ]
      )
      error = assert_raises(ReleaseStateError) do
        authenticated_github_release_state!(
          journal: phase_zero_journal, repository: "basecamp/once-campfire", tag: "v1.2.3",
          notes_file:, asset_paths: [ asset ]
        )
      end
      assert_match "before authenticated promotion preparation", error.message
    end
  end

  test "a publication raced between compare and the fenced mutation boundary is rejected" do
    Dir.mktmpdir("release-github-boundary-race") do |directory|
      notes_file = File.join(directory, "notes.md")
      asset = File.join(directory, "campfire-1.2.3.zip")
      File.binwrite notes_file, "release notes\n"
      File.binwrite asset, "release bytes\n"
      draft = github_release_metadata(notes_file, [ asset ], draft: true)
      public_release = github_release_metadata(notes_file, [ asset ], draft: false)
      stubs(:github_release).with("basecamp/once-campfire", "v1.2.3")
        .returns(draft, draft, public_release)
      journal = phase_zero_journal.merge(
        "channels" => {
          "github_public" => {
            "kind" => "github_release", "previous" => "draft", "target" => "public"
          }
        },
        "status" => "prepared", "outcome" => "complete", "completed_steps" => {}
      )
      lock = FakeLock.new(journal, mutation_status: stub(success?: true))
      channel = ReleaseChannel.new(
        key: "github_public", previous: "draft", target: "public",
        read: -> {
          authenticated_github_release_state!(
            journal: lock.journal, repository: "basecamp/once-campfire", tag: "v1.2.3",
            notes_file:, asset_paths: [ asset ]
          )
        },
        write: ->(_target, runner) {
          validate_github_publication_boundary!(
            journal: lock.journal, repository: "basecamp/once-campfire", tag: "v1.2.3",
            notes_file:, asset_paths: [ asset ]
          )
          runner.call "gh", "release", "edit"
        }
      )

      error = assert_raises(ReleaseStateError) do
        MovingChannelPromotion.new(
          lock:, journal: lock.journal, channels: [ channel ]
        ).converge!("complete")
      end
      assert_match "before the authenticated publication mutation", error.message
      assert_nil lock.journal["mutation_in_flight"]
      assert_empty lock.journal.fetch("settled_mutations", [])
    end
  end

  test "a successful fenced publication retains authenticated settlement evidence" do
    journal = phase_zero_journal.merge(
      "channels" => {
        "github_public" => {
          "kind" => "github_release", "previous" => "draft", "target" => "public"
        }
      }
    )
    lock = FakeLock.new(journal, mutation_status: stub(success?: true))
    target = { "channel" => "github_public", "value" => "public" }

    ReleaseMutationFence.new(lock:, journal: lock.journal).run!(
      kind: "moving_channel", target:
    ) { _1.call "gh", "release", "edit" }

    assert_nil lock.journal["mutation_in_flight"]
    assert_equal target, lock.journal.fetch("settled_mutations").sole.fetch("target")
  end

  test "secondary immutable aliases converge when either or both are missing" do
    references = %w[ registry.example/campfire:1.2.3 registry.example/campfire:sha ]
    target = "sha256:#{'a' * 64}"
    references.each_index.to_a.push(nil).each do |existing_index|
      states = { "registry.example/campfire:staging" => nil }
      states[references.fetch(existing_index)] = target if existing_index
      writes = []
      convergence = immutable_convergence(references, target, states, writes)

      assert_equal target, convergence.converge!(allow_create: true)
      assert references.all? { states.fetch(_1) == target }
      assert_equal target, states.fetch("registry.example/campfire:staging")
      assert writes.any? { _1.first == :sign }
    end
  end

  test "immutable alias reconciliation survives every staging signature and alias fault boundary" do
    references = %w[ registry.example/campfire:1.2.3 registry.example/campfire:sha ]
    target = "sha256:#{'a' * 64}"
    boundaries = [
      [ "stage", "registry.example/campfire:staging" ],
      [ "signature", target ],
      *references.map { [ "alias", _1 ] }
    ]

    boundaries.each do |faulting_boundary|
      states = { "registry.example/campfire:staging" => nil }
      writes = []
      convergence = immutable_convergence(
        references, target, states, writes,
        fault_after: ->(boundary, reference) {
          raise SimulatedCrash if [ boundary, reference ] == faulting_boundary
        }
      )

      assert_raises(SimulatedCrash, faulting_boundary.join(":")) do
        convergence.converge!(allow_create: true)
      end
      assert_equal target,
        immutable_convergence(references, target, states, writes).converge!(allow_create: true)
      assert references.all? { states.fetch(_1) == target }
    end
  end

  test "evidence-bound aliases remain absent after the evidence fault boundary and converge on retry" do
    references = %w[ registry.example/campfire:v1.2.3 registry.example/campfire:1.2.3 ]
    target = "sha256:#{'a' * 64}"
    states = { "registry.example/campfire:staging" => target }
    writes = []

    assert_raises(SimulatedCrash) do
      converge_evidence_bound_aliases!(
        immutable_convergence(references, target, states, writes),
        fault_after: ->(boundary) { raise SimulatedCrash if boundary == "evidence" }
      )
    end
    assert references.none? { states.key?(_1) }
    assert_equal target, converge_evidence_bound_aliases!(
      immutable_convergence(references, target, states, writes),
      fault_after: ->(_boundary) { }
    )
    assert references.all? { states.fetch(_1) == target }
  end

  test "immutable alias targets are recorded in independently authenticated journal evidence" do
    digest = "sha256:#{'a' * 64}"
    references = %w[ registry.example/campfire:1.2.3 registry.example/campfire:v1.2.3 ]
    journal = base_journal
    journal["registry_immutability_probes"] = {
      "registry.example" => registry_probe_evidence("registry.example", digest:, references:)
    }
    lock = FakeLock.new(journal)

    record_immutable_alias_evidence!(
      lock:, journal:, registry: "registry.example", references:, digest:,
      source_evidence_sha256: "e" * 64
    )
    authenticated = ReleaseJournal.verify!(
      ReleaseJournal.serialize(lock.journal, key: "k" * 32), key: "k" * 32
    )

    references.each do |reference|
      assert verify_immutable_alias_evidence!(
        journal: authenticated, registry: "registry.example", reference:, digest:
      )
    end
    authenticated.dig("immutable_alias_evidence", "registry.example", "aliases")[references.first] =
      "sha256:#{'b' * 64}"
    assert_raises(ReleaseStateError) do
      verify_immutable_alias_evidence!(
        journal: authenticated, registry: "registry.example", reference: references.first, digest:
      )
    end
  end

  test "registry alias creation detects a conflict raced before mutation" do
    reference = "registry.example/campfire:1.2.3"
    digest = "sha256:#{'a' * 64}"
    state = nil
    assert_nil state
    state = "sha256:#{'b' * 64}"
    mutated = false

    assert_raises(ReleaseStateError) do
      create_registry_alias_with_policy!(reference:, digest:, read: ->(_candidate) { state }) do
        mutated = true
      end
    end
    assert_not mutated
    assert_equal "sha256:#{'b' * 64}", state
  end

  test "registry alias creation never reports success when the post-mutation digest conflicts" do
    reference = "registry.example/campfire:1.2.3"
    digest = "sha256:#{'a' * 64}"
    state = nil

    assert_raises(ReleaseMutationUnsettled) do
      create_registry_alias_with_policy!(reference:, digest:, read: ->(_candidate) { state }) do
        state = "sha256:#{'b' * 64}"
      end
    end
    assert_equal "sha256:#{'b' * 64}", state
  end

  test "registry rejection after a raced immutable alias leaves authenticated unresolved state" do
    reference = "registry.example/campfire:1.2.3"
    digest = "sha256:#{'a' * 64}"
    initial = base_journal
    initial["registry_immutability_probes"] = {
      "registry.example" => registry_probe_evidence(
        "registry.example", digest:, references: [ reference ]
      )
    }
    lock = FakeLock.new(initial, mutation_status: stub(success?: false))
    journal = lock.journal
    record_immutable_alias_evidence!(
      lock:, journal:, registry: "registry.example", references: [ reference ], digest:,
      source_evidence_sha256: "e" * 64
    )
    journal = lock.journal

    assert_raises(ReleaseMutationUnsettled) do
      ReleaseMutationFence.new(lock:, journal:).run!(
        kind: "immutable_alias", target: { "reference" => reference, "digest" => digest }
      ) do |runner|
        verify_immutable_alias_evidence!(journal:, registry: "registry.example", reference:, digest:)
        create_registry_alias_with_policy!(reference:, digest:, read: ->(_candidate) { }) do
          mutate! "docker", "buildx", "imagetools", "create", runner:
        end
      end
    end
    assert_equal reference, lock.journal.dig("mutation_in_flight", "target", "reference")
  end

  test "live immutable-tag probe retains rejection and digest-preservation evidence before aliases" do
    seed = "sha256:#{'a' * 64}"
    conflict = "sha256:#{'b' * 64}"
    repository = "registry.example/campfire"
    references = [ "#{repository}:v1.2.3", "#{repository}:1.2.3" ]
    journal = base_journal.merge("lock_id" => "f" * 64)
    lock = FakeLock.new(journal)
    states = {
      "#{repository}@#{seed}" => seed,
      "#{repository}@#{conflict}" => conflict
    }
    success = stub(success?: true)
    rejected = stub(exited?: true, success?: false, exitstatus: 1)
    lock.define_singleton_method(:run_mutation!) do |*command, env: {}|
      reference = command.fetch(command.index("--tag") + 1)
      states[reference] = states.fetch(command.last)
      success
    end
    lock.define_singleton_method(:capture_mutation!) do |*command, stdin_data: nil|
      [ "", "denied: tag is immutable", rejected ]
    end

    evidence = prove_registry_tag_immutability!(
      lock:, journal:, registry: "registry.example", repository:,
      seed_digest: seed, conflict_digest: conflict,
      seed_source: "#{repository}@#{seed}", conflict_source: "#{repository}@#{conflict}",
      policy_references: references, read: ->(reference) { states[reference] },
      media_type: ->(_reference) { "application/vnd.oci.image.index.v1+json" },
      fault_prefix: "test_probe"
    )

    assert_equal "verified", evidence.fetch("status")
    assert_equal conflict, states.fetch(evidence.fetch("control_reference"))
    references.each { assert_equal seed, states.fetch(_1) }
    evidence.fetch("rejections").each_value do |rejection|
      assert_equal "server_immutable_tag_rejection", rejection.fetch("classification")
      assert_equal 1, rejection.fetch("exit_status")
      assert_match(/\A[0-9a-f]{64}\z/, rejection.fetch("output_sha256"))
    end
    assert registry_immutability_probe_evidence!(lock.journal, "registry.example")
  end

  test "registry accepting the conflicting live probe aborts before alias authorization" do
    seed = "sha256:#{'a' * 64}"
    conflict = "sha256:#{'b' * 64}"
    repository = "registry.example/campfire"
    references = [ "#{repository}:1.2.3" ]
    journal = base_journal.merge("lock_id" => "f" * 64)
    lock = FakeLock.new(journal)
    states = {
      "#{repository}@#{seed}" => seed,
      "#{repository}@#{conflict}" => conflict
    }
    success = stub(exited?: true, success?: true, exitstatus: 0)
    lock.define_singleton_method(:run_mutation!) do |*command, env: {}|
      reference = command.fetch(command.index("--tag") + 1)
      states[reference] = states.fetch(command.last)
      success
    end
    lock.define_singleton_method(:capture_mutation!) do |*command, stdin_data: nil|
      reference = command.fetch(command.index("--tag") + 1)
      states[reference] = states.fetch(command.last)
      [ "", "", success ]
    end

    assert_raises(ReleaseMutationUnsettled) do
      prove_registry_tag_immutability!(
        lock:, journal:, registry: "registry.example", repository:,
        seed_digest: seed, conflict_digest: conflict,
        seed_source: "#{repository}@#{seed}", conflict_source: "#{repository}@#{conflict}",
        policy_references: references, read: ->(reference) { states[reference] },
        media_type: ->(_reference) { "application/vnd.oci.image.index.v1+json" },
        fault_prefix: "test_probe"
      )
    end
    assert_nil lock.journal["immutable_alias_evidence"]
    assert_equal conflict, states.fetch(references.sole)
  end

  test "registry immutability proof rejects auth network and unsupported failures" do
    rejected = stub(exited?: true, success?: false, exitstatus: 1)
    assert registry_immutable_tag_rejection?("", "denied: tag is immutable", rejected)
    [
      "unauthorized: authentication required",
      "dial tcp: connection timed out",
      "unsupported manifest media type",
      "manifest unknown"
    ].each do |message|
      assert_not registry_immutable_tag_rejection?("", message, rejected), message
    end
  end

  test "workflow YAML has the exact nonce-bound dispatch and flat evidence contract" do
    workflow = YAML.safe_load(Rails.root.join(".github/workflows/publish-image.yml").read, aliases: false)
    triggers = workflow["on"] || workflow.fetch(true)
    inputs = triggers.fetch("workflow_dispatch").fetch("inputs")
    steps = workflow.fetch("jobs").values.flat_map { _1.fetch("steps", []) }
    upload = steps.find { _1["name"] == "Upload release evidence" }
    build_inputs = steps.find { _1["name"] == "Compute immutable build inputs" }.fetch("run")
    release_evidence = steps.find { _1["name"] == "Record release evidence" }.fetch("run")
    authorization = steps.find { _1["name"] == "Validate release authorization" }

    assert_equal [ "workflow_dispatch" ], triggers.keys
    assert_equal %w[ operation_nonce release_sha release_tag ], inputs.keys.sort
    inputs.each_value do |input|
      assert_equal true, input.fetch("required")
      assert_equal "string", input.fetch("type")
    end
    assert_equal "Campfire release ${{ inputs.release_tag }} ${{ inputs.release_sha }} ${{ inputs.operation_nonce }}",
      workflow.fetch("run-name")
    assert_equal "${{ inputs.operation_nonce }}", authorization.dig("env", "OPERATION_NONCE")
    assert_includes authorization.fetch("run"), '[[ "$OPERATION_NONCE" =~ ^[0-9a-f]{64}$ ]]'
    assert_equal "${{ inputs.operation_nonce }}", workflow.dig("jobs", "manifest", "env", "OPERATION_NONCE")
    assert_equal "release-evidence-${{ github.run_attempt }}", upload.dig("with", "name")
    assert_equal 90, upload.dig("with", "retention-days")
    upload_paths = upload.dig("with", "path").lines.map(&:strip).reject(&:empty?)
    assert_equal RELEASE_EVIDENCE_INVENTORY,
      upload_paths.map { File.basename(_1) }.sort
    assert upload_paths.all? { _1.start_with?("${{ runner.temp }}/release-evidence/") }
    assert_includes build_inputs, "release:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}:${{ matrix.arch }}:${RELEASE_SHA}"
    assert_includes release_evidence, '--arg run_attempt "$GITHUB_RUN_ATTEMPT"'
    assert_includes release_evidence, '--arg operation_nonce "$OPERATION_NONCE"'
    assert steps.none? { _1.fetch("run", "").include?("exact_tags=(") }
    %w[ ghcr_evidence ghcr_tag_alias ghcr_version_alias ].each do |boundary|
      assert_includes Rails.root.join("bin/release").read, boundary
    end
  end

  test "release build identities are scoped to one workflow attempt" do
    attributes = {
      run_id: 123, architecture: "amd64", revision: "c" * 40
    }

    first = CampfireBackup::BuildIdentity.release_identity(**attributes, run_attempt: 1)
    second = CampfireBackup::BuildIdentity.release_identity(**attributes, run_attempt: 2)

    assert_equal Digest::SHA256.hexdigest("release:123:1:amd64:#{'c' * 40}"), first
    assert_not_equal first, second
  end

  test "completed secondary immutable phase repairs a missing alias without overwriting" do
    references = %w[ registry.example/campfire:1.2.3 registry.example/campfire:sha ]
    target = "sha256:#{'a' * 64}"
    states = { references.first => target, "registry.example/campfire:staging" => target }
    writes = []

    assert_equal target, immutable_convergence(references, target, states, writes).converge!(allow_create: true)
    assert references.all? { states.fetch(_1) == target }
    assert_includes writes, [ :publish, references.last ]
  end

  test "secondary immutable reconciliation refuses a conflicting alias before mutation" do
    references = %w[ registry.example/campfire:1.2.3 registry.example/campfire:sha ]
    target = "sha256:#{'a' * 64}"
    states = {
      references.first => "sha256:#{'b' * 64}",
      "registry.example/campfire:staging" => target
    }
    writes = []

    assert_raises(ReleaseStateError) do
      immutable_convergence(references, target, states, writes).converge!(allow_create: true)
    end
    assert_empty writes
  end

  test "immutable static publication explicitly rejects existing symbolic links" do
    Dir.mktmpdir("release-static") do |directory|
      source = File.join(directory, "campfire.zip")
      File.write source, "release bytes"
      digest = Digest::SHA256.file(source).hexdigest
      commands = []
      stubs(:capture!).with do |*arguments|
        commands << arguments.last
        true
      end.returns("#{digest}  campfire.zip")

      upload_immutable source, "campfire-1.2.3.zip", "c" * 40

      assert_equal EXPORT_DEPLOY_HOSTS.length, commands.length
      commands.each do |command|
        assert_includes command, "test ! -L"
        assert_includes command, "stat -c %h"
        assert_includes command, "candidate"
        _stdout, stderr, status = Open3.capture3("bash", "-n", "-c", command)
        assert status.success?, stderr
      end
    end
  end

  test "remote static staging uses an unpredictable exclusive regular file" do
    Dir.mktmpdir("release-static-upload") do |directory|
      source = File.join(directory, "campfire.zip")
      File.binwrite source, "release bytes"
      digest = Digest::SHA256.file(source).hexdigest
      command = nil
      SecureRandom.stubs(:hex).with(16).returns("1" * 32)
      stubs(:stream_file_to_remote!).with do |path, host, candidate|
        command = candidate
        path == source && host == "static.example"
      end.returns("#{digest}  staged")

      temporary, actual_digest = upload_remote_temporary!(
        source, "static.example", "/releases/.campfire.zip.revision"
      )

      assert_equal "/releases/.campfire.zip.revision.#{'1' * 32}.tmp", temporary
      assert_equal digest, actual_digest
      assert_includes command, "set -C"
      assert_includes command, "stat -c %h"
      assert_includes command, "wc -c"
      assert_not_includes command, "scp"
    end
  end

  test "static pointer replacement holds a pinned remote exclusive lock and compares the old target" do
    command = nil
    success = stub(success?: true)
    runner = lambda do |*arguments, env:|
      command = arguments.last
      assert_empty env
      success
    end

    set_static_release_target!(
      "static.example", "campfire-1.2.3", "c" * 40,
      expected: "campfire-1.2.2", runner:
    )

    assert_includes command, "flock -x 9"
    assert_includes command, "/proc/$$/fd/9"
    assert_includes command, ".campfire-current.release.lock"
    assert_operator command.scan("readlink campfire-current").length, :>=, 3
    assert_includes command, "campfire-1.2.2"
    assert_includes command, "mv -Tf"
  end

  test "immutable static files publish with a no-clobber hard link" do
    Dir.mktmpdir("release-static-hard-link") do |directory|
      source = File.join(directory, "campfire.zip")
      File.binwrite source, "release bytes"
      digest = Digest::SHA256.file(source).hexdigest
      commands = []
      stubs(:capture!).with do |*arguments|
        commands << arguments.last
        true
      end.returns(
        "ABSENT", "#{digest}  campfire-1.2.3.zip",
        "ABSENT", "#{digest}  campfire-1.2.3.zip"
      )
      stubs(:upload_remote_temporary!).returns(
        [ "/releases/.first.random.tmp", digest ],
        [ "/releases/.second.random.tmp", digest ]
      )

      upload_immutable source, "campfire-1.2.3.zip", "c" * 40

      publication_commands = commands.reject { _1.include?("echo ABSENT") }
      assert_equal EXPORT_DEPLOY_HOSTS.length, publication_commands.length
      publication_commands.each do |command|
        assert_includes command, "ln -T"
        assert_includes command, "-ef"
        assert_includes command, "stat -c %h"
        assert_not_includes command, "mv "
        _stdout, stderr, status = Open3.capture3("bash", "-n", "-c", command)
        assert status.success?, stderr
      end
    end
  end

  test "immutable static directories use random staging and atomic no-replace rename" do
    Dir.mktmpdir("release-static-directory") do |directory|
      archive = File.join(directory, "campfire.zip")
      checksum = "#{archive}.sha256"
      File.binwrite archive, "release bytes"
      File.binwrite checksum, "#{Digest::SHA256.file(archive).hexdigest}  campfire.zip\n"
      archive_digest = Digest::SHA256.file(archive).hexdigest
      checksum_digest = Digest::SHA256.file(checksum).hexdigest
      staged = EXPORT_DEPLOY_HOSTS.each_index.flat_map do |index|
        [
          [ "/releases/.archive.#{index}.random.tmp", archive_digest ],
          [ "/releases/.checksum.#{index}.random.tmp", checksum_digest ]
        ]
      end
      stubs(:upload_remote_temporary!).returns(*staged)
      commands = []
      stubs(:run!).with do |*arguments|
        commands << arguments.last
        true
      end.returns(true)

      assert_equal "campfire-1.2.3", stage_static_release!(archive, checksum, "1.2.3", "c" * 40)

      assert_equal EXPORT_DEPLOY_HOSTS.length, commands.length
      commands.each do |command|
        assert_match(/\.campfire-1\.2\.3\.#{'c' * 40}\.[0-9a-f]{32}\.tmp/, command)
        assert_includes command, "ln -T"
        assert_includes command, "renameat2"
        assert_includes command, "-rbase64"
        assert_includes command, "-eq 2"
        assert_includes command, "stat -c %h"
        assert_not_includes command, "mv "
        _stdout, stderr, status = Open3.capture3("bash", "-n", "-c", command)
        assert status.success?, stderr
      end
      assert_not_equal commands.first[/\.[0-9a-f]{32}\.tmp/], commands.last[/\.[0-9a-f]{32}\.tmp/]
    end
  end

  test "phase-zero and journal staging names authenticate expected bytes" do
    lock_id = "a" * 64
    source = history_chain(1).sole.fetch(:source)
    pending = ReleaseLock.pending_stage_name(lock_id, source, key: history_key)
    assert_equal lock_id,
      ReleaseLock.parse_pending_stage_name(pending, key: history_key).fetch(:lock_id)

    stage = ReleaseLock.journal_stage_name(
      lock_id:, invocation_id: "b" * 32, revision: 1, source:, key: history_key
    )
    assert_equal 1,
      ReleaseLock.parse_journal_stage_name(stage, lock_id:, key: history_key).fetch(:revision)
    tampered = stage.sub(/.$/, stage.end_with?("0") ? "1" : "0")
    assert_raises(ReleaseStateError) do
      ReleaseLock.parse_journal_stage_name(tampered, lock_id:, key: history_key)
    end
  end

  test "truncated keyed history staging is removable only with the exact history set" do
    lock_id = "a" * 64
    canonical = history_chain(1).sole
    state = ReleaseLock.state_from_snapshot(history_snapshot([ canonical ]), key: history_key)
    staged = build_history_revision(
      revision: 1, prior_digest: canonical.fetch(:current_digest), publisher_id: "b" * 32,
      status: "staged"
    )
    name = ReleaseLock.journal_stage_name(
      lock_id:, invocation_id: "b" * 32, revision: 1,
      source: staged.fetch(:source), key: history_key
    )
    truncated = staged.fetch(:source).byteslice(0, staged.fetch(:source).bytesize / 2)
    stage = snapshot_record(
      kind: "STAGE", name:, source: truncated, nlink: 1, identity: "9:9"
    )
    status = stub(success?: true)
    commands = []
    key = history_key
    ReleaseLock.stubs(:capture_remote).with do |command|
      commands << command
      true
    end.returns([ "", "", status ])

    assert_nothing_raised do
      ReleaseLock.cleanup_journal_staging!(
        "/releases/.campfire-release.lock", state, key, "b" * 32,
        stages: [ stage ]
      )
    end
    assert_includes commands.sole, canonical.fetch(:name)
    assert_includes commands.sole, name
  end

  test "truncated keyed phase-zero staging remains provably unpublished" do
    lock_id = "a" * 64
    source = history_chain(1).sole.fetch(:source)
    name = ReleaseLock.pending_stage_name(lock_id, source, key: history_key)
    truncated = source.byteslice(0, source.bytesize / 2)
    stage_name = ReleaseLock.journal_stage_name(
      lock_id:, invocation_id: "b" * 32, revision: 0, source:, key: history_key
    )
    stage = snapshot_record(
      kind: "STAGE", name: stage_name, source: truncated, nlink: 1, identity: "8:8"
    )
    partial_artifact = {
      kind: "ARTIFACT", name: ReleaseLock::PHASE_ZERO_ARTIFACT_FILENAMES.fetch("export"),
      nlink: 1, identity: "8:9", bytes: 7, digest: Digest::SHA256.hexdigest("partial")
    }
    observed = {
      owner_nlink: 1, owner_bytes: 65, owner_digest: Digest::SHA256.hexdigest("#{lock_id}\n"),
      history: nil, stages: [ stage ], artifacts: [ partial_artifact ]
    }
    status = stub(success?: true)
    commands = []
    ReleaseLock.stubs(:capture_remote).with do |command|
      commands << command
      true
    end.returns([ "", "", status ])

    ReleaseLock.send(
      :remove_pending_stage!,
      File.join("/releases", name), observed, "b" * 32
    )
    assert_includes commands.sole, stage_name
    assert_includes commands.sole, partial_artifact.fetch(:name)
    assert_includes commands.sole, "rmdir"
  end

  test "unknown journal staging is preserved and blocks cleanup" do
    assert_raises(ReleaseStateError) do
      ReleaseLock.parse_journal_stage_name(
        ".journal-history.stage-unknown", lock_id: "a" * 64, key: history_key
      )
    end
  end

  private
    def acquire_test_live_lock(directory, mutation_popen3: Open3.method(:popen3))
      invocation_id = "1" * 32
      ReleaseInvocationLock.acquire(
        invocation_id:,
        command: local_lock_holder_command(File.join(directory, "live.lock"), invocation_id),
        mutation_popen3:, mutation_exit_timeout: 0.05,
        mutation_termination_timeout: 0.5, mutation_kill_timeout: 5,
        mutation_io_timeout: 1
      )
    end

    def mutation_process_paths(directory)
      {
        terminated: File.join(directory, "terminated"),
        leader: File.join(directory, "leader"),
        descendant: File.join(directory, "descendant")
      }
    end

    def stubborn_mutation_command(paths, mode:)
      source = <<~'RUBY'
        termination_log = File.open(
          ARGV.fetch(0), File::WRONLY | File::CREAT | File::APPEND, 0o600
        )
        termination_log.sync = true
        trap("TERM") do
          begin
            termination_log.syswrite("#{Process.pid}\n")
          rescue StandardError
            nil
          end
        end
        descendant_path = ARGV.fetch(2)
        descendant = fork do
          File.write descendant_path, "#{Process.pid} #{Process.getpgrp}\n"
          loop { sleep 1 }
        end
        File.write ARGV.fetch(1), "#{Process.pid} #{Process.getpgrp} #{descendant}\n"
        exit! 0 if ARGV.fetch(3) == "exit"
        STDIN.read if ARGV.fetch(3) == "read"
        loop { sleep 1 }
      RUBY
      [
        RbConfig.ruby, "-e", source, paths.fetch(:terminated), paths.fetch(:leader),
        paths.fetch(:descendant), mode
      ]
    end

    def wait_for_mutation_processes(paths)
      Timeout.timeout(5) do
        until File.size?(paths.fetch(:leader)) && File.size?(paths.fetch(:descendant))
          sleep 0.01
        end
      end
    end

    def mutation_process_ids(paths)
      leader_pid, group_id, recorded_descendant = File.read(paths.fetch(:leader)).split.map(&:to_i)
      descendant_pid, descendant_group = File.read(paths.fetch(:descendant)).split.map(&:to_i)
      assert_equal recorded_descendant, descendant_pid
      [ leader_pid, group_id, descendant_pid, descendant_group ]
    end

    def process_group_alive?(pid)
      return false unless pid

      Process.kill 0, -pid
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def assert_process_group_gone(pid)
      Timeout.timeout(5) { sleep 0.01 while process_group_alive?(pid) }
      assert_not process_group_alive?(pid)
    end

    def kill_test_process_group(pid)
      return unless process_group_alive?(pid)

      Process.kill "KILL", -pid
      Timeout.timeout(5) { sleep 0.01 while process_group_alive?(pid) }
    rescue Errno::ESRCH, Timeout::Error
      nil
    end

    def terminate_test_live_lock_holder(lock)
      waiter = lock.instance_variable_get(:@wait_thread)
      Process.kill "KILL", waiter.pid
      waiter.join
    rescue Errno::ESRCH
      waiter&.join
    end

    def release_test_live_lock(lock)
      return unless lock&.instance_variable_get(:@wait_thread)

      lock.release
    rescue ReleaseStateError
      waiter = lock.instance_variable_get(:@wait_thread)
      begin
        Process.kill "KILL", waiter.pid if waiter&.alive?
      rescue Errno::ESRCH
        nil
      end
      waiter&.join
      %i[ @stdin @stdout @stderr ].each do |name|
        stream = lock.instance_variable_get(name)
        stream&.close unless stream&.closed?
      rescue IOError
        nil
      end
      lock.instance_variable_set(:@wait_thread, nil)
    end

    def history_key
      "k" * 32
    end

    def build_history_revision(revision:, prior_digest:, publisher_id: nil, status: nil)
      journal = phase_zero_journal.merge(
        "lock_id" => "a" * 64, "journal_revision" => revision
      )
      journal["status"] = status if status
      ReleaseJournal.build_history(
        journal, operation_id: "a" * 64, prior_digest:,
        publisher_id: publisher_id || format("%032x", revision + 1), key: history_key
      )
    end

    def history_chain(length)
      prior_digest = ReleaseJournal::GENESIS_DIGEST
      Array.new(length) do |revision|
        entry = build_history_revision(
          revision:, prior_digest:, status: revision.zero? ? nil : "revision-#{revision}"
        )
        prior_digest = entry.fetch(:current_digest)
        entry
      end
    end

    def history_snapshot(history, stages: [], artifacts: nil)
      journal = JSON.parse(history.last.fetch(:source)).fetch("journal")
      {
        lock_id: "a" * 64,
        histories: history.each_with_index.map do |entry, index|
          snapshot_record(
            kind: "HISTORY", name: entry.fetch(:name), source: entry.fetch(:source),
            nlink: entry.fetch(:nlink, 1), identity: entry.fetch(:identity, "1:#{index + 1}")
          )
        end,
        stages:,
        artifacts: artifacts || phase_zero_artifact_snapshot(journal)
      }
    end

    def phase_zero_artifact_snapshot(journal)
      sources = phase_zero_artifact_sources
      ReleaseLock.phase_zero_artifact_metadata(journal).values.each_with_index.map do |metadata, index|
        source = sources.fetch(metadata.fetch(:role))
        {
          kind: "ARTIFACT", name: metadata.fetch(:name), nlink: 1,
          identity: "2:#{index + 1}", bytes: source.bytesize,
          digest: Digest::SHA256.hexdigest(source)
        }
      end
    end

    def snapshot_record(kind:, name:, source:, nlink:, identity:)
      {
        kind:, name:, source:, nlink:, identity:, bytes: source.bytesize,
        digest: Digest::SHA256.hexdigest(source)
      }
    end

    def portable_release_shell(command)
      command = command.gsub("mv -T ", "mv ").gsub("ln -T ", "ln ")
      RbConfig::CONFIG.fetch("host_os").match?(/darwin/) ? command.gsub("stat -c %h", "stat -f %l") : command
    end

    def local_publisher
      ReleaseAtomicPublisher.new(capture: ->(command, stream) {
        portable_command = portable_release_shell(command)
        input = stream.respond_to?(:read) ? stream.read : stream
        Open3.capture3("bash", "-c", portable_command, stdin_data: input)
      }, rename_noreplace: ->(source, destination) {
        "mv #{Shellwords.escape(source)} #{Shellwords.escape(destination)}"
      })
    end

    def local_lock_holder_command(path, invocation_id)
      source = <<~RUBY
        file = File.open(ARGV.fetch(0), File::RDWR | File::CREAT, 0o600)
        if file.flock(File::LOCK_EX | File::LOCK_NB)
          puts "READY #{invocation_id}"
          STDOUT.flush
          STDIN.read
        else
          puts "BUSY"
          STDOUT.flush
          exit 75
        end
      RUBY
      [ RbConfig.ruby, "-e", source, path ]
    end

    def release_entry_arguments(**overrides)
      {
        reconciling: false, resuming: false, reconcile_sha: "",
        git_sha: "c" * 40, existing_tag_sha: nil, release_public: false,
        remote_main_sha: "c" * 40, release_sha_ancestor_of_main: true
      }.merge(overrides)
    end

    def github_release_metadata(notes_file, asset_paths, draft:)
      {
        "assets" => asset_paths.map do |path|
          {
            "name" => File.basename(path),
            "digest" => "sha256:#{Digest::SHA256.file(path).hexdigest}"
          }
        end,
        "body" => File.read(notes_file),
        "isDraft" => draft,
        "isPrerelease" => false,
        "name" => "v1.2.3",
        "tagName" => "v1.2.3"
      }
    end

    def write_valid_release_evidence(directory)
      repository = "basecamp/once-campfire"
      sha = "c" * 40
      tag = "v1.2.3"
      image = "ghcr.io/basecamp/once-campfire"
      run_id = 123
      run_attempt = 2
      operation_nonce = "9" * 64
      json_files = %w[
        container-validation-amd64.json container-validation-arm64.json
        sbom-amd64.spdx.json sbom-arm64.spdx.json
        buildkit-provenance-amd64.json buildkit-provenance-arm64.json
        parent-provenance-verification-amd64.json parent-provenance-verification-arm64.json
        runnable-provenance-verification-amd64.json runnable-provenance-verification-arm64.json
        index-provenance-verification.json
      ]
      json_files.each do |name|
        File.binwrite File.join(directory, name), JSON.generate("file" => name) << "\n"
      end
      %w[
        parent-provenance-amd64.bundle.jsonl parent-provenance-arm64.bundle.jsonl
        runnable-provenance-amd64.bundle.jsonl runnable-provenance-arm64.bundle.jsonl
        index-provenance.bundle.jsonl
      ].each do |name|
        File.binwrite File.join(directory, name), JSON.generate("bundle" => name) << "\n"
      end

      promotion = {
        "authority" => "bin/release",
        "workflow_scope" => "attempt-scoped staging only",
        "required_release_driver_evidence" => [
          "live no-overwrite registry probe bound to immutable aliases",
          "dual Object Lock anchor receipts for the authenticated journal head"
        ]
      }
      File.binwrite(
        File.join(directory, "promotion-requirements.json"),
        JSON.pretty_generate(promotion) << "\n"
      )

      build_indexes = {
        "amd64" => "sha256:#{'d' * 64}", "arm64" => "sha256:#{'e' * 64}"
      }
      children = {
        "amd64" => "sha256:#{'a' * 64}", "arm64" => "sha256:#{'b' * 64}"
      }
      legacy_images = RELEASE_EVIDENCE_ARCHITECTURES.to_h { [ _1, "sha256:#{'f' * 64}" ] }
      build_identities = RELEASE_EVIDENCE_ARCHITECTURES.to_h do |architecture|
        [ architecture, CampfireBackup::BuildIdentity.release_identity(
          run_id:, run_attempt:, architecture:, revision: sha
        ) ]
      end

      RELEASE_EVIDENCE_ARCHITECTURES.each_with_index do |architecture, index|
        upgrade_receipt = {
          "format_version" => 2,
          "kind" => "campfire-upgrade-recovery",
          "migration" => "CreateIdentities",
          "environment" => "production",
          "target_revision" => sha,
          "target_build_identity" => build_identities.fetch(architecture),
          "backup_id" => "backup-#{architecture}",
          "installation_fingerprint" => "1" * 64,
          "source_schema_version" => "20260730000000",
          "source_state_sha256" => "2" * 64,
          "source_manifest_sha256" => "3" * 64,
          "archive_path" => "/recovery/#{architecture}.campfire-backup",
          "archive_bytes" => 123,
          "archive_sha256" => "4" * 64,
          "authentication_path" => "/recovery/#{architecture}.campfire-backup",
          "authentication_sha256" => "4" * 64,
          "created_at" => "2026-08-02T12:00:00Z",
          "expires_at" => "2026-08-02T13:00:00Z",
          "authentication" => {
            "algorithm" => "HMAC-SHA256", "key_id" => "5" * 16, "mac" => "6" * 64
          }
        }
        upgrade_name = "upgrade-recovery-#{architecture}.json"
        File.binwrite File.join(directory, upgrade_name), JSON.pretty_generate(upgrade_receipt) << "\n"

        recovery = {
          "format_version" => 1,
          "kind" => "campfire-image-recovery",
          "architecture" => architecture,
          "platform" => "linux/#{architecture}",
          "source_sha" => sha,
          "release_tag" => tag,
          "target_reference" => "#{image}@#{children.fetch(architecture)}",
          "target_digest" => children.fetch(architecture),
          "target_manifest_digest" => children.fetch(architecture),
          "target_config_digest" => "sha256:#{(index + 7).to_s(16) * 64}",
          "runtime_binding" => "registry-manifest-digest",
          "container_validation_sha256" => Digest::SHA256.file(
            File.join(directory, "container-validation-#{architecture}.json")
          ).hexdigest,
          "target_build_identity" => build_identities.fetch(architecture),
          "legacy_reference" => "ghcr.io/basecamp/once-campfire@#{legacy_images.fetch(architecture)}",
          "legacy_digest" => legacy_images.fetch(architecture),
          "legacy_revision" => "7" * 40,
          "source_schema_version" => "20260730000000",
          "upgrade_receipt_sha256" => Digest::SHA256.file(File.join(directory, upgrade_name)).hexdigest,
          "current_recovery" => { "artifact_kind" => "campfire-backup", "artifact_sha256" => "8" * 64 },
          "legacy_recovery" => { "artifact_kind" => "campfire-backup", "artifact_sha256" => "9" * 64 },
          "checks" => %w[
            current_restore legacy_restore migration_denials tamper_denials authorized_upgrade
            http_history_and_uploads worker_execution
          ].to_h { [ _1, "passed" ] },
          "recovery" => "passed",
          "run_id" => run_id.to_s,
          "run_attempt" => run_attempt.to_s,
          "parent_digest" => build_indexes.fetch(architecture),
          "image_inspection_sha256" => Digest::SHA256.file(
            File.join(directory, "container-validation-#{architecture}.json")
          ).hexdigest,
          "buildkit" => {
            "sbom_sha256" => Digest::SHA256.file(File.join(directory, "sbom-#{architecture}.spdx.json")).hexdigest,
            "provenance_sha256" => Digest::SHA256.file(
              File.join(directory, "buildkit-provenance-#{architecture}.json")
            ).hexdigest
          },
          "signed_provenance" => {
            "parent_bundle_sha256" => Digest::SHA256.file(
              File.join(directory, "parent-provenance-#{architecture}.bundle.jsonl")
            ).hexdigest,
            "runnable_bundle_sha256" => Digest::SHA256.file(
              File.join(directory, "runnable-provenance-#{architecture}.bundle.jsonl")
            ).hexdigest,
            "parent_verification_sha256" => Digest::SHA256.file(
              File.join(directory, "parent-provenance-verification-#{architecture}.json")
            ).hexdigest,
            "runnable_verification_sha256" => Digest::SHA256.file(
              File.join(directory, "runnable-provenance-verification-#{architecture}.json")
            ).hexdigest,
            "source_digest" => sha,
            "source_ref" => "refs/heads/main",
            "signer_workflow" => PUBLISH_WORKFLOW_FILE
          }
        }
        File.binwrite(
          File.join(directory, "recovery-#{architecture}.json"),
          JSON.pretty_generate(recovery) << "\n"
        )
      end

      evidence_files = RELEASE_EVIDENCE_FILES.to_h do |name|
        [ name, Digest::SHA256.file(File.join(directory, name)).hexdigest ]
      end
      release_evidence = {
        "format_version" => WORKFLOW_EVIDENCE_FORMAT_VERSION,
        "operation_nonce" => operation_nonce,
        "repository" => repository,
        "source_sha" => sha,
        "release_tag" => tag,
        "image" => image,
        "index_digest" => "sha256:#{'c' * 64}",
        "staging_reference" => "#{image}:staging-#{run_id}-#{run_attempt}",
        "build_indexes" => build_indexes,
        "children" => children,
        "build_identities" => build_identities,
        "legacy_images" => legacy_images,
        "recovery" => RELEASE_EVIDENCE_ARCHITECTURES.to_h { [ _1, "passed" ] },
        "recovery_receipts" => RELEASE_EVIDENCE_ARCHITECTURES.to_h do |architecture|
          [ architecture, evidence_files.fetch("recovery-#{architecture}.json") ]
        end,
        "upgrade_receipts" => RELEASE_EVIDENCE_ARCHITECTURES.to_h do |architecture|
          [ architecture, evidence_files.fetch("upgrade-recovery-#{architecture}.json") ]
        end,
        "signed_provenance" => {
          "source_digest" => sha,
          "source_ref" => "refs/heads/main",
          "signer_workflow" => PUBLISH_WORKFLOW_FILE,
          "index_bundle_sha256" => evidence_files.fetch("index-provenance.bundle.jsonl"),
          "index_verification_sha256" => evidence_files.fetch("index-provenance-verification.json")
        },
        "promotion_requirements" => promotion,
        "promotion_requirements_sha256" => evidence_files.fetch("promotion-requirements.json"),
        "evidence_files" => evidence_files,
        "run_id" => run_id.to_s,
        "run_attempt" => run_attempt.to_s
      }
      File.binwrite(
        File.join(directory, "release-evidence.json"),
        JSON.pretty_generate(release_evidence) << "\n"
      )
      {
        repository:, run_id:, run_attempt:, destination: directory, sha:, tag:, image:,
        operation_nonce:
      }
    end

    def refresh_release_evidence_file_hash!(directory, name)
      path = File.join(directory, "release-evidence.json")
      evidence = JSON.parse(File.binread(path))
      digest = Digest::SHA256.file(File.join(directory, name)).hexdigest
      evidence.fetch("evidence_files")[name] = digest
      if match = name.match(/\Arecovery-(amd64|arm64)\.json\z/)
        evidence.fetch("recovery_receipts")[match[1]] = digest
      end
      File.binwrite path, JSON.pretty_generate(evidence) << "\n"
    end

    def immutable_convergence(references, target, states, writes, fault_after: ->(_boundary, _reference) { })
      ImmutableAliasConvergence.new(
        references:, staging_reference: "registry.example/campfire:staging", target_digest: target,
        read: ->(reference) { states[reference] },
        stage: ->(reference, digest) { writes << [ :stage, reference ]; states[reference] = digest },
        verify: ->(digest) { writes << [ :verify, digest ] },
        sign: ->(digest) { writes << [ :sign, digest ] },
        publish: ->(reference, digest) { writes << [ :publish, reference ]; states[reference] = digest },
        fault_after:
      )
    end

    def registry_probe_evidence(registry, digest: "sha256:#{'a' * 64}",
        references: [ "#{registry}/campfire:1.2.3" ])
      repository = "#{registry}/campfire"
      conflict = "sha256:#{'b' * 64}"
      {
        "format_version" => 2,
        "status" => "verified",
        "registry" => registry,
        "repository" => repository,
        "control_reference" => "#{repository}:release-mutability-control-#{'f' * 64}",
        "policy_references" => references.sort,
        "media_type" => "application/vnd.oci.image.index.v1+json",
        "seed_digest" => digest,
        "conflict_digest" => conflict,
        "prepared_at" => "2026-08-02T12:00:00Z",
        "control_seed_observed_digest" => digest,
        "control_overwrite_observed_digest" => conflict,
        "policy_observed_digests" => references.sort.to_h { [ _1, digest ] },
        "rejections" => references.sort.to_h do |reference|
          [ reference, {
            "classification" => "server_immutable_tag_rejection",
            "exit_status" => 1,
            "output_sha256" => "e" * 64
          } ]
        end,
        "verified_at" => "2026-08-02T12:01:00Z"
      }
    end

    def base_journal
      {
        "format_version" => 1,
        "journal_revision" => 0,
        "outcome" => "complete",
        "status" => "prepared",
        "completed_steps" => {}
      }
    end

    def phase_zero_journal
      notes = "# What's Changed\n\n- Durable release notes\n"
      artifacts = phase_zero_artifact_sources
      {
        "format_version" => RELEASE_JOURNAL_FORMAT_VERSION,
        "journal_revision" => 0,
        "release" => { "repository" => "basecamp/once-campfire", "version" => "1.2.3", "tag" => "v1.2.3", "sha" => "c" * 40 },
        "anchor_set" => test_anchor_set,
        "phase_zero_artifacts" => {
          "notes_sha256" => Digest::SHA256.hexdigest(notes),
          "export" => {
            "name" => ReleaseLock::PHASE_ZERO_ARTIFACT_FILENAMES.fetch("export"),
            "bytes" => artifacts.fetch("export").bytesize,
            "sha256" => Digest::SHA256.hexdigest(artifacts.fetch("export"))
          },
          "checksum" => {
            "name" => ReleaseLock::PHASE_ZERO_ARTIFACT_FILENAMES.fetch("checksum"),
            "bytes" => artifacts.fetch("checksum").bytesize,
            "sha256" => Digest::SHA256.hexdigest(artifacts.fetch("checksum"))
          }
        },
        "release_notes" => notes,
        "status" => "locked",
        "phase" => "phase_zero",
        "phases" => {
          "phase_zero" => {
            "status" => "completed", "data" => {},
            "started_at" => "2026-07-31T12:00:00Z", "completed_at" => "2026-07-31T12:00:00Z"
          }
        },
        "created_at" => "2026-07-31T12:00:00Z",
        "updated_at" => "2026-07-31T12:00:00Z"
      }
    end

    def test_anchor_set
      {
        "format_version" => 2,
        "provider" => "aws",
        "endpoint_policy" => "aws-default-endpoints-only",
        "ignore_configured_endpoint_urls" => true,
        "anchors" => [],
        "sha256" => "d" * 64
      }
    end

    def phase_zero_artifact_sources
      export = "exact phase-zero export bytes\n"
      {
        "export" => export,
        "checksum" => "#{Digest::SHA256.hexdigest(export)}  campfire-1.2.3.zip\n"
      }
    end

    def write_phase_zero_artifacts(directory)
      phase_zero_artifact_sources.to_h do |role, source|
        name = ReleaseLock::PHASE_ZERO_ARTIFACT_FILENAMES.fetch(role)
        path = File.join(directory, "source-#{name}")
        File.binwrite path, source
        [ name, path ]
      end
    end

    def channels_for(states, writes: [])
      if CHANNEL_KEYS.all? { states.key?(_1) }
        return CHANNEL_KEYS.map { channel(_1, "previous:#{_1}", "target:#{_1}", states, writes) }
      end

      [
        channel("registry_latest", "sha256:old", "sha256:new", states, writes),
        channel("static_host", "campfire-1.2.2", "campfire-1.2.3", states, writes),
        channel("github_public", "draft", "public", states, writes)
      ]
    end

    def channel(key, previous, target, states, writes)
      ReleaseChannel.new(
        key:, previous:, target:,
        read: -> { states.fetch(key) },
        write: ->(value, _runner) { writes << [ key, value ]; states[key] = value }
      )
    end
end
