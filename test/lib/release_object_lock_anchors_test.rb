require "test_helper"
require "tmpdir"

require Rails.root.join("lib/release_object_lock_anchors")

class ReleaseObjectLockAnchorsTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  class SimulatedInterruption < Exception; end

  test "Object Lock must be enabled and retained objects must use COMPLIANCE rather than GOVERNANCE" do
    with_fake_aws do |environment, state_path|
      update_fake_state(state_path) do |state|
        state.fetch("buckets").fetch("campfire-release-anchor-a")["object_lock"] = "Disabled"
      end

      assert_raises(ReleaseObjectLockAnchors::Error) do
        anchors(environment)
      end
    end

    with_fake_aws do |environment, state_path|
      update_fake_state(state_path) do |state|
        state.fetch("buckets").fetch("campfire-release-anchor-a")["force_retention_mode"] = "GOVERNANCE"
      end

      control = anchors(environment)
      error = assert_raises(ReleaseObjectLockAnchors::Error) do
        control.reconcile!(state: journal_state(1), release: release_identity)
      end
      assert_match "COMPLIANCE", error.message
    end
  end

  test "anchors require independently configured and observed STS accounts" do
    with_fake_aws do |environment, _state_path|
      environment["RELEASE_JOURNAL_ANCHOR_2_ACCOUNT_ID"] =
        environment.fetch("RELEASE_JOURNAL_ANCHOR_1_ACCOUNT_ID")
      environment[ReleaseObjectLockAnchors::EXPECTED_ANCHOR_SET_DIGEST_ENVIRONMENT_VARIABLE] =
        ReleaseObjectLockAnchors.anchor_set_digest_from_env!(env: environment)

      error = assert_raises(ReleaseObjectLockAnchors::Error) do
        anchors(environment)
      end
      assert_match "distinct profiles and STS accounts", error.message
    end

    with_fake_aws do |environment, state_path|
      update_fake_state(state_path) do |state|
        state.fetch("profiles").fetch("anchor-b")["account"] = "333333333333"
      end

      error = assert_raises(ReleaseObjectLockAnchors::Error) do
        anchors(environment)
      end
      assert_match "STS account", error.message
    end
  end

  test "anchor set requires a protected digest and production AWS rejects endpoint overrides" do
    with_fake_aws do |environment, _state_path|
      environment.delete(ReleaseObjectLockAnchors::EXPECTED_ANCHOR_SET_DIGEST_ENVIRONMENT_VARIABLE)
      error = assert_raises(ReleaseObjectLockAnchors::Error) { anchors(environment) }
      assert_match "is required", error.message
    end

    with_fake_aws do |environment, _state_path|
      environment[ReleaseObjectLockAnchors::EXPECTED_ANCHOR_SET_DIGEST_ENVIRONMENT_VARIABLE] = "f" * 64
      error = assert_raises(ReleaseObjectLockAnchors::Error) { anchors(environment) }
      assert_match "protected expected digest", error.message
    end

    with_fake_aws do |environment, _state_path|
      environment["RELEASE_JOURNAL_ANCHOR_1_ENDPOINT_URL"] = "https://s3.example.test"
      error = assert_raises(ReleaseObjectLockAnchors::Error) { anchors(environment) }
      assert_match "forbid custom endpoint", error.message
    end
  end

  test "profile endpoint overrides are ignored while compatibility endpoints remain explicit" do
    with_fake_aws do |environment, state_path|
      config = File.join(environment.fetch("HOME"), "aws-config")
      File.binwrite config, <<~CONFIG
        [profile anchor-a]
        endpoint_url = https://redirect.example.test
        services = redirected
        [profile anchor-b]
        endpoint_url = https://redirect.example.test
        services = redirected
        [services redirected]
        s3 =
          endpoint_url = https://s3.redirect.example.test
        sts =
          endpoint_url = https://sts.redirect.example.test
      CONFIG
      environment["AWS_CONFIG_FILE"] = config
      environment["AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"] = "false"

      control = anchors(environment)

      assert_equal true, control.identity.fetch("ignore_configured_endpoint_urls")
      calls = fake_state(state_path).fetch("calls")
      assert calls.all? { _1.fetch("ignore_configured_endpoint_urls") == "true" }
      assert calls.all? { _1.fetch("endpoint_url").nil? }
      assert calls.all? { _1.fetch("environment_keys").include?("AWS_CONFIG_FILE") }
    end

    with_fake_aws do |environment, state_path|
      endpoints = {
        "anchor-a" => "https://s3-a.example.test",
        "anchor-b" => "https://s3-b.example.test"
      }
      environment["RELEASE_JOURNAL_ANCHOR_PROVIDER"] = "s3-compatible"
      environment["RELEASE_JOURNAL_ANCHOR_1_ENDPOINT_URL"] = endpoints.fetch("anchor-a")
      environment["RELEASE_JOURNAL_ANCHOR_2_ENDPOINT_URL"] = endpoints.fetch("anchor-b")
      environment[ReleaseObjectLockAnchors::EXPECTED_ANCHOR_SET_DIGEST_ENVIRONMENT_VARIABLE] =
        ReleaseObjectLockAnchors.anchor_set_digest_from_env!(env: environment)

      control = anchors(environment)

      assert_equal true, control.identity.fetch("ignore_configured_endpoint_urls")
      calls = fake_state(state_path).fetch("calls")
      assert calls.all? { _1.fetch("ignore_configured_endpoint_urls") == "true" }
      calls.each do |call|
        if call.fetch("service") == "sts"
          assert_nil call.fetch("endpoint_url")
        else
          assert_equal endpoints.fetch(call.fetch("profile")), call.fetch("endpoint_url")
        end
      end
    end
  end

  test "authenticated state cannot switch to a freshly configured anchor namespace" do
    with_fake_aws do |environment, _state_path|
      original = anchors(environment)
      state = journal_state(1, anchor_set: original.identity)
      original.reconcile!(state:, release: release_identity)

      changed = environment.merge(
        "RELEASE_JOURNAL_ANCHOR_1_PREFIX" => "campfire/fresh-journal",
        "RELEASE_JOURNAL_ANCHOR_2_PREFIX" => "campfire/fresh-journal"
      )
      changed[ReleaseObjectLockAnchors::EXPECTED_ANCHOR_SET_DIGEST_ENVIRONMENT_VARIABLE] =
        ReleaseObjectLockAnchors.anchor_set_digest_from_env!(env: changed)
      replacement = anchors(changed)

      error = assert_raises(ReleaseObjectLockAnchors::Error) do
        replacement.reconcile!(state:, release: release_identity)
      end
      assert_match "anchor set identity changed", error.message
    end
  end

  test "one unavailable anchor aborts without claiming dual publication" do
    with_fake_aws do |environment, state_path|
      update_fake_state(state_path) do |state|
        state.fetch("buckets").fetch("campfire-release-anchor-b")["unavailable_operations"] =
          [ "put-object" ]
      end

      error = assert_raises(ReleaseObjectLockAnchors::Error) do
        anchors(environment).reconcile!(state: journal_state(1), release: release_identity)
      end
      assert_match "anchor 2", error.message

      state = fake_state(state_path)
      assert_equal 3, state.dig("buckets", "campfire-release-anchor-a", "objects").length
      assert_empty state.dig("buckets", "campfire-release-anchor-b", "objects")
    end
  end

  test "a higher anchored head detects deletion of a valid local suffix" do
    with_fake_aws do |environment, _state_path|
      control = anchors(environment)
      control.reconcile!(state: journal_state(3), release: release_identity)

      error = assert_raises(ReleaseObjectLockAnchors::Error) do
        control.reconcile!(state: journal_state(2), release: release_identity)
      end
      assert_match "deleted local history suffix at revision 2", error.message
    end
  end

  test "anchored heads detect deletion of the complete local history" do
    with_fake_aws do |environment, _state_path|
      control = anchors(environment)
      control.reconcile!(state: journal_state(1), release: release_identity)

      error = assert_raises(ReleaseObjectLockAnchors::Error) do
        control.reconcile!(state: nil, release: release_identity)
      end
      assert_match "wholly deleted local history", error.message

      different_sha = release_identity.merge("sha" => "d" * 40)
      assert_raises(ReleaseObjectLockAnchors::Error) do
        control.reconcile!(state: nil, release: different_sha)
      end
    end
  end

  test "global operation catalog detects deletion of an old complete local operation" do
    with_fake_aws do |environment, _state_path|
      control = anchors(environment)
      state = journal_state(1, anchor_set: control.identity)
      control.reconcile!(state:, release: release_identity)
      assert control.reconcile_catalog!(states: [ state ])

      next_release = {
        "repository" => "basecamp/once-campfire", "version" => "1.2.4",
        "tag" => "v1.2.4", "sha" => "d" * 40
      }
      assert control.reconcile!(state: nil, release: next_release)
      error = assert_raises(ReleaseObjectLockAnchors::Error) do
        control.reconcile_catalog!(states: [])
      end
      assert_match "wholly deleted local operation", error.message
    end
  end

  test "content addresses reject overwrite and version deletion attempts" do
    with_fake_aws do |environment, state_path|
      anchors(environment).reconcile!(state: journal_state(1), release: release_identity)
      state = fake_state(state_path)

      state.fetch("buckets").each_value do |bucket|
      assert_equal 3, bucket.fetch("objects").length
        bucket.fetch("objects").each_value { assert_equal 1, _1.length }
      end
      calls = state.fetch("calls")
      rejected_overwrites = calls.select do |call|
        call.fetch("operation") == "put-object" && call.fetch("arguments").include?("--if-none-match")
      end
      delete_attempts = calls.select { _1.fetch("operation") == "delete-object" }
      assert_operator rejected_overwrites.length, :>=, 12
      assert_equal 6, delete_attempts.length
    end

    with_fake_aws do |environment, state_path|
      update_fake_state(state_path) do |state|
        state.fetch("buckets").fetch("campfire-release-anchor-a")["allow_compliance_delete"] = true
      end

      error = assert_raises(ReleaseObjectLockAnchors::Error) do
        anchors(environment).reconcile!(state: journal_state(1), release: release_identity)
      end
      assert_match "accepted deletion", error.message
    end
  end

  test "interruption after one anchor is repaired idempotently before success" do
    with_fake_aws do |environment, state_path|
      interrupted = anchors(environment, fault_after: ->(anchor, kind, revision) {
        raise SimulatedInterruption if anchor == 1 && kind == "head" && revision == 0
      })

      assert_raises(SimulatedInterruption) do
        interrupted.reconcile!(state: journal_state(1), release: release_identity)
      end
      state = fake_state(state_path)
      assert_equal 3, state.dig("buckets", "campfire-release-anchor-a", "objects").length
      assert_empty state.dig("buckets", "campfire-release-anchor-b", "objects")

      assert anchors(environment).reconcile!(state: journal_state(1), release: release_identity)
      state = fake_state(state_path)
      state.fetch("buckets").each_value { assert_equal 3, _1.fetch("objects").length }
    end
  end

  test "success verifies both immutable checksums and retention while scrubbing inherited secrets" do
    with_fake_aws do |environment, state_path|
      environment.merge!(
        "RELEASE_JOURNAL_AUTHENTICATION_KEY" => "must-not-leak",
        "GH_TOKEN" => "must-not-leak", "AWS_SECRET_ACCESS_KEY" => "must-not-leak"
      )

      assert anchors(environment).reconcile!(state: journal_state(2), release: release_identity)
      state = fake_state(state_path)
      state.fetch("buckets").each_value do |bucket|
        assert_equal 5, bucket.fetch("objects").length
        bucket.fetch("objects").each_value do |versions|
          entry = versions.sole
          assert_equal "COMPLIANCE", entry.fetch("mode")
          assert_equal entry.fetch("checksum"),
            Base64.strict_encode64(Digest::SHA256.digest(Base64.strict_decode64(entry.fetch("source"))))
        end
      end
      state.fetch("calls").map { _1.fetch("environment_keys") }.uniq.each do |environment_keys|
        assert_not_includes environment_keys, "RELEASE_JOURNAL_AUTHENTICATION_KEY"
        assert_not_includes environment_keys, "GH_TOKEN"
        assert_not_includes environment_keys, "AWS_SECRET_ACCESS_KEY"
      end
    end
  end

  test "four-field release identity survives workflow and promotion-prepared anchoring and restart" do
    with_fake_aws do |environment, state_path|
      control = anchors(environment)
      identity = control.identity
      journals = [
        release_journal(identity, "phase_zero"),
        release_journal(identity, "workflow").merge(
          "workflow_run" => {
            "run_id" => "123", "run_attempt" => "1", "operation_nonce" => "9" * 64
          }
        ),
        release_journal(identity, "promotion_prepared").merge(
          "workflow_run" => {
            "run_id" => "123", "run_attempt" => "1", "operation_nonce" => "9" * 64
          },
          "artifacts" => { "workflow_evidence_sha256" => "e" * 64 },
          "channels" => { "github_public" => { "target" => "public", "previous" => "draft" } }
        )
      ]

      journals.each_index do |index|
        state = journal_state_from_journals(journals.first(index + 1))
        assert control.reconcile!(state:, release: release_identity)
      end
      resumed_state = journal_state_from_journals(journals)
      assert anchors(environment).reconcile!(state: resumed_state, release: release_identity)
      assert resumed_state.fetch(:history).all? do |entry|
        entry.dig(:journal, "release").keys.sort == %w[ repository sha tag version ]
      end

      fake_state(state_path).fetch("buckets").each_value do |bucket|
        revision_sources = bucket.fetch("objects").filter_map do |_key, versions|
          entry = versions.sole
          next unless entry.dig("metadata", "kind") == "revision"

          JSON.parse(Base64.strict_decode64(entry.fetch("source")))
        end
        assert_equal 3, revision_sources.length
      end
    end
  end

  test "pending evidence repairs both anchors after each whole-anchor retention fault" do
    %w[ after_first_anchor after_both_anchors ].each do |boundary|
      with_fake_aws do |environment, state_path|
        control = anchors(environment)
        Dir.mktmpdir("release-pending-evidence-source") do |source_directory|
          source = "{\"format_version\":1}\n"
          File.binwrite File.join(source_directory, "release-evidence.json"), source
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
          journal = release_journal(control.identity, "ghcr_immutable").merge(
            "lock_id" => "a" * 64, "workflow_evidence_pending" => contract
          )
          pending_state = journal_state_from_journals([ journal ])
          assert control.reconcile!(state: pending_state, release: release_identity)

          assert_raises(SimulatedInterruption, boundary) do
            control.retain_pending_evidence!(
              journal:, directory: source_directory,
              fault_after: ->(observed) { raise SimulatedInterruption if observed == boundary }
            )
          end

          retained_counts = fake_state(state_path).fetch("buckets").transform_values do |bucket|
            bucket.fetch("objects").values.count do |versions|
              versions.sole.dig("metadata", "kind") == "workflow-evidence"
            end
          end
          assert_equal 1, retained_counts.fetch("campfire-release-anchor-a")
          assert_equal boundary == "after_first_anchor" ? 0 : 1,
            retained_counts.fetch("campfire-release-anchor-b")

          resumed = anchors(environment)
          Dir.mktmpdir("release-pending-evidence-restore") do |destination|
            assert resumed.restore_pending_evidence!(journal:, destination:)
            assert_equal source, File.binread(File.join(destination, "release-evidence.json"))
            assert resumed.retain_pending_evidence!(journal:, directory: destination)
          end

          promoted = JSON.parse(JSON.generate(journal))
          promoted["workflow_evidence"] = promoted.delete("workflow_evidence_pending")
          state = journal_state_from_journals([ journal, promoted ])
          assert resumed.reconcile!(state:, release: release_identity)
          fake_state(state_path).fetch("buckets").each_value do |bucket|
            evidence = bucket.fetch("objects").values.select do |versions|
              versions.sole.dig("metadata", "kind") == "workflow-evidence"
            end
            assert_equal 1, evidence.length
          end
        end
      end
    end
  end

  test "validated workflow evidence bytes restore from both Object Lock anchors" do
    with_fake_aws do |environment, _state_path|
      control = anchors(environment)
      Dir.mktmpdir("release-evidence-source") do |source_directory|
        source = "{\"format_version\":1}\n"
        File.binwrite File.join(source_directory, "release-evidence.json"), source
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
        journal = release_journal(control.identity, "ghcr_immutable").merge(
          "lock_id" => "a" * 64, "workflow_evidence" => contract
        )
        assert control.retain_evidence!(journal:, directory: source_directory)

        state = journal_state_from_journals([ journal ])
        assert control.reconcile!(state:, release: release_identity)
        Dir.mktmpdir("release-evidence-restore") do |destination|
          assert anchors(environment).restore_evidence!(journal:, destination:)
          assert_equal source, File.binread(File.join(destination, "release-evidence.json"))
        end

        journal.fetch("workflow_evidence").dig("files", "release-evidence.json")["sha256"] = "f" * 64
        Dir.mktmpdir("release-evidence-tampered") do |destination|
          assert_raises(ReleaseObjectLockAnchors::Error) do
            control.restore_evidence!(journal:, destination:)
          end
        end
      end
    end
  end

  private
    def anchors(environment, fault_after: ->(_anchor, _kind, _revision) { })
      ReleaseObjectLockAnchors.from_env!(
        env: environment, clock: -> { Time.utc(2026, 8, 2, 12) }, fault_after:
      )
    end

    def with_fake_aws
      Dir.mktmpdir("release-fake-aws") do |directory|
        bin = File.join(directory, "bin")
        FileUtils.mkdir bin
        File.symlink Rails.root.join("test/support/fake_release_aws_cli"), File.join(bin, "aws")
        state_path = File.join(directory, "fake-release-aws.json")
        File.binwrite state_path, JSON.pretty_generate(initial_fake_state) << "\n"
        environment = {
          "HOME" => directory,
          "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
          "RELEASE_JOURNAL_ANCHOR_PROVIDER" => "aws",
          "RELEASE_JOURNAL_ANCHOR_1_PROFILE" => "anchor-a",
          "RELEASE_JOURNAL_ANCHOR_1_ACCOUNT_ID" => "111111111111",
          "RELEASE_JOURNAL_ANCHOR_1_BUCKET" => "campfire-release-anchor-a",
          "RELEASE_JOURNAL_ANCHOR_1_PREFIX" => "campfire/release-journal",
          "RELEASE_JOURNAL_ANCHOR_2_PROFILE" => "anchor-b",
          "RELEASE_JOURNAL_ANCHOR_2_ACCOUNT_ID" => "222222222222",
          "RELEASE_JOURNAL_ANCHOR_2_BUCKET" => "campfire-release-anchor-b",
          "RELEASE_JOURNAL_ANCHOR_2_PREFIX" => "campfire/release-journal"
        }
        environment[ReleaseObjectLockAnchors::EXPECTED_ANCHOR_SET_DIGEST_ENVIRONMENT_VARIABLE] =
          ReleaseObjectLockAnchors.anchor_set_digest_from_env!(env: environment)
        yield environment, state_path
      end
    end

    def initial_fake_state
      {
        "profiles" => {
          "anchor-a" => { "account" => "111111111111" },
          "anchor-b" => { "account" => "222222222222" }
        },
        "buckets" => {
          "campfire-release-anchor-a" => fake_bucket("111111111111"),
          "campfire-release-anchor-b" => fake_bucket("222222222222")
        },
        "calls" => []
      }
    end

    def fake_bucket(account)
      {
        "account" => account, "versioning" => "Enabled", "object_lock" => "Enabled",
        "objects" => {}, "delete_markers" => []
      }
    end

    def update_fake_state(path)
      state = fake_state(path)
      yield state
      File.binwrite path, JSON.pretty_generate(state) << "\n"
    end

    def fake_state(path)
      JSON.parse(File.binread(path))
    end

    def release_identity
      {
        "repository" => "basecamp/once-campfire", "version" => "1.2.3",
        "tag" => "v1.2.3", "sha" => "c" * 40
      }
    end

    def release_journal(anchor_set, phase)
      {
        "format_version" => 5,
        "release" => release_identity,
        "anchor_set" => anchor_set,
        "phase" => phase,
        "created_at" => "2026-08-02T12:00:00Z"
      }
    end

    def journal_state(length, anchor_set: nil)
      anchor_set ||= ReleaseObjectLockAnchors.anchor_set_identity_from_env!(env: default_anchor_environment)
      journals = Array.new(length) { |revision| release_journal(anchor_set, "revision-#{revision}") }
      journal_state_from_journals journals
    end

    def journal_state_from_journals(journals)
      operation_id = "a" * 64
      prior_digest = "0" * 64
      history = journals.each_with_index.map do |source_journal, revision|
        journal = JSON.parse(JSON.generate(source_journal)).merge(
          "lock_id" => operation_id, "journal_revision" => revision
        )
        source = JSON.pretty_generate("revision" => revision, "journal" => journal) << "\n"
        current_digest = Digest::SHA256.hexdigest("#{prior_digest}\0#{source}")
        entry = {
          operation_id:, revision:, prior_digest:, current_digest:, source:,
          journal:
        }
        prior_digest = current_digest
        entry
      end
      { lock_id: operation_id, history:, journal: history.last.fetch(:journal) }
    end

    def default_anchor_environment
      {
        "RELEASE_JOURNAL_ANCHOR_PROVIDER" => "aws",
        "RELEASE_JOURNAL_ANCHOR_1_PROFILE" => "anchor-a",
        "RELEASE_JOURNAL_ANCHOR_1_ACCOUNT_ID" => "111111111111",
        "RELEASE_JOURNAL_ANCHOR_1_BUCKET" => "campfire-release-anchor-a",
        "RELEASE_JOURNAL_ANCHOR_1_PREFIX" => "campfire/release-journal",
        "RELEASE_JOURNAL_ANCHOR_2_PROFILE" => "anchor-b",
        "RELEASE_JOURNAL_ANCHOR_2_ACCOUNT_ID" => "222222222222",
        "RELEASE_JOURNAL_ANCHOR_2_BUCKET" => "campfire-release-anchor-b",
        "RELEASE_JOURNAL_ANCHOR_2_PREFIX" => "campfire/release-journal"
      }
    end
end
