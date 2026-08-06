require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

class ContainerWorkflowTest < ActiveSupport::TestCase
  SOURCE_REVISION = "a" * 40

  test "asset precompile uses a build-only transport mode" do
    dockerfile = Rails.root.join("Dockerfile").read
    precompile = dockerfile.lines.grep(/assets:precompile/).sole

    assert_equal "RUN DISABLE_SSL=true OIDC_MODE=disabled SECRET_KEY_BASE_DUMMY=1 " \
      "./bin/rails assets:precompile\n", precompile
    assert_no_match(/^ENV\s+(?:DISABLE_SSL|OIDC_MODE)=/i, dockerfile)

    validation = Rails.root.join("script/ci/validate-container-image").read
    assert_includes validation, 'startswith("DISABLE_SSL=")'
    assert_includes validation, 'startswith("OIDC_MODE=")'
    assert_includes validation, "asset_precompile_contract='#{precompile.strip}'"
    assert_includes validation, "Container startup without an explicit transport mode succeeded unexpectedly"
  end

  test "container runtime probes use the explicit external HTTPS test contract" do
    validation = Rails.root.join("script/ci/validate-container-image").read
    recovery = Rails.root.join("script/ci/verify-image-recovery").read

    [ validation, recovery ].each do |source|
      assert_includes source, "--env DISABLE_SSL=true"
      assert_includes source, "--env OIDC_MODE=disabled"
      assert_includes source, "X-Forwarded-Proto: https"
      assert_includes source, 'transport_mode: "external-https-loopback-probe"'
      assert_includes source, 'transport_contract: "passed"'
    end
    assert_includes validation, "Container startup without an explicit transport mode succeeded unexpectedly"

    guide = Rails.root.join("docs/self-hosting.md").read
    assert_includes guide, "--volume campfire:/rails/storage --env TLS_DOMAIN=chat.example.com"
    assert_includes guide, "does not authorize plaintext production traffic"
    assert_includes guide, "--publish 127.0.0.1:3000:80 --env DISABLE_SSL=true"
  end

  test "aggregate verifier executes and accepts only exact amd64 and arm64 receipts" do
    workflow = YAML.safe_load(Rails.root.join(".github/workflows/container.yml").read, aliases: false)
    step = workflow.fetch("jobs").fetch("verify-receipts").fetch("steps")
      .find { _1["name"] == "Verify exact amd64 and arm64 receipt set" }
    assert step

    Dir.mktmpdir("campfire-container-receipts") do |directory|
      runner_temp = Pathname(directory)
      %w[ amd64 arm64 ].each { write_evidence(runner_temp, _1) }
      verifier = runner_temp.join("verify-container-receipts")
      verifier.write "#!/usr/bin/env bash\n#{step.fetch("run")}"
      verifier.chmod 0o755
      assert verifier.executable?

      environment = { "RUNNER_TEMP" => runner_temp.to_s, "SOURCE_REVISION" => SOURCE_REVISION }
      _stdout, stderr, status = Open3.capture3(environment, verifier.to_s)
      assert status.success?, stderr

      aggregate = JSON.parse(runner_temp.join("container-architecture-receipt.json").read)
      assert_equal %w[ architectures format_version kind source_revision status transport_mode ],
        aggregate.keys.sort
      assert_equal "campfire-container-architecture-set", aggregate.fetch("kind")
      assert_equal "external-https-loopback-probe", aggregate.fetch("transport_mode")
      assert_equal %w[ amd64 arm64 ], aggregate.fetch("architectures").pluck("architecture")
      assert_equal "passed", aggregate.fetch("status")
      aggregate.fetch("architectures").each do |entry|
        architecture = entry.fetch("architecture")
        source = runner_temp.join("container-receipts", architecture)
        assert_equal %w[
          architecture container_validation_sha256 host_architecture platform receipt_sha256
          recovery_receipt_sha256 run_receipt_sha256 runnable_digest upgrade_receipt_sha256
        ], entry.keys.sort
        assert_equal Digest::SHA256.file(source.join("container-validation.json")).hexdigest,
          entry.fetch("container_validation_sha256")
        assert_equal Digest::SHA256.file(source.join("recovery-receipt.json")).hexdigest,
          entry.fetch("recovery_receipt_sha256")
        assert_equal Digest::SHA256.file(source.join("run.json")).hexdigest,
          entry.fetch("run_receipt_sha256")
        assert_equal Digest::SHA256.file(source.join("upgrade-recovery.json")).hexdigest,
          entry.fetch("upgrade_receipt_sha256")
      end

      %w[ run.json upgrade-recovery.json ].each do |name|
        path = runner_temp.join("container-receipts/arm64", name)
        source = path.binread
        path.delete
        _stdout, _stderr, status = Open3.capture3(environment, verifier.to_s)
        assert_not status.success?, name
        path.binwrite source
      end

      arm64_receipt = runner_temp.join("container-receipts/arm64/receipt.json")
      original_receipt = arm64_receipt.binread
      tampered = JSON.parse(original_receipt).merge("unexpected" => true)
      arm64_receipt.write JSON.generate(tampered)
      _stdout, _stderr, status = Open3.capture3(environment, verifier.to_s)
      assert_not status.success?
      arm64_receipt.binwrite original_receipt

      upgrade_path = runner_temp.join("container-receipts/arm64/upgrade-recovery.json")
      recovery_path = runner_temp.join("container-receipts/arm64/recovery-receipt.json")
      upgrade = JSON.parse(upgrade_path.read).merge("target_revision" => "b" * 40)
      upgrade_path.write JSON.generate(upgrade)
      recovery = JSON.parse(recovery_path.read)
      recovery["upgrade_receipt_sha256"] = Digest::SHA256.file(upgrade_path).hexdigest
      recovery_path.write JSON.generate(recovery)
      receipt = JSON.parse(arm64_receipt.read)
      receipt["upgrade_receipt_sha256"] = Digest::SHA256.file(upgrade_path).hexdigest
      receipt["recovery_receipt_sha256"] = Digest::SHA256.file(recovery_path).hexdigest
      arm64_receipt.write JSON.generate(receipt)
      _stdout, _stderr, status = Open3.capture3(environment, verifier.to_s)
      assert_not status.success?, "self-consistent invalid upgrade receipt"
    end
  end

  test "architecture receipt sealer directly binds run and upgrade source records" do
    workflow = YAML.safe_load(Rails.root.join(".github/workflows/container.yml").read, aliases: false)
    step = workflow.fetch("jobs").fetch("validate").fetch("steps")
      .find { _1["name"] == "Seal container evidence receipt" }
    assert step

    Dir.mktmpdir("campfire-container-sealer") do |directory|
      runner_temp = Pathname(directory)
      write_evidence(runner_temp, "amd64")
      source = runner_temp.join("container-receipts/amd64")
      evidence = runner_temp.join("container-evidence-amd64").tap(&:mkpath)
      %w[ container-validation.json recovery-receipt.json run.json upgrade-recovery.json ].each do |name|
        FileUtils.cp source.join(name), evidence.join(name)
      end
      build_identity = JSON.parse(source.join("receipt.json").read).fetch("build_identity")
      environment = {
        "RUNNER_TEMP" => runner_temp.to_s,
        "ARCHITECTURE" => "amd64",
        "CONTAINER_PLATFORM" => "linux/amd64",
        "EXPECTED_HOST_ARCHITECTURE" => "x86_64",
        "SOURCE_REVISION" => SOURCE_REVISION,
        "TARGET_BUILD_IDENTITY" => build_identity
      }

      _stdout, stderr, status = Open3.capture3(environment, "bash", "-c", step.fetch("run"))
      assert status.success?, stderr

      receipt = JSON.parse(evidence.join("receipt.json").read)
      assert_equal %w[
        architecture build_identity checks config_digest container_validation_sha256 format_version
        host_architecture kind platform recovery_receipt_sha256 run_receipt_sha256 runnable_digest
        source_revision status transport_mode upgrade_receipt_sha256
      ], receipt.keys.sort
      assert_equal Digest::SHA256.file(evidence.join("run.json")).hexdigest,
        receipt.fetch("run_receipt_sha256")
      assert_equal Digest::SHA256.file(evidence.join("upgrade-recovery.json")).hexdigest,
        receipt.fetch("upgrade_receipt_sha256")
    end
  end

  private
    def write_evidence(runner_temp, architecture)
      platform, host_architecture = {
        "amd64" => %w[ linux/amd64 x86_64 ],
        "arm64" => %w[ linux/arm64 aarch64 ]
      }.fetch(architecture)
      directory = runner_temp.join("container-receipts", architecture).tap(&:mkpath)
      build_identity = Digest::SHA256.hexdigest("build-#{architecture}")
      runnable_digest = "sha256:#{Digest::SHA256.hexdigest("manifest-#{architecture}")}"
      config_digest = "sha256:#{Digest::SHA256.hexdigest("config-#{architecture}")}"
      validation = {
        format_version: 1,
        kind: "campfire-container-validation",
        architecture:,
        platform:,
        image: "campfire-ci:#{architecture}-#{SOURCE_REVISION}",
        source_revision: SOURCE_REVISION,
        build_identity:,
        app_version: "ci-#{SOURCE_REVISION[0, 12]}",
        runnable_digest:,
        validated_manifest_digest: runnable_digest,
        config_digest:,
        runtime_binding: "config-digest-matched-dual-build",
        transport_mode: "external-https-loopback-probe",
        image_inspection_sha256: "1" * 64,
        sbom_sha256: "2" * 64,
        buildkit_provenance_sha256: "3" * 64,
        oci_archive_sha256: "4" * 64,
        runtime_archive_sha256: "5" * 64,
        request_limit_probe_bytes: 106_954_752,
        checks: {
          asset_precompile_transport: "passed",
          boot_health: "passed",
          entrypoint_and_labels: "passed",
          graceful_exit_code: 0,
          immutable_runtime_paths: "passed",
          mutable_runtime_directories: "passed",
          non_root_user: "passed",
          platform_config: "passed",
          procps: "passed",
          provenance: "passed",
          request_limit: "HTTP/1.1 413",
          runtime_transport_neutrality: "passed",
          sbom: "passed",
          transport_contract: "passed"
        }
      }
      validation_path = directory.join("container-validation.json")
      validation_path.write JSON.generate(validation)
      validation_sha256 = Digest::SHA256.file(validation_path).hexdigest
      source_schema_version = "20260730000000"
      upgrade = {
        format_version: 2,
        kind: "campfire-upgrade-recovery",
        migration: "CreateIdentities",
        environment: "production",
        target_revision: SOURCE_REVISION,
        target_build_identity: build_identity,
        backup_id: "backup-#{architecture}",
        installation_fingerprint: "6" * 64,
        source_schema_version: source_schema_version.to_i,
        source_state_sha256: "7" * 64,
        source_manifest_sha256: "8" * 64,
        archive_path: "/recovery/#{architecture}.campfire-backup",
        archive_bytes: 123,
        archive_sha256: "9" * 64,
        authentication_path: "/recovery/#{architecture}.campfire-backup",
        authentication_sha256: "9" * 64,
        created_at: "2026-08-05T12:00:00Z",
        expires_at: "2026-08-05T13:00:00Z",
        authentication: {
          algorithm: "HMAC-SHA256", key_id: "a" * 16, mac: "b" * 64
        }
      }
      upgrade_path = directory.join("upgrade-recovery.json")
      upgrade_path.write JSON.generate(upgrade)
      upgrade_sha256 = Digest::SHA256.file(upgrade_path).hexdigest
      recovery = {
        format_version: 1,
        kind: "campfire-image-recovery",
        architecture:,
        platform:,
        source_sha: SOURCE_REVISION,
        release_tag: "ci-#{SOURCE_REVISION}",
        target_reference: validation.fetch(:image),
        target_build_identity: build_identity,
        target_digest: runnable_digest,
        target_manifest_digest: runnable_digest,
        target_config_digest: config_digest,
        runtime_binding: "config-digest-matched-dual-build",
        container_validation_sha256: validation_sha256,
        transport_mode: "external-https-loopback-probe",
        legacy_reference: "ghcr.io/basecamp/once-campfire@sha256:#{'c' * 64}",
        legacy_digest: "sha256:#{'c' * 64}",
        legacy_revision: "d" * 40,
        source_schema_version:,
        upgrade_receipt_sha256: upgrade_sha256,
        current_recovery: {
          artifact_kind: "campfire-backup", artifact_sha256: "e" * 64
        },
        legacy_recovery: {
          artifact_kind: "campfire-backup", artifact_sha256: "f" * 64
        },
        recovery: "passed",
        checks: {
          authorized_upgrade: "passed",
          current_restore: "passed",
          http_history_and_uploads: "passed",
          legacy_restore: "passed",
          migration_denials: "passed",
          tamper_denials: "passed",
          transport_contract: "passed",
          worker_execution: "passed"
        },
        run_id: "123",
        run_attempt: "1"
      }
      recovery_path = directory.join("recovery-receipt.json")
      recovery_path.write JSON.generate(recovery)
      run_receipt = {
        format_version: 1,
        architecture:,
        host_architecture:,
        source_revision: SOURCE_REVISION,
        status: "started"
      }
      run_path = directory.join("run.json")
      run_path.write JSON.generate(run_receipt)
      receipt = {
        format_version: 1,
        kind: "campfire-container-workflow-receipt",
        architecture:,
        platform:,
        host_architecture:,
        source_revision: SOURCE_REVISION,
        build_identity:,
        runnable_digest:,
        config_digest:,
        transport_mode: "external-https-loopback-probe",
        container_validation_sha256: validation_sha256,
        recovery_receipt_sha256: Digest::SHA256.file(recovery_path).hexdigest,
        run_receipt_sha256: Digest::SHA256.file(run_path).hexdigest,
        upgrade_receipt_sha256: upgrade_sha256,
        checks: {
          container_validation: "passed",
          image_recovery: "passed",
          native_host_architecture: "passed"
        },
        status: "passed"
      }
      directory.join("receipt.json").write JSON.generate(receipt)
    end
end
