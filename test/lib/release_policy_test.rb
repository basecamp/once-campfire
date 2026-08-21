require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class ReleasePolicyTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  SCRIPT = Rails.root.join("script/ci/verify-release-policy")
  DIGEST = "sha256:#{'a' * 64}"

  test "repository release dependencies are pinned" do
    stdout, stderr, status = Open3.capture3(SCRIPT.to_s)

    assert status.success?, stderr
    assert_equal "Release and container policy verified\n", stdout
  end

  test "policy rejects mutable Docker workflow and action references" do
    Dir.mktmpdir("campfire-release-policy") do |directory|
      root = Pathname(directory)
      root.join(".github/workflows").mkpath
      root.join("Dockerfile").write <<~DOCKERFILE
        # syntax = docker/dockerfile:1
        FROM ruby:3.4-slim AS base
        FROM base
      DOCKERFILE
      root.join(".github/workflows/ci.yml").write <<~YAML
        jobs:
          test:
            services:
              redis:
                image: redis:7-alpine
            steps:
              - uses: actions/checkout@v4
      YAML

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "frontend must use a verified sha256 manifest digest", stderr
      assert_match "external base image is not digest-pinned", stderr
      assert_match "workflow image is not digest-pinned", stderr
      assert_match "action is not pinned to a full commit", stderr
    end
  end

  test "policy accepts digest-pinned external dependencies and internal stages" do
    Dir.mktmpdir("campfire-release-policy") do |directory|
      root = Pathname(directory)
      root.join(".github/workflows").mkpath
      root.join("Dockerfile").write <<~DOCKERFILE
        # syntax = docker/dockerfile:1@#{DIGEST}
        FROM ruby:3.4-slim@#{DIGEST} AS base
        ENV BUNDLE_WITHOUT="development:test"
        FROM base
      DOCKERFILE
      root.join(".github/workflows/ci.yml").write <<~YAML
        jobs:
          test:
            services:
              redis:
                image: redis:7-alpine@#{DIGEST}
            steps:
              - uses: actions/checkout@#{'b' * 40}
      YAML

      stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert status.success?, stderr
      assert_equal "Release and container policy verified\n", stdout
    end
  end

  test "policy rejects production bundles containing test dependencies" do
    with_repository_policy_fixture do |root|
      dockerfile = root.join("Dockerfile")
      dockerfile.write dockerfile.read.sub('BUNDLE_WITHOUT="development:test"', 'BUNDLE_WITHOUT="development"')

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "production bundle must exclude development and test dependencies", stderr
    end
  end

  test "policy rejects a later production bundle override" do
    with_repository_policy_fixture do |root|
      dockerfile = root.join("Dockerfile")
      dockerfile.write dockerfile.read.sub(
        "# Throw-away build stage",
        "ENV BUNDLE_WITHOUT=\"development\"\n\n# Throw-away build stage"
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "production bundle must exclude development and test dependencies", stderr
    end
  end

  test "policy rejects a bundle-install command override" do
    with_repository_policy_fixture do |root|
      dockerfile = root.join("Dockerfile")
      dockerfile.write dockerfile.read.sub(
        "RUN bundle install",
        "RUN BUNDLE_WITHOUT=development bundle install"
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "production bundle must exclude development and test dependencies", stderr
    end
  end

  test "policy rejects alternate Docker environment override forms" do
    [
      "ENV BUNDLE_WITHOUT development",
      "RUN env -u BUNDLE_WITHOUT bundle install"
    ].each do |override|
      with_repository_policy_fixture do |root|
        dockerfile = root.join("Dockerfile")
        dockerfile.write dockerfile.read.sub(
          "# Throw-away build stage",
          "#{override}\n\n# Throw-away build stage"
        )

        _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

        assert_not status.success?, override
        assert_match "production bundle must exclude development and test dependencies", stderr
      end
    end
  end

  test "policy rejects a skipped container architecture" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read.sub("            arch: arm64\n", "            arch: s390x\n")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "validation matrix must contain exactly linux/amd64 and linux/arm64", stderr
    end
  end

  test "policy requires the aggregate native architecture receipt check" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read.sub("  verify-receipts:\n", "  ignored-receipts:\n")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "required container control is missing: verify-receipts:", stderr
      assert_match "aggregate verify-receipts must always run after the complete native architecture matrix", stderr
    end
  end

  test "policy requires aggregate architecture receipts to run after matrix failures" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read.sub("    if: ${{ always() }}", "    if: ${{ success() }}")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "aggregate verify-receipts must always run after the complete native architecture matrix", stderr
    end
  end

  test "policy requires receipt reporting before an explicit validation-result failure" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read
        .sub(
          "      - name: Download amd64 evidence\n        if: ${{ always() }}\n",
          "      - name: Download amd64 evidence\n        if: ${{ success() }}\n"
        )
        .sub(
          "          VALIDATE_RESULT: ${{ needs.validate.result }}",
          "          VALIDATE_RESULT: ${{ needs.validate.conclusion }}"
        )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "aggregate receipts must be inspected before explicitly requiring validate success", stderr
    end
  end

  test "policy requires aggregate inspection and attestation semantics" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      source = workflow.read
      verifier_start = source.index("      - name: Verify exact amd64 and arm64 receipt set")
      verifier = source[verifier_start..]
        .gsub(
          '.subject[0].digest == {"sha256": $digest}',
          "any(.subject[]?; .digest.sha256 == $digest)"
        )
      workflow.write source[0...verifier_start] + verifier

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "aggregate SBOM and provenance must each bind one exact architecture digest", stderr
    end
  end

  test "policy requires direct run and upgrade receipt hash bindings" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read
        .gsub("run_receipt_sha256", "unbound_run_receipt")
        .gsub("upgrade_receipt_sha256", "unbound_upgrade_receipt")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "required container control is missing: run_receipt_sha256", stderr
      assert_match "required container control is missing: upgrade_receipt_sha256", stderr
    end
  end

  test "policy rejects an unpinned legacy recovery image" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read.sub(
        %r{ghcr\.io/basecamp/once-campfire@sha256:[0-9a-f]{64}},
        "ghcr.io/basecamp/once-campfire:latest"
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "LEGACY_IMAGE is not digest-pinned", stderr
      assert_match "legacy recovery image must be an explicit sha256 digest", stderr
    end
  end

  test "policy rejects mutable BuildKit and SBOM scanner images" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      source = workflow.read
        .sub(%r{docker\.io/moby/buildkit:[^\s]+@sha256:[0-9a-f]{64}}, "docker.io/moby/buildkit:latest")
        .sub(%r{docker\.io/docker/buildkit-syft-scanner:[^\s]+@sha256:[0-9a-f]{64}}, "docker.io/docker/buildkit-syft-scanner:latest")
      workflow.write source

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "BUILDKIT_IMAGE is not digest-pinned", stderr
      assert_match "SBOM_SCANNER_IMAGE is not digest-pinned", stderr
    end
  end

  test "policy rejects release publication without recovery and signed provenance evidence" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      source = workflow.read
        .sub("recovery_receipts:", "recovery_records:")
        .gsub('--source-digest "$RELEASE_SHA"', '--source-digest "$GITHUB_SHA"')
      workflow.write source

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "required release evidence control is missing: recovery_receipts:", stderr
      assert_match 'required release evidence control is missing: --source-digest "$RELEASE_SHA"', stderr
    end
  end

  test "policy requires retained image inspection and digest-bound BuildKit attestations" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      workflow.write workflow.read
        .sub(
          '--arg inspection_sha256 "$(sha256sum "$evidence_directory/image-inspect.json"',
          '--arg inspection_sha256 "$(sha256sum "$evidence_directory/container-validation.json"'
        )
        .gsub(
          '.subject[0].digest == {"sha256": $digest}',
          "any(.subject[]?; .digest.sha256 == $digest)"
        )
      validation = root.join("script/ci/validate-container-image")
      validation.write validation.read.gsub(
        '.subject[0].digest == {"sha256": $digest}',
        "any(.subject[]?; .digest.sha256 == $digest)"
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "image inspection hash must bind the retained image-inspect.json", stderr
      assert_match "SBOM and BuildKit provenance must each bind one exact architecture digest", stderr
      assert_match "missing evidence check: .subject[0].digest", stderr
    end
  end

  test "policy confines the GHCR overwrite probe to a disposable alias" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      workflow.write workflow.read.sub(
        'probe_reference="${canonical_image}:release-mutability-control-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${OPERATION_NONCE:0:16}"',
        'probe_reference="${canonical_image}:${RELEASE_TAG}"'
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "non-destructive GHCR immutability gate is missing", stderr
      assert_match "GHCR mutability probes may target only a disposable operation-bound alias", stderr
    end
  end

  test "policy forbids release-driver conflict probes against production aliases" do
    with_repository_policy_fixture do |root|
      release = root.join("bin/release")
      release.write release.read.sub(
        '"imagetools", "create", "--tag", control_reference,',
        '"imagetools", "create", "--tag", alias_references.first,'
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "production registry aliases may never be conflict-probe targets", stderr
    end
  end

  test "policy pins every GitHub CLI invocation to github.com" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      workflow.write workflow.read.sub("  GH_HOST: github.com\n", "  GH_HOST: attacker.example\n")
      release = root.join("bin/release")
      release.write release.read.sub(
        'GITHUB_CLI_ENVIRONMENT = { "GH_HOST" => "github.com" }.freeze',
        'GITHUB_CLI_ENVIRONMENT = { "GH_HOST" => "attacker.example" }.freeze'
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "required release evidence control is missing: GH_HOST: github.com", stderr
      assert_match "every GitHub CLI invocation must pin GH_HOST to github.com", stderr
    end
  end

  test "policy requires post-lock publication paths to use the monitored mutation runner" do
    mutations = [
      [
        'run! "git", "push", RELEASE_REMOTE, "refs/tags/#{TAG}", runner: live_mutation_runner',
        'run! "git", "push", RELEASE_REMOTE, "refs/tags/#{TAG}"',
        "monitored live-owner mutation control is missing"
      ],
      [
        "journal_anchors.monitor_with! live_mutation_runner",
        "journal_anchors.identity",
        "monitored live-owner mutation control is missing"
      ]
    ]

    mutations.each do |expected, replacement, message|
      with_repository_policy_fixture do |root|
        release = root.join("bin/release")
        release.write release.read.sub(expected, replacement)

        _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

        assert_not status.success?, expected
        assert_match message, stderr
      end
    end
  end

  test "policy rejects subject-less registry attestation summaries" do
    with_repository_policy_fixture do |root|
      validation = root.join("script/ci/validate-container-image")
      validation.write validation.read.sub(
        'docker buildx imagetools inspect "$attestation_image" --raw > "$registry_manifest"',
        'docker buildx imagetools inspect "$attestation_image" --format \'{{json .SBOM}}\' > "$registry_manifest"'
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "subject-less registry attestation summaries are forbidden", stderr
    end
  end

  test "policy requires retained-bundle verification and a sufficient current-image stop timeout" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      workflow.write workflow.read
        .sub('--bundle "$evidence_directory/${kind}-provenance.bundle.jsonl"', '--bundle "$RUNNER_TEMP/other.jsonl"')
        .sub('docker stop --timeout 70 "$source_container"', 'docker stop --timeout 35 "$source_container"')

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "required release evidence control is missing: --bundle", stderr
      assert_match "current-image stop timeout must be at least 70 seconds", stderr
    end
  end

  test "policy permits Sigstore public-good verification for GitHub attestations" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      workflow.write workflow.read.sub(
        "              --deny-self-hosted-runners \\\n",
        "              --no-public-good \\\n              --deny-self-hosted-runners \\\n"
      )
      release = root.join("bin/release")
      release.write release.read.sub(
        '    "--deny-self-hosted-runners",',
        "    \"--no-public-good\",\n    \"--deny-self-hosted-runners\","
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match ".github/workflows/publish-image.yml: Sigstore public-good", stderr
      assert_match "bin/release: Sigstore public-good", stderr
    end
  end

  test "policy requires a fail-closed release environment preflight" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      workflow.write workflow.read
        .sub(".prevent_self_review == true", ".prevent_self_review == false")
        .sub("needs: [ verify, release-environment ]", "needs: verify")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "release environment preflight is missing: .prevent_self_review == true", stderr
      assert_match "registry-writing jobs must depend on the protected release environment preflight", stderr
    end
  end

  test "policy accepts parsed nonce-bound durable release evidence wiring" do
    with_repository_policy_fixture do |root|
      stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert status.success?, stderr
      assert_equal "Release and container policy verified\n", stdout
    end
  end

  test "policy rejects parsed nonce workflow contract mismatches" do
    mutations = [
      [
        ->(source) { source.sub("        type: string\n\nconcurrency:", "        type: boolean\n\nconcurrency:") },
        "workflow_dispatch inputs must be exact required strings"
      ],
      [
        ->(source) { source.sub("run-name: Campfire release ${{ inputs.release_tag }} ${{ inputs.release_sha }} ${{ inputs.operation_nonce }}", "run-name: Campfire release") },
        "run-name must bind the exact release tag, SHA, and operation nonce"
      ],
      [
        ->(source) { source.sub('[[ "$OPERATION_NONCE" =~ ^[0-9a-f]{64}$ ]]', '[[ -n "$OPERATION_NONCE" ]]') },
        "parsed release authorization must validate the exact operation nonce input"
      ],
      [
        ->(source) { source.sub(/(  manifest:.*?      OPERATION_NONCE:) \$\{\{ inputs\.operation_nonce \}\}/m, '\\1 static') },
        "manifest job must bind OPERATION_NONCE to the exact dispatch input"
      ]
    ]

    mutations.each do |mutation, expected_error|
      with_repository_policy_fixture do |root|
        workflow = root.join(".github/workflows/publish-image.yml")
        workflow.write mutation.call(workflow.read)

        _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

        assert_not status.success?, expected_error
        assert_match expected_error, stderr
      end
    end
  end

  test "policy rejects extra or nested final release evidence uploads" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      source = workflow.read.sub(
        "            ${{ runner.temp }}/release-evidence/runnable-provenance-verification-arm64.json\n",
        "            ${{ runner.temp }}/release-evidence/runnable-provenance-verification-arm64.json\n" \
          "            ${{ runner.temp }}/release-evidence/nested/unexpected.json\n"
      )
      workflow.write source

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "release evidence upload must be the exact flat inventory", stderr
    end
  end

  test "policy rejects stale plaintext backup references in recovery CI paths" do
    [ ".tar.gz", ".authentication.json", "BACKUP_AUTHENTICATION_FILE" ].each do |reference|
      with_repository_policy_fixture do |root|
        workflow = root.join(".github/workflows/publish-image.yml")
        workflow.write workflow.read.sub(".campfire-backup", reference)

        _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

        assert_not status.success?
        assert_match "stale plaintext backup reference is forbidden: #{reference}", stderr
      end
    end
  end

  test "policy rejects a reused CI backup encryption key" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      source = workflow.read
      authentication_key = source[/^\s*backup_authentication_key='([^']+)'$/, 1]
      workflow.write source.sub(
        /^\s*backup_encryption_key='[^']+'$/,
        "          backup_encryption_key='#{authentication_key}'"
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "CI backup encryption key must be separate from its authentication key", stderr
    end
  end

  test "policy requires host-owned archives to use the Campfire runtime group" do
    mutations = [
      [
        ".github/workflows/publish-image.yml",
        'archive_json=$(docker run --rm --user "$(id -u):$(id -g)" --group-add 1000',
        'archive_json=$(docker run --rm --user "$(id -u):$(id -g)"',
        "release archive must use the host identity with Campfire runtime group access"
      ],
      [
        "script/ci/verify-image-recovery",
        'archive_json=$(docker_run --rm --user "$(id -u):$(id -g)" --group-add 1000',
        'archive_json=$(docker_run --rm --user "$(id -u):$(id -g)"',
        "archive must use the host identity with Campfire runtime group access"
      ],
      [
        "script/ci/verify-image-recovery",
        '--group-add "$(id -g)"',
        "--group-add 1000",
        "guarded-upgrade archive consumers must add the host group"
      ]
    ]

    mutations.each do |relative, expected, replacement, error|
      with_repository_policy_fixture do |root|
        path = root.join(relative)
        path.write path.read.sub(expected, replacement)

        _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

        assert_not status.success?
        assert_match error, stderr
      end
    end
  end

  test "policy requires the runtime environment for guarded-upgrade authorization" do
    with_repository_policy_fixture do |root|
      recovery = root.join("script/ci/verify-image-recovery")
      source = recovery.read
      source.sub!(
        "  --volume \"$work_directory\":/recovery:ro \\\n" \
          "  \"${runtime_env[@]}\" \\\n" \
          "  --env BACKUP_AUTHENTICATION_KEY=\"$backup_authentication_key\" \\\n",
        "  --volume \"$work_directory\":/recovery:ro \\\n" \
          "  --env BACKUP_AUTHENTICATION_KEY=\"$backup_authentication_key\" \\\n"
      )
      recovery.write source

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "guarded-upgrade authorization must pass the runtime environment", stderr
    end
  end

  test "policy rejects invalid inline archive mutation Ruby" do
    with_repository_policy_fixture do |root|
      recovery = root.join("script/ci/verify-image-recovery")
      recovery.write recovery.read.sub("      begin\n        authentication_key", "        authentication_key")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "archive mutation Ruby must parse", stderr
    end
  end

  test "policy rejects pull request validation with registry mutation authority" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read.sub("      contents: read\n", "      contents: read\n      packages: write\n")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "pull-request validation may not contain packages: write", stderr
    end
  end

  test "policy rejects shared dependency caches in artifact-producing CI" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/ci.yml")
      workflow.write workflow.read.sub(
        "          ruby-version: .ruby-version\n",
        "          ruby-version: .ruby-version\n          bundler-cache: true\n"
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "shared dependency caching is forbidden in artifact-producing CI", stderr
    end
  end

  test "policy rejects an independently rebuilt runtime recovery candidate" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read.sub(
        '          docker load --input "$evidence_directory/campfire.runtime.tar"',
        "          docker buildx build --load --tag detached-runtime .\n" \
          '          docker load --input "$evidence_directory/campfire.runtime.tar"'
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "runtime and OCI evidence must use exactly two config-matched Buildx builds", stderr
    end
  end

  test "policy rejects recovery evidence detached from validated manifest records" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read.sub("TARGET_MANIFEST_PATH", "UNVALIDATED_MANIFEST_PATH")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "required container control is missing: TARGET_MANIFEST_PATH", stderr
    end
  end

  test "policy rejects container branch scope that differs from application CI" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/container.yml")
      workflow.write workflow.read.sub('[ main, "release/**" ]', "[ main ]")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "push and pull-request branches must match application CI", stderr
    end
  end

  test "policy rejects an incomplete shared JavaScript verifier" do
    with_repository_policy_fixture do |root|
      verifier = root.join("script/ci/verify-javascript")
      verifier.write verifier.read.sub("app/views/pwa/service_worker.js", "app/views/pwa/ignored.js")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "missing JavaScript verification contract: app/views/pwa/service_worker.js", stderr
    end
  end

  test "policy rejects conditional manual AT template validation" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/ci.yml")
      workflow.write workflow.read.sub(
        "      - name: Verify manual AT record template\n",
        "      - name: Verify manual AT record template\n        if: startsWith(github.ref, 'refs/heads/release/')\n"
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "manual AT template structure validation must run unconditionally", stderr
    end
  end

  test "policy rejects divergent release and publication executable checks" do
    with_repository_policy_fixture do |root|
      workflow = root.join(".github/workflows/publish-image.yml")
      workflow.write workflow.read.sub("            script/admin/generate-backup-encryption-key\n", "")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "complete aligned entrypoint set", stderr
    end
  end

  test "policy executes the four-field release identity contract" do
    with_repository_policy_fixture do |root|
      release = root.join("bin/release")
      release.write release.read.sub(
        '"workflow_run" => JSON.parse(JSON.generate(workflow_run)),',
        '"release" => JSON.parse(JSON.generate(workflow_run)),'
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "executable immutable-release contract failed", stderr
    end
  end

  test "policy executes the independent GitHub publication and latest-channel contract" do
    with_repository_policy_fixture do |root|
      release = root.join("bin/release")
      release.write release.read.sub('"--latest=false", runner:', '"--latest", runner:')

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "executable immutable-release contract failed", stderr
      assert_match "couples latest-channel mutation", stderr
    end
  end

  test "policy requires journal format 6 for generation-bound moving channels" do
    with_repository_policy_fixture do |root|
      release = root.join("bin/release")
      release.write release.read.sub(
        "RELEASE_JOURNAL_FORMAT_VERSION = 6", "RELEASE_JOURNAL_FORMAT_VERSION = 5"
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "generation-bound moving-channel state requires journal format 6", stderr
    end
  end

  test "policy executes the production AWS endpoint policy" do
    with_repository_policy_fixture do |root|
      anchors = root.join("lib/release_object_lock_anchors.rb")
      anchors.write anchors.read.sub('provider == "aws"', 'provider == "disabled"')

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "executable anchor-set contract failed", stderr
    end
  end

  test "policy rejects disabling configured endpoint suppression" do
    with_repository_policy_fixture do |root|
      anchors = root.join("lib/release_object_lock_anchors.rb")
      anchors.write anchors.read.sub(
        '@anchor_set.fetch("ignore_configured_endpoint_urls").to_s',
        '"false"'
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "executable anchor-set contract failed", stderr
    end
  end

  test "policy rejects a post-workflow freshness check that drops reconciliation mode" do
    with_repository_policy_fixture do |root|
      release = root.join("bin/release")
      release.write release.read.sub(
        "signer_fingerprint: TAG_SIGNER_FINGERPRINT, reconciling:,\n",
        "signer_fingerprint: TAG_SIGNER_FINGERPRINT,\n"
      )

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "every post-workflow source revalidation", stderr
    end
  end

  test "policy rejects removal of pending evidence and authenticated publication controls" do
    [
      [ "workflow_evidence_pending", "workflow_evidence_untracked" ],
      [ "authenticated_github_release_state!", "unchecked_github_release_state!" ]
    ].each do |control, replacement|
      with_repository_policy_fixture do |root|
        release = root.join("bin/release")
        release.write release.read.gsub(control, replacement)

        _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

        assert_not status.success?
        assert_match "durable release transition control is missing: #{control}", stderr
      end
    end
  end

  test "policy requires narrowly scoped unversioned Object Lock delete authority in docs" do
    with_repository_policy_fixture do |root|
      guide = root.join("docs/releasing.md")
      guide.write guide.read.sub("        \"s3:DeleteObject\",\n", "")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match 'required release evidence guidance is missing: "s3:DeleteObject",', stderr
    end
  end

  test "policy requires standalone backup tools to activate bundled gems" do
    with_repository_policy_fixture do |root|
      verifier = root.join("script/admin/verify-backup")
      verifier.write verifier.read.sub("require_relative \"../../config/boot\"\n", "")

      _stdout, stderr, status = Open3.capture3(SCRIPT.to_s, root.to_s)

      assert_not status.success?
      assert_match "standalone backup entrypoint must activate bundled gems", stderr
    end
  end

  private
    def with_repository_policy_fixture
      Dir.mktmpdir("campfire-container-policy") do |directory|
        root = Pathname(directory)
        %w[
          .ruby-version .dockerignore Dockerfile Dockerfile-export
          .github/workflows/ci.yml .github/workflows/container.yml .github/workflows/publish-image.yml
          config/ci.rb bin/load bin/setup bin/boot bin/start-web bin/release
          script/admin/prepare-backup script/admin/verify-backup
          script/admin/archive-backup script/admin/extract-backup
          script/admin/install-backup script/admin/generate-backup-encryption-key
          script/ci/validate-container-image script/ci/verify-image-recovery
          script/ci/verify-release-policy script/ci/verify-javascript
          test/support/accessibility/verify_manual_at_template.rb
           lib/campfire_backup/build_identity.rb lib/release_object_lock_anchors.rb docs/releasing.md
        ].each do |relative|
          source = Rails.root.join(relative)
          destination = root.join(relative)
          destination.dirname.mkpath
          FileUtils.cp source, destination
        end
        yield root
      end
    end
end
