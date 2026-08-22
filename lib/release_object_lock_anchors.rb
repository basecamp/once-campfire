# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tempfile"
require "time"
require "uri"

class ReleaseObjectLockAnchors
  RETENTION_DAYS = 2_557
  FORMAT_VERSION = 1
  ANCHOR_SET_FORMAT_VERSION = 2
  EVIDENCE_FORMAT_VERSION = 1
  DESTRUCTIVE_CONTROL_RETENTION_SECONDS = 10
  DESTRUCTIVE_CONTROL_EXPIRY_MARGIN_SECONDS = 2
  DESTRUCTIVE_CONTROL_NAMESPACE = ".destructive-authority-controls"
  DESTRUCTIVE_CONTROL_NAME_PATTERN = /\Acontrol-([0-9a-f]{32})\.json\z/
  EXACT_RESOURCE_DELETE_INTENT_NAMESPACE = ".exact-resource-delete-marker-intents"
  EXACT_RESOURCE_DELETE_INTENT_NAME_PATTERN = /\Aintent-([0-9a-f]{64})\z/
  PROTECTED_OBJECT_KINDS = %w[ head operation revision workflow-evidence ].freeze
  AWS_CLI_ERROR_RECORD = /\AAn error occurred \(([A-Za-z][A-Za-z0-9]*)\) when calling the ([A-Za-z][A-Za-z0-9]*) operation: ([^\r\n]+)\n?\z/
  IGNORE_CONFIGURED_ENDPOINT_URLS = true
  REQUIRED_CONFIGURATION = %w[ PROFILE ACCOUNT_ID BUCKET PREFIX ].freeze
  PROVIDER_ENVIRONMENT_VARIABLE = "RELEASE_JOURNAL_ANCHOR_PROVIDER"
  EXPECTED_ANCHOR_SET_DIGEST_ENVIRONMENT_VARIABLE = "RELEASE_JOURNAL_EXPECTED_ANCHOR_SET_SHA256"
  PROVIDER_POLICIES = {
    "aws" => "aws-default-endpoints-only",
    "s3-compatible" => "explicit-https-origins"
  }.freeze
  SAFE_ENVIRONMENT = %w[
    HOME PATH AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_CA_BUNDLE
    SSL_CERT_FILE SSL_CERT_DIR LANG LC_ALL
  ].freeze
  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
  OPERATION_PATTERN = /\A[0-9a-f]{64}\z/
  ACCOUNT_PATTERN = /\A[0-9]{12}\z/
  PROFILE_PATTERN = /\A[A-Za-z0-9_+=,.@-]+\z/
  BUCKET_PATTERN = /\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/

  Error = Class.new(defined?(ReleaseStateError) ? ReleaseStateError : StandardError)
  Anchor = Data.define(:number, :profile, :account_id, :bucket, :prefix, :endpoint_url)

  class << self
    def from_env!(env: ENV, clock: -> { Time.now.utc }, executor: nil,
        fault_after: ->(_anchor, _kind, _revision) { },
        control_clock: -> { Time.now.utc }, sleeper: ->(duration) { sleep duration })
      provider, anchors, anchor_set = configuration_from_env!(env)
      expected_digest = env[EXPECTED_ANCHOR_SET_DIGEST_ENVIRONMENT_VARIABLE].to_s
      if expected_digest.empty?
        raise Error,
          "Release journal anchor configuration #{EXPECTED_ANCHOR_SET_DIGEST_ENVIRONMENT_VARIABLE} is required"
      end
      unless expected_digest.match?(DIGEST_PATTERN) && expected_digest == anchor_set.fetch("sha256")
        raise Error, "Release journal anchor set does not match its protected expected digest"
      end

      new(
        anchors:, provider:, anchor_set:, environment: env, clock:, executor:, fault_after:,
        control_clock:, sleeper:
      ).tap(&:validate!)
    end

    def anchor_set_digest_from_env!(env: ENV)
      anchor_set_identity_from_env!(env:).fetch("sha256")
    end

    def anchor_set_identity_from_env!(env: ENV)
      _provider, _anchors, anchor_set = configuration_from_env!(env)
      JSON.parse(JSON.generate(anchor_set))
    end

    def canonical_json(value)
      JSON.generate(canonicalize(value))
    end

    private
      def configuration_from_env!(env)
        provider = env[PROVIDER_ENVIRONMENT_VARIABLE].to_s
        unless PROVIDER_POLICIES.key?(provider)
          raise Error,
            "Release journal anchor configuration #{PROVIDER_ENVIRONMENT_VARIABLE} must be aws or s3-compatible"
        end

        anchors = (1..2).map do |number|
          values = REQUIRED_CONFIGURATION.to_h do |name|
            key = "RELEASE_JOURNAL_ANCHOR_#{number}_#{name}"
            value = env[key].to_s
            raise Error, "Release journal anchor configuration #{key} is required" if value.empty?

            [ name.downcase.to_sym, value ]
          end
          endpoint_url = env["RELEASE_JOURNAL_ANCHOR_#{number}_ENDPOINT_URL"].to_s
          Anchor.new(number:, **values, endpoint_url: endpoint_url.empty? ? nil : endpoint_url)
        end
        endpoints = anchors.map(&:endpoint_url)
        if provider == "aws" && endpoints.any?
          raise Error, "Production dual-AWS release journal anchors forbid custom endpoint overrides"
        end
        if provider == "s3-compatible" && endpoints.any?(&:nil?)
          raise Error, "S3-compatible release journal anchors require an explicit HTTPS endpoint for each anchor"
        end

        descriptor = {
          "format_version" => ANCHOR_SET_FORMAT_VERSION,
          "provider" => provider,
          "endpoint_policy" => PROVIDER_POLICIES.fetch(provider),
          "ignore_configured_endpoint_urls" => IGNORE_CONFIGURED_ENDPOINT_URLS,
          "anchors" => anchors.map do |anchor|
            {
              "number" => anchor.number,
              "account_id" => anchor.account_id,
              "bucket" => anchor.bucket,
              "prefix" => anchor.prefix,
              "endpoint_url" => anchor.endpoint_url
            }
          end
        }
        digest = Digest::SHA256.hexdigest(canonical_json(descriptor))
        [ provider, anchors, descriptor.merge("sha256" => digest) ]
      end

      def canonicalize(value)
        case value
        when Hash
          value.to_h { |key, item| [ key.to_s, canonicalize(item) ] }.sort.to_h
        when Array
          value.map { canonicalize(_1) }
        else
          value
        end
      end
  end

  attr_reader :anchor_set
  alias_method :identity, :anchor_set

  def initialize(anchors:, provider:, anchor_set:, environment: ENV, clock: -> { Time.now.utc }, executor: nil,
      fault_after: ->(_anchor, _kind, _revision) { },
      control_clock: -> { Time.now.utc }, sleeper: ->(duration) { sleep duration })
    @anchors = anchors
    @provider = provider
    @anchor_set = JSON.parse(JSON.generate(anchor_set)).freeze
    @clock = clock
    @control_clock = control_clock
    @sleeper = sleeper
    @fault_after = fault_after
    @destructive_authority = {}
    @recovered_exact_resource_delete_scopes = {}
    @default_retentions = {}
    @environment = SAFE_ENVIRONMENT.filter_map do |name|
      [ name, environment[name] ] if environment.key?(name)
    end.to_h.merge(
      "AWS_PAGER" => "", "AWS_CLI_AUTO_PROMPT" => "off", "AWS_EC2_METADATA_DISABLED" => "true",
      "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS" => @anchor_set.fetch("ignore_configured_endpoint_urls").to_s
    )
    @executor = executor || lambda do |safe_environment, *command|
      Open3.capture3(safe_environment, *command, unsetenv_others: true)
    end
  end

  def validate!
    validate_configuration!
    stdout, stderr, status = @executor.call(@environment, "aws", "--version")
    unless status.success? && "#{stdout}#{stderr}".match?(/aws-cli\/2\./)
      raise Error, "AWS CLI v2 is required on the release host"
    end

    @anchors.each do |anchor|
      identity = json_command!(anchor, "sts", "get-caller-identity", endpoint: false)
      unless identity.fetch("Account", nil) == anchor.account_id
        raise Error, "Release journal anchor #{anchor.number} STS account does not match its configured account"
      end

      command!(anchor, "s3api", "head-bucket", *bucket_arguments(anchor))
      versioning = json_command!(
        anchor, "s3api", "get-bucket-versioning", *bucket_arguments(anchor)
      )
      unless versioning.fetch("Status", nil) == "Enabled"
        raise Error, "Release journal anchor #{anchor.number} bucket versioning is not enabled"
      end

      object_lock = json_command!(
        anchor, "s3api", "get-object-lock-configuration", *bucket_arguments(anchor)
      )
      unless object_lock.fetch("ObjectLockEnabled", nil) == "Enabled"
        raise Error, "Release journal anchor #{anchor.number} Object Lock is not enabled"
      end
      @default_retentions[anchor.number] = validate_default_retention!(
        anchor, object_lock["Rule"]
      )
    end
    @validated = true
  rescue SystemCallError
    raise Error, "AWS CLI v2 is required on the release host"
  rescue KeyError, JSON::ParserError
    raise Error, "Release journal anchor prerequisite response is invalid"
  end

  def monitor_with!(runner)
    @executor = lambda do |safe_environment, *command|
      runner.capture(*command, env: safe_environment, unsetenv_others: true)
    end
    self
  end

  def reconcile!(state:, release:)
    validate! unless @validated
    release = validate_release!(release)
    validate_local_anchor_set!(state) if state
    local = state && local_descriptors(state, release)
    @anchors.each do |anchor|
      recover_exact_resource_delete_markers!(anchor, full_key(anchor, "catalog/operations"))
      recover_exact_resource_delete_markers!(
        anchor, full_key(anchor, "releases/#{release_id(release)}")
      )
    end
    catalogs = @anchors.to_h { [ _1.number, load_operation_catalog(_1) ] }
    compare_operation_catalogs!(catalogs, local, release)
    observed = @anchors.to_h { [ _1.number, load_heads(_1, release) ] }
    compare_with_local!(observed, local, release)
    return true unless local

    operation = operation_descriptor(local.first)
    @anchors.each do |anchor|
      ensure_object!(
        anchor, full_key(anchor, operation.fetch(:key)), operation.fetch(:source),
        operation.fetch(:retain_until), "operation"
      )
      anchored_revisions = observed.fetch(anchor.number).map { _1.fetch(:revision) }
      local.each do |descriptor|
        next if anchored_revisions.include?(descriptor.fetch(:revision))

        ensure_object!(
          anchor, full_key(anchor, descriptor.fetch(:history_key)),
          descriptor.fetch(:history_source), descriptor.fetch(:retain_until), "revision"
        )
        ensure_object!(
          anchor, full_key(anchor, descriptor.fetch(:head_key)), descriptor.fetch(:head_source),
          descriptor.fetch(:retain_until), "head"
        )
      end
    end

    verified_catalogs = @anchors.to_h { [ _1.number, load_operation_catalog(_1) ] }
    compare_operation_catalogs!(verified_catalogs, local, release, require_complete: true)
    verified = @anchors.to_h { [ _1.number, load_heads(_1, release) ] }
    compare_with_local!(verified, local, release, require_complete: true)
    verify_bound_evidence!(state.fetch(:journal))
    true
  end

  def reconcile_catalog!(states:)
    validate! unless @validated
    unless states.is_a?(Array)
      raise Error, "Local release operation inventory is invalid"
    end
    local = states.map do |state|
      validate_local_anchor_set! state
      release = validate_release!(state.fetch(:journal).fetch("release"))
      operation_descriptor(local_descriptors(state, release).first)
    end
    @anchors.each do |anchor|
      recover_exact_resource_delete_markers!(anchor, full_key(anchor, "catalog/operations"))
    end
    if local.map { _1.fetch(:operation_id) }.uniq.length != local.length ||
        local.map { _1.fetch(:release_id) }.uniq.length != local.length
      raise Error, "Local release operation inventory contains a duplicate operation or release identity"
    end
    expected = local.to_h { [ _1.fetch(:source), _1 ] }
    observed = @anchors.to_h { [ _1.number, load_operation_catalog(_1) ] }
    observed.each do |number, entries|
      entries.each do |entry|
        unless expected.key?(entry.fetch(:source))
          raise Error,
            "Global Object Lock operation catalog proves wholly deleted local operation #{entry.fetch(:operation_id)} on anchor #{number}"
        end
      end
    end

    @anchors.each do |anchor|
      anchored = observed.fetch(anchor.number).map { _1.fetch(:source) }
      local.each do |operation|
        next if anchored.include?(operation.fetch(:source))

        ensure_object!(
          anchor, full_key(anchor, operation.fetch(:key)), operation.fetch(:source),
          operation.fetch(:retain_until), "operation"
        )
      end
    end
    verified = @anchors.to_h { [ _1.number, load_operation_catalog(_1) ] }
    verified.each do |number, entries|
      unless entries.map { _1.fetch(:source) }.sort == expected.keys.sort
        raise Error, "Release journal anchor #{number} global operation catalog is incomplete or divergent"
      end
    end
    true
  rescue KeyError, NoMethodError
    raise Error, "Local release operation inventory is invalid"
  end

  def retain_evidence!(journal:, directory:)
    retain_evidence_contract!(
      journal:, directory:, contract_key: "workflow_evidence", fault_after: ->(_boundary) { }
    )
  rescue Errno::ENOENT, KeyError, NoMethodError, ArgumentError
    raise Error, "Workflow evidence retention contract is incomplete"
  end

  def retain_pending_evidence!(journal:, directory:, fault_after: ->(_boundary) { })
    retain_evidence_contract!(
      journal:, directory:, contract_key: "workflow_evidence_pending", fault_after:
    )
  rescue Errno::ENOENT, KeyError, NoMethodError, ArgumentError
    raise Error, "Pending workflow evidence retention contract is incomplete"
  end

  def restore_evidence!(journal:, destination:)
    restore_evidence_contract!(
      journal:, destination:, contract_key: "workflow_evidence", allow_incomplete: false
    )
  rescue Errno::ENOENT, KeyError, NoMethodError, ArgumentError
    raise Error, "Workflow evidence restore contract is incomplete"
  end

  def restore_pending_evidence!(journal:, destination:)
    restore_evidence_contract!(
      journal:, destination:, contract_key: "workflow_evidence_pending", allow_incomplete: true
    )
  rescue Errno::ENOENT, KeyError, NoMethodError, ArgumentError
    raise Error, "Pending workflow evidence restore contract is incomplete"
  end

  private
    def validate_default_retention!(anchor, rule)
      return unless rule

      unless rule.is_a?(Hash) && rule.keys == [ "DefaultRetention" ]
        raise Error, "Release journal anchor #{anchor.number} default retention rule is invalid"
      end
      retention = rule.fetch("DefaultRetention")
      period_keys = %w[ Days Years ].select { retention&.key?(_1) }
      unless retention.is_a?(Hash) &&
          (retention.keys - %w[ Days Mode Years ]).empty? &&
          %w[ COMPLIANCE GOVERNANCE ].include?(retention["Mode"]) &&
          period_keys.one? && retention.fetch(period_keys.sole).is_a?(Integer) &&
          retention.fetch(period_keys.sole).positive?
        raise Error, "Release journal anchor #{anchor.number} default retention rule is invalid"
      end
      JSON.parse(JSON.generate(retention))
    rescue KeyError, NoMethodError
      raise Error, "Release journal anchor #{anchor.number} default retention rule is invalid"
    end

    def evidence_context!(journal, contract_key)
      validate! unless @validated
      validate_local_anchor_set!({ journal: })
      if journal.key?("workflow_evidence") && journal.key?("workflow_evidence_pending")
        raise Error, "Workflow evidence cannot be pending and retained simultaneously"
      end
      release = validate_release!(journal.fetch("release"))
      contract = validate_evidence_contract!(journal.fetch(contract_key))
      operation_id = journal.fetch("lock_id")
      created_at = Time.iso8601(journal.fetch("created_at")).utc
      unless operation_id.match?(OPERATION_PATTERN)
        raise Error, "Workflow evidence operation identity is invalid"
      end
      {
        release:, contract:, operation_id:,
        retain_until: created_at + RETENTION_DAYS * 86_400
      }
    end

    def evidence_sources!(directory, contract)
      expected_names = contract.fetch("files").keys.sort
      unless Dir.children(directory).sort == expected_names
        raise Error, "Workflow evidence directory does not exactly match its authenticated contract"
      end

      contract.fetch("files").to_h do |name, metadata|
        path = File.join(directory, name)
        stat = File.lstat(path)
        source = File.binread(path)
        unless stat.file? && !stat.symlink? && stat.nlink == 1 &&
            stat.size == metadata.fetch("bytes") &&
            Digest::SHA256.hexdigest(source) == metadata.fetch("sha256")
          raise Error, "Workflow evidence file #{name} differs from its authenticated contract"
        end
        [ name, source ]
      end
    end

    def retain_evidence_contract!(journal:, directory:, contract_key:, fault_after:)
      context = evidence_context!(journal, contract_key)
      contract = context.fetch(:contract)
      sources = evidence_sources!(directory, contract)
      @anchors.each_with_index do |anchor, index|
        contract.fetch("files").each do |name, metadata|
          key = evidence_key(
            context.fetch(:release), context.fetch(:operation_id), name, metadata.fetch("sha256")
          )
          ensure_object!(
            anchor, full_key(anchor, key), sources.fetch(name), context.fetch(:retain_until),
            "workflow-evidence"
          )
        end
        fault_after.call "after_first_anchor" if index.zero?
      end
      verify_evidence_objects!(journal, contract_key:)
      fault_after.call "after_both_anchors"
      true
    end

    def restore_evidence_contract!(journal:, destination:, contract_key:, allow_incomplete:)
      context = evidence_context!(journal, contract_key)
      contract = context.fetch(:contract)
      @anchors.each do |anchor|
        recover_exact_resource_delete_markers!(
          anchor, full_key(anchor, "releases/#{release_id(context.fetch(:release))}")
        )
      end
      FileUtils.mkdir_p destination
      unless Dir.children(destination).empty?
        raise Error, "Workflow evidence restore destination must be empty"
      end

      incomplete = false
      restored = contract.fetch("files").to_h do |name, metadata|
        key = evidence_key(
          context.fetch(:release), context.fetch(:operation_id), name, metadata.fetch("sha256")
        )
        objects = if allow_incomplete
          @anchors.filter_map do |anchor|
            read_optional_object!(
              anchor, full_key(anchor, key), expected_sha256: metadata.fetch("sha256"),
              expected_kind: "workflow-evidence", required_until: context.fetch(:retain_until)
            )
          end
        else
          @anchors.map do |anchor|
            read_object!(
              anchor, full_key(anchor, key), expected_sha256: metadata.fetch("sha256"),
              expected_kind: "workflow-evidence", required_until: context.fetch(:retain_until)
            )
          end
        end
        if objects.empty? && allow_incomplete
          incomplete = true
          next [ name, nil ]
        end

        sources = objects.map { _1.fetch(:source) }.uniq
        unless sources.one? && sources.sole.bytesize == metadata.fetch("bytes")
          raise Error, "Workflow evidence anchors disagree for #{name}"
        end
        [ name, sources.sole ]
      end
      return false if incomplete

      restored.each do |name, source|
        Tempfile.create([ ".#{name}", ".tmp" ], destination) do |temporary|
          temporary.binmode
          temporary.chmod(0o600)
          temporary.write source
          temporary.flush
          temporary.fsync
          File.rename temporary.path, File.join(destination, name)
        end
      end
      true
    end

    def read_optional_object!(anchor, key, expected_sha256:, expected_kind:, required_until:)
      versions = exact_versions(anchor, key)
      return if versions.fetch(:versions).empty? && versions.fetch(:delete_markers).empty?

      read_object!(
        anchor, key, expected_sha256:, expected_kind:, required_until:
      )
    end

    def verify_evidence_objects!(journal, contract_key:)
      context = evidence_context!(journal, contract_key)
      context.fetch(:contract).fetch("files").each do |name, metadata|
        key = evidence_key(
          context.fetch(:release), context.fetch(:operation_id), name, metadata.fetch("sha256")
        )
        objects = @anchors.map do |anchor|
          read_object!(
            anchor, full_key(anchor, key), expected_sha256: metadata.fetch("sha256"),
            expected_kind: "workflow-evidence", required_until: context.fetch(:retain_until)
          )
        end
        unless objects.map { _1.fetch(:source) }.uniq.one? &&
            objects.first.fetch(:source).bytesize == metadata.fetch("bytes")
          raise Error, "Workflow evidence anchors disagree for #{name}"
        end
      end
      true
    end

    def validate_configuration!
      unless PROVIDER_POLICIES.fetch(@provider, nil) == @anchor_set.fetch("endpoint_policy", nil) &&
          @anchor_set.fetch("format_version", nil) == ANCHOR_SET_FORMAT_VERSION &&
          @anchor_set.fetch("sha256", nil)&.match?(DIGEST_PATTERN)
        raise Error, "Release journal anchor set identity is invalid"
      end
      expected_descriptor = {
        "format_version" => ANCHOR_SET_FORMAT_VERSION,
        "provider" => @provider,
        "endpoint_policy" => PROVIDER_POLICIES.fetch(@provider),
        "ignore_configured_endpoint_urls" => IGNORE_CONFIGURED_ENDPOINT_URLS,
        "anchors" => @anchors.map do |anchor|
          {
            "number" => anchor.number, "account_id" => anchor.account_id,
            "bucket" => anchor.bucket, "prefix" => anchor.prefix,
            "endpoint_url" => anchor.endpoint_url
          }
        end
      }
      expected_digest = Digest::SHA256.hexdigest(self.class.canonical_json(expected_descriptor))
      unless @anchor_set == expected_descriptor.merge("sha256" => expected_digest)
        raise Error, "Release journal anchor set descriptor changed"
      end
      unless @anchors.length == 2 && @anchors.map(&:profile).uniq.length == 2 &&
          @anchors.map(&:account_id).uniq.length == 2
        raise Error, "Release journal anchors require two distinct profiles and STS accounts"
      end

      @anchors.each do |anchor|
        unless anchor.profile.match?(PROFILE_PATTERN)
          raise Error, "Release journal anchor #{anchor.number} profile is invalid"
        end
        unless anchor.account_id.match?(ACCOUNT_PATTERN)
          raise Error, "Release journal anchor #{anchor.number} account ID is invalid"
        end
        unless valid_bucket?(anchor.bucket)
          raise Error, "Release journal anchor #{anchor.number} bucket is invalid"
        end
        unless valid_prefix?(anchor.prefix)
          raise Error, "Release journal anchor #{anchor.number} prefix is invalid"
        end
        validate_endpoint!(anchor)
      end
    end

    def validate_local_anchor_set!(state)
      journal = state.fetch(:journal)
      unless journal.is_a?(Hash) && journal.fetch("anchor_set") == @anchor_set
        raise Error, "Authenticated release journal anchor set identity changed"
      end
      true
    rescue KeyError, NoMethodError
      raise Error, "Authenticated release journal anchor set identity is missing"
    end

    def valid_bucket?(bucket)
      bucket.match?(BUCKET_PATTERN) && !bucket.include?("..") &&
        !bucket.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/)
    end

    def valid_prefix?(prefix)
      prefix.ascii_only? && prefix.bytesize.between?(1, 512) &&
        !prefix.start_with?("/") && !prefix.end_with?("/") &&
        prefix.split("/").all? { _1.match?(/\A[A-Za-z0-9][A-Za-z0-9._=-]*\z/) && !%w[ . .. ].include?(_1) }
    end

    def validate_endpoint!(anchor)
      return unless anchor.endpoint_url

      uri = URI.parse(anchor.endpoint_url)
      unless uri.scheme == "https" && uri.host && uri.userinfo.nil? && uri.query.nil? &&
          uri.fragment.nil? && [ "", "/" ].include?(uri.path)
        raise Error, "Release journal anchor #{anchor.number} endpoint URL must be an HTTPS origin"
      end
    rescue URI::InvalidURIError
      raise Error, "Release journal anchor #{anchor.number} endpoint URL is invalid"
    end

    def validate_release!(release)
      unless release.is_a?(Hash) && release.keys.sort == %w[ repository sha tag version ] &&
          release.fetch("repository").match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/) &&
          release.fetch("version").match?(/\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z/) &&
          release.fetch("tag") == "v#{release.fetch('version')}" &&
          release.fetch("sha").match?(/\A[0-9a-f]{40}\z/)
        raise Error, "Release journal anchor release identity is invalid"
      end
      JSON.parse(JSON.generate(release))
    rescue KeyError, NoMethodError
      raise Error, "Release journal anchor release identity is invalid"
    end

    def local_descriptors(state, release)
      history = state.fetch(:history)
      lock_id = state.fetch(:lock_id)
      unless lock_id.match?(OPERATION_PATTERN) && history.is_a?(Array) && history.any?
        raise Error, "Local release journal history cannot be anchored"
      end

      created_at = Time.iso8601(history.first.fetch(:journal).fetch("created_at")).utc
      retain_until = created_at + RETENTION_DAYS * 86_400
      prior = "0" * 64
      history.each_with_index.map do |entry, revision|
        source = entry.fetch(:source)
        source_sha256 = Digest::SHA256.hexdigest(source)
        unless entry.fetch(:operation_id) == lock_id && entry.fetch(:revision) == revision &&
            entry.fetch(:prior_digest) == prior && entry.fetch(:current_digest).match?(DIGEST_PATTERN) &&
            entry.fetch(:journal).fetch("release") == release &&
            entry.fetch(:journal).fetch("created_at") == history.first.fetch(:journal).fetch("created_at")
          raise Error, "Local release journal chain differs from its anchor contract"
        end
        prior = entry.fetch(:current_digest)
        descriptor(
          release:, created_at:, retain_until:, operation_id: lock_id, revision:,
          prior_digest: entry.fetch(:prior_digest), current_digest: entry.fetch(:current_digest),
          history_source: source, history_sha256: source_sha256
        )
      end
    rescue KeyError, NoMethodError, ArgumentError
      raise Error, "Local release journal history cannot be anchored"
    end

    def operation_descriptor(genesis)
      release = genesis.fetch(:release)
      payload = {
        "format_version" => FORMAT_VERSION,
        "anchor_set_sha256" => @anchor_set.fetch("sha256"),
        "release" => release,
        "release_id" => release_id(release),
        "release_created_at" => genesis.fetch(:created_at).iso8601,
        "operation_id" => genesis.fetch(:operation_id),
        "genesis_current_digest" => genesis.fetch(:current_digest),
        "genesis_history_sha256" => genesis.fetch(:history_sha256),
        "retention" => {
          "mode" => "COMPLIANCE", "retain_until" => genesis.fetch(:retain_until).iso8601
        }
      }
      source = JSON.pretty_generate(payload) << "\n"
      digest = Digest::SHA256.hexdigest(source)
      key = [
        "catalog", "operations", genesis.fetch(:operation_id),
        "#{release_id(release)}-#{digest}.json"
      ].join("/")
      genesis.merge(key:, source:, source_sha256: digest)
    end

    def load_operation_catalog(anchor)
      scope = full_key(anchor, "catalog/operations")
      prefix = "#{scope}/"
      inventory = list_versions(anchor, prefix)
      control_prefix = destructive_control_prefix(scope)
      controls = inventory.transform_values do |entries|
        entries.select { _1.fetch("Key").start_with?(control_prefix) }
      end
      recover_stale_destructive_controls!(anchor, scope, inventory: controls) if controls.values.any?(&:any?)
      inventory = inventory.transform_values do |entries|
        entries.reject { _1.fetch("Key").start_with?(control_prefix) }
      end
      unless inventory.fetch(:delete_markers).empty?
        raise Error, "Release journal anchor #{anchor.number} contains an operation-catalog deletion marker"
      end
      grouped = inventory.fetch(:versions).group_by { _1.fetch("Key") }
      if grouped.values.any? { _1.length != 1 }
        raise Error, "Release journal anchor #{anchor.number} contains overwritten operation-catalog objects"
      end

      entries = grouped.map do |key, versions|
        object = read_object!(anchor, key, expected_kind: "operation", version: versions.sole)
        payload = JSON.parse(object.fetch(:source))
        validate_remote_operation!(anchor, key, payload, object)
      end
      grouped_releases = entries.group_by { _1.fetch(:release_id) }
      if grouped_releases.values.any? { _1.length != 1 }
        raise Error, "Release journal anchor #{anchor.number} contains multiple operations for one release identity"
      end
      entries.sort_by { [ _1.fetch(:release_id), _1.fetch(:operation_id) ] }
    rescue JSON::ParserError
      raise Error, "Release journal anchor #{anchor.number} operation catalog payload is invalid"
    end

    def validate_remote_operation!(anchor, key, payload, object)
      expected_keys = %w[
        anchor_set_sha256 format_version genesis_current_digest genesis_history_sha256
        operation_id release release_created_at release_id retention
      ]
      release = validate_release!(payload.fetch("release"))
      created_at = Time.iso8601(payload.fetch("release_created_at")).utc
      retain_until = created_at + RETENTION_DAYS * 86_400
      retention = payload.fetch("retention")
      unless payload.keys.sort == expected_keys && payload.fetch("format_version") == FORMAT_VERSION &&
          payload.fetch("anchor_set_sha256") == @anchor_set.fetch("sha256") &&
          payload.fetch("release_id") == release_id(release) &&
          payload.fetch("operation_id").match?(OPERATION_PATTERN) &&
          payload.fetch("genesis_current_digest").match?(DIGEST_PATTERN) &&
          payload.fetch("genesis_history_sha256").match?(DIGEST_PATTERN) &&
          retention == { "mode" => "COMPLIANCE", "retain_until" => retain_until.iso8601 }
        raise Error, "Release journal anchor #{anchor.number} operation catalog contract is invalid"
      end

      descriptor = operation_descriptor({
        release:, release_id: release_id(release), created_at:, retain_until:,
        operation_id: payload.fetch("operation_id"), revision: 0,
        prior_digest: "0" * 64, current_digest: payload.fetch("genesis_current_digest"),
        history_sha256: payload.fetch("genesis_history_sha256")
      })
      unless key == full_key(anchor, descriptor.fetch(:key)) &&
          object.fetch(:sha256) == descriptor.fetch(:source_sha256) &&
          object.fetch(:source) == descriptor.fetch(:source) && object.fetch(:retain_until) >= retain_until
        raise Error, "Release journal anchor #{anchor.number} operation catalog address is invalid"
      end
      descriptor
    rescue KeyError, NoMethodError, ArgumentError
      raise Error, "Release journal anchor #{anchor.number} operation catalog contract is invalid"
    end

    def compare_operation_catalogs!(observed, local, release, require_complete: false)
      release_identifier = release_id(release)
      historical = observed.transform_values do |entries|
        entries.reject { _1.fetch(:release_id) == release_identifier }.map { _1.fetch(:source) }.sort
      end
      unless historical.values.uniq.one?
        raise Error, "Release journal anchors disagree on the global operation catalog"
      end

      matching = observed.transform_values do |entries|
        entries.select { _1.fetch(:release_id) == release_identifier }
      end
      unless local
        if matching.values.any?(&:any?)
          raise Error,
            "Global Object Lock operation catalog proves wholly deleted local history for #{release.fetch('tag')}"
        end
        return true
      end

      expected = operation_descriptor(local.first)
      matching.each do |number, entries|
        if entries.length > 1
          raise Error, "Release journal anchor #{number} contains conflicting release operations"
        end
        if entries.any? && entries.sole.fetch(:source) != expected.fetch(:source)
          raise Error, "Release journal anchor #{number} proves a different operation for this release identity"
        end
        if require_complete && entries.empty?
          raise Error, "Release journal anchor #{number} did not retain the global operation catalog entry"
        end
      end
      true
    end

    def descriptor(release:, created_at:, retain_until:, operation_id:, revision:, prior_digest:,
        current_digest:, history_source:, history_sha256:, history_bytes: history_source.bytesize)
      release_id = release_id(release)
      history_key = [
        "releases", release_id, "operations", operation_id, "revisions",
        "#{format('%020d', revision)}-#{current_digest}-#{history_sha256}.json"
      ].join("/")
      payload = {
        "format_version" => FORMAT_VERSION,
        "release" => release,
        "release_id" => release_id,
        "release_created_at" => created_at.iso8601,
        "operation_id" => operation_id,
        "revision" => revision,
        "prior_digest" => prior_digest,
        "current_digest" => current_digest,
        "history" => {
          "key" => history_key, "sha256" => history_sha256, "bytes" => history_bytes
        },
        "retention" => { "mode" => "COMPLIANCE", "retain_until" => retain_until.iso8601 }
      }
      head_source = JSON.pretty_generate(payload) << "\n"
      head_sha256 = Digest::SHA256.hexdigest(head_source)
      head_key = [
        "releases", release_id, "heads", operation_id,
        "#{format('%020d', revision)}-#{current_digest}-#{history_sha256}-#{head_sha256}.json"
      ].join("/")
      {
        release:, release_id:, created_at:, retain_until:, operation_id:, revision:,
        prior_digest:, current_digest:, history_source:, history_sha256:, history_key:,
        head_source:, head_sha256:, head_key:
      }
    end

    def release_id(release)
      slot = release.slice("repository", "version", "tag")
      Digest::SHA256.hexdigest(self.class.canonical_json(slot))
    end

    def load_heads(anchor, release)
      prefix = full_key(anchor, "releases/#{release_id(release)}/heads/")
      inventory = list_versions(anchor, prefix)
      unless inventory.fetch(:delete_markers).empty?
        raise Error, "Release journal anchor #{anchor.number} contains a head deletion marker"
      end
      grouped = inventory.fetch(:versions).group_by { _1.fetch("Key") }
      if grouped.values.any? { _1.length != 1 }
        raise Error, "Release journal anchor #{anchor.number} contains overwritten head objects"
      end

      heads = grouped.map do |key, versions|
        object = read_object!(anchor, key, expected_kind: "head", version: versions.first)
        payload = JSON.parse(object.fetch(:source))
        validate_remote_head!(anchor, key, payload, object, release)
      end
      validate_remote_chain!(anchor, heads)
      heads.sort_by { _1.fetch(:revision) }
    rescue JSON::ParserError
      raise Error, "Release journal anchor #{anchor.number} head payload is invalid"
    end

    def validate_remote_head!(anchor, key, payload, object, release)
      expected_keys = %w[
        current_digest format_version history operation_id prior_digest release release_created_at
        release_id retention revision
      ]
      history = payload.fetch("history")
      retention = payload.fetch("retention")
      created_at = Time.iso8601(payload.fetch("release_created_at")).utc
      retain_until = Time.iso8601(retention.fetch("retain_until")).utc
      unless payload.keys.sort == expected_keys && payload.fetch("format_version") == FORMAT_VERSION &&
          payload.fetch("release") == release && payload.fetch("release_id") == release_id(release) &&
          payload.fetch("operation_id").match?(OPERATION_PATTERN) &&
          payload.fetch("revision").is_a?(Integer) && payload.fetch("revision") >= 0 &&
          payload.fetch("prior_digest").match?(DIGEST_PATTERN) &&
          payload.fetch("current_digest").match?(DIGEST_PATTERN) &&
          history.is_a?(Hash) && history.keys.sort == %w[ bytes key sha256 ] &&
          history.fetch("sha256").match?(DIGEST_PATTERN) && history.fetch("bytes").is_a?(Integer) &&
          history.fetch("bytes").positive? && retention == {
            "mode" => "COMPLIANCE", "retain_until" => (created_at + RETENTION_DAYS * 86_400).iso8601
          }
        raise Error, "Release journal anchor #{anchor.number} head contract is invalid"
      end

      expected = descriptor(
        release:, created_at:, retain_until:, operation_id: payload.fetch("operation_id"),
        revision: payload.fetch("revision"), prior_digest: payload.fetch("prior_digest"),
        current_digest: payload.fetch("current_digest"), history_source: "",
        history_sha256: history.fetch("sha256"), history_bytes: history.fetch("bytes")
      )
      expected_head_key = full_key(anchor, expected.fetch(:head_key))
      unless key == expected_head_key && object.fetch(:sha256) == expected.fetch(:head_sha256) &&
          object.fetch(:retain_until) >= retain_until
        raise Error, "Release journal anchor #{anchor.number} head address or retention is invalid"
      end

      history_key = full_key(anchor, history.fetch("key"))
      history_object = read_object!(
        anchor, history_key, expected_sha256: history.fetch("sha256"),
        expected_kind: "revision", required_until: retain_until
      )
      unless history_object.fetch(:source).bytesize == history.fetch("bytes")
        raise Error, "Release journal anchor #{anchor.number} revision size is invalid"
      end
      expected = descriptor(
        release:, created_at:, retain_until:, operation_id: payload.fetch("operation_id"),
        revision: payload.fetch("revision"), prior_digest: payload.fetch("prior_digest"),
        current_digest: payload.fetch("current_digest"), history_source: history_object.fetch(:source),
        history_sha256: history.fetch("sha256")
      )
      unless key == full_key(anchor, expected.fetch(:head_key)) &&
          object.fetch(:source) == expected.fetch(:head_source)
        raise Error, "Release journal anchor #{anchor.number} head content address is invalid"
      end
      expected
    rescue KeyError, NoMethodError, ArgumentError
      raise Error, "Release journal anchor #{anchor.number} head contract is invalid"
    end

    def validate_remote_chain!(anchor, heads)
      grouped = heads.group_by { _1.fetch(:revision) }
      if grouped.values.any? { _1.length != 1 }
        raise Error, "Release journal anchor #{anchor.number} contains a forked head revision"
      end
      return if heads.empty?

      operations = heads.map { _1.fetch(:operation_id) }.uniq
      revisions = grouped.keys.sort
      unless operations.one? && revisions == (0..revisions.last).to_a
        raise Error, "Release journal anchor #{anchor.number} head chain is incomplete"
      end
      revisions.each do |revision|
        entry = grouped.fetch(revision).first
        prior = revision.zero? ? "0" * 64 : grouped.fetch(revision - 1).first.fetch(:current_digest)
        unless entry.fetch(:prior_digest) == prior
          raise Error, "Release journal anchor #{anchor.number} head chain is broken"
        end
      end
    end

    def compare_with_local!(observed, local, release, require_complete: false)
      unless local
        unless observed.values.all?(&:empty?)
          raise Error,
            "Anchored release history exists for #{release.fetch('tag')} but local authenticated history is wholly absent"
        end
        return true
      end

      expected = local.to_h { [ _1.fetch(:revision), _1 ] }
      observed.each do |number, heads|
        heads.each do |head|
          local_head = expected[head.fetch(:revision)]
          unless local_head
            raise Error,
              "Release journal anchor #{number} proves a deleted local history suffix at revision #{head.fetch(:revision)}"
          end
          unless head.fetch(:operation_id) == local_head.fetch(:operation_id) &&
              head.fetch(:head_source) == local_head.fetch(:head_source) &&
              head.fetch(:history_source) == local_head.fetch(:history_source)
            raise Error, "Release journal anchor #{number} disagrees with local authenticated history"
          end
        end
        if require_complete && heads.length != local.length
          raise Error, "Release journal anchor #{number} did not retain every local journal head"
        end
      end
      true
    end

    def validate_evidence_contract!(contract)
      expected_keys = %w[ files format_version operation_nonce run_attempt run_id ]
      unless contract.is_a?(Hash) && contract.keys.sort == expected_keys &&
          contract.fetch("format_version") == EVIDENCE_FORMAT_VERSION &&
          contract.fetch("operation_nonce").match?(OPERATION_PATTERN) &&
          contract.fetch("run_id").match?(/\A[1-9][0-9]*\z/) &&
          contract.fetch("run_attempt").match?(/\A[1-9][0-9]*\z/) &&
          contract.fetch("files").is_a?(Hash) && contract.fetch("files").any?
        raise Error, "Authenticated workflow evidence contract is invalid"
      end
      contract.fetch("files").each do |name, metadata|
        unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,199}\z/) &&
            metadata.is_a?(Hash) && metadata.keys.sort == %w[ bytes sha256 ] &&
            metadata.fetch("bytes").is_a?(Integer) && metadata.fetch("bytes").positive? &&
            metadata.fetch("sha256").match?(DIGEST_PATTERN)
          raise Error, "Authenticated workflow evidence file contract is invalid"
        end
      end
      contract
    rescue KeyError, NoMethodError
      raise Error, "Authenticated workflow evidence contract is invalid"
    end

    def evidence_key(release, operation_id, name, digest)
      unless operation_id.match?(OPERATION_PATTERN) && digest.match?(DIGEST_PATTERN) &&
          name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,199}\z/)
        raise Error, "Workflow evidence object address is invalid"
      end
      [
        "releases", release_id(release), "operations", operation_id, "workflow-evidence",
        "#{digest}-#{name}"
      ].join("/")
    end

    def verify_bound_evidence!(journal)
      if journal.key?("workflow_evidence") && journal.key?("workflow_evidence_pending")
        raise Error, "Workflow evidence cannot be pending and retained simultaneously"
      end
      if journal.key?("workflow_evidence_pending")
        evidence_context!(journal, "workflow_evidence_pending")
        return true
      end
      return true unless journal.key?("workflow_evidence")

      verify_evidence_objects!(journal, contract_key: "workflow_evidence")
    rescue KeyError, NoMethodError, ArgumentError
      raise Error, "Authenticated workflow evidence retention state is invalid"
    end

    def ensure_object!(anchor, key, source, retain_until, kind)
      recover_exact_resource_delete_markers!(
        anchor, destructive_authority_scope!(anchor, key)
      )
      digest = Digest::SHA256.hexdigest(source)
      versions = exact_versions(anchor, key)
      if versions.fetch(:versions).empty?
        put_object(anchor, key, source, digest, retain_until, kind)
      end
      read_object!(
        anchor, key, expected_sha256: digest, expected_kind: kind, required_until: retain_until
      )
      prove_no_replace_and_no_delete!(anchor, key, source, digest, retain_until, kind)
      @fault_after.call(anchor.number, kind, object_revision(key))
      true
    end

    def put_object(anchor, key, source, digest, retain_until, kind)
      with_body(source) do |path|
        stdout, stderr, status = execute(
          anchor, "s3api", "put-object", *bucket_arguments(anchor), "--key", key,
          "--body", path, "--content-type", "application/json", "--checksum-algorithm", "SHA256",
          "--checksum-sha256", Base64.strict_encode64([ digest ].pack("H*")),
          "--metadata", "sha256=#{digest},kind=#{kind}", "--object-lock-mode", "COMPLIANCE",
          "--object-lock-retain-until-date", retain_until.iso8601, "--if-none-match", "*"
        )
        return if status.success?

        unless s3_put_precondition_failed?(stdout, stderr, status) &&
            exact_versions(anchor, key).fetch(:versions).one?
          raise Error, "Release journal anchor #{anchor.number} immutable object publication failed"
        end
      end
    end

    def prove_no_replace_and_no_delete!(anchor, key, source, digest, retain_until, kind)
      inventory = exact_versions(anchor, key)
      unless inventory.fetch(:versions).one? && inventory.fetch(:delete_markers).empty?
        raise Error, "Release journal anchor #{anchor.number} immutable object inventory changed"
      end
      version = inventory.fetch(:versions).first
      with_body(source) do |path|
        stdout, stderr, overwrite = execute(
          anchor, "s3api", "put-object", *bucket_arguments(anchor), "--key", key,
          "--body", path, "--content-type", "application/json", "--checksum-algorithm", "SHA256",
          "--checksum-sha256", Base64.strict_encode64([ digest ].pack("H*")),
          "--metadata", "sha256=#{digest},kind=#{kind}", "--object-lock-mode", "COMPLIANCE",
          "--object-lock-retain-until-date", retain_until.iso8601, "--if-none-match", "*"
        )
        if overwrite.success?
          raise Error, "Release journal anchor #{anchor.number} accepted an overwrite of a content address"
        end
        unless s3_put_precondition_failed?(stdout, stderr, overwrite)
          raise Error,
            "Release journal anchor #{anchor.number} did not return the expected conditional PutObject rejection"
        end
      end

      prove_destructive_authority! anchor, protected_key: key
      delete_stdout, delete_stderr, deletion = execute(
        anchor, "s3api", "delete-object", *bucket_arguments(anchor), "--key", key,
        "--version-id", version.fetch("VersionId")
      )
      if deletion.success?
        raise Error, "Release journal anchor #{anchor.number} accepted deletion during COMPLIANCE retention"
      end
      exact_resource_delete_authorized =
        s3_delete_error_code(delete_stdout, delete_stderr, deletion) == "AccessDenied" &&
        prove_exact_resource_delete_authority!(
          anchor, key, version.fetch("VersionId"), digest:, kind:, retain_until:
        )
      unless compliance_delete_rejection?(
        delete_stdout, delete_stderr, deletion,
        exact_resource_delete_authorized:
      )
        raise Error,
          "Release journal anchor #{anchor.number} did not return the expected COMPLIANCE retention rejection"
      end
      preserved = exact_versions(anchor, key)
      unless preserved.fetch(:versions).one? && preserved.fetch(:delete_markers).empty? &&
          preserved.fetch(:versions).sole.fetch("VersionId") == version.fetch("VersionId")
        raise Error, "Release journal anchor #{anchor.number} changed the retained object after rejected deletion"
      end
    end

    def prove_exact_resource_delete_authority!(anchor, key, protected_version_id, digest:, kind:,
        retain_until:)
      scope = destructive_authority_scope!(anchor, key)
      recover_exact_resource_delete_markers!(anchor, scope)
      intent_key = exact_resource_delete_intent_key(
        anchor, scope, key, protected_version_id, digest, kind, retain_until
      )
      intent_inventory = exact_versions(anchor, intent_key)
      unless intent_inventory.values.all?(&:empty?)
        raise Error, "Release journal anchor #{anchor.number} exact-resource delete intent already exists"
      end

      recovery_key = [ anchor.number, scope ]
      @recovered_exact_resource_delete_scopes.delete(recovery_key)
      intent_marker_id = create_temporary_delete_marker!(anchor, intent_key)
      marker_version_id = create_temporary_delete_marker!(
        anchor, key, protected_version_id:
      )
      delete_temporary_marker!(
        anchor, key, marker_version_id, protected_version_id:, recovery: false
      )
      delete_temporary_marker!(
        anchor, intent_key, intent_marker_id, protected_version_id: nil, recovery: false
      )
      @recovered_exact_resource_delete_scopes[recovery_key] = true
      true
    end

    def recover_exact_resource_delete_markers!(anchor, scope)
      recovery_key = [ anchor.number, scope ]
      return true if @recovered_exact_resource_delete_scopes[recovery_key]

      intent_prefix = exact_resource_delete_intent_prefix(scope)
      pending = list_versions(anchor, intent_prefix)
      unless pending.fetch(:versions).empty?
        raise Error, "Release journal anchor #{anchor.number} exact-resource delete intent inventory is invalid"
      end
      markers = pending.fetch(:delete_markers).group_by { _1.fetch("Key") }
      if markers.empty?
        @recovered_exact_resource_delete_scopes[recovery_key] = true
        return true
      end

      markers.each do |intent_key, entries|
        name = intent_key.delete_prefix(intent_prefix)
        unless intent_key.start_with?(intent_prefix) &&
            EXACT_RESOURCE_DELETE_INTENT_NAME_PATTERN.match?(name) && entries.one? &&
            valid_version_id?(entries.sole.fetch("VersionId"))
          raise Error,
            "Release journal anchor #{anchor.number} exact-resource delete intent inventory is invalid"
        end
      end

      excluded_prefixes = [ destructive_control_prefix(scope), intent_prefix ]
      protected = list_versions(anchor, "#{scope}/").fetch(:versions).reject do |version|
        excluded_prefixes.any? { version.fetch("Key").start_with?(_1) }
      end
      descriptors = protected.map do |version|
        exact_resource_delete_intent_descriptor!(anchor, scope, version)
      end.group_by { _1.fetch(:intent_key) }

      markers.each do |intent_key, entries|
        matches = descriptors.fetch(intent_key, [])
        unless matches.one?
          raise Error,
            "Release journal anchor #{anchor.number} exact-resource delete intent has no unique retained target"
        end
        descriptor = matches.sole
        protected_key = descriptor.fetch(:protected_key)
        protected_version_id = descriptor.fetch(:protected_version_id)
        inventory = exact_versions(anchor, protected_key)
        unless inventory.fetch(:versions).one? &&
            inventory.fetch(:versions).sole.fetch("VersionId") == protected_version_id &&
            inventory.fetch(:delete_markers).length <= 1
          raise Error,
            "Release journal anchor #{anchor.number} pending exact-resource delete marker is invalid"
        end
        if marker = inventory.fetch(:delete_markers).first
          marker_version_id = marker.fetch("VersionId")
          unless valid_version_id?(marker_version_id)
            raise Error,
              "Release journal anchor #{anchor.number} pending exact-resource delete marker is invalid"
          end
          delete_temporary_marker!(
            anchor, protected_key, marker_version_id, protected_version_id:, recovery: true
          )
        end
        delete_temporary_marker!(
          anchor, intent_key, entries.sole.fetch("VersionId"), protected_version_id: nil,
          recovery: true
        )
      end
      @recovered_exact_resource_delete_scopes[recovery_key] = true
      true
    rescue KeyError, NoMethodError, ArgumentError
      raise Error, "Release journal anchor #{anchor.number} exact-resource delete intent response is invalid"
    end

    def exact_resource_delete_intent_descriptor!(anchor, scope, version)
      protected_key = version.fetch("Key")
      protected_version_id = version.fetch("VersionId")
      unless protected_key.start_with?("#{scope}/") && valid_version_id?(protected_version_id)
        raise Error, "Release journal anchor #{anchor.number} retained delete-intent target is invalid"
      end
      head = json_command!(
        anchor, "s3api", "head-object", *bucket_arguments(anchor), "--key", protected_key,
        "--version-id", protected_version_id, "--checksum-mode", "ENABLED"
      )
      metadata = head.fetch("Metadata")
      digest = metadata.fetch("sha256")
      kind = metadata.fetch("kind")
      checksum = Base64.strict_encode64([ digest ].pack("H*")) if digest.match?(DIGEST_PATTERN)
      retention = json_command!(
        anchor, "s3api", "get-object-retention", *bucket_arguments(anchor),
        "--key", protected_key, "--version-id", protected_version_id
      ).fetch("Retention")
      retain_until = Time.iso8601(retention.fetch("RetainUntilDate")).utc
      unless metadata.keys.sort == %w[ kind sha256 ] && PROTECTED_OBJECT_KINDS.include?(kind) &&
          head.fetch("VersionId") == protected_version_id && head.fetch("ChecksumSHA256") == checksum &&
          retention.keys.sort == %w[ Mode RetainUntilDate ] && retention.fetch("Mode") == "COMPLIANCE"
        raise Error, "Release journal anchor #{anchor.number} retained delete-intent target is invalid"
      end
      {
        intent_key: exact_resource_delete_intent_key(
          anchor, scope, protected_key, protected_version_id, digest, kind, retain_until
        ),
        protected_key:, protected_version_id:
      }
    rescue KeyError, NoMethodError, ArgumentError
      raise Error, "Release journal anchor #{anchor.number} retained delete-intent target is invalid"
    end

    def exact_resource_delete_intent_key(anchor, scope, protected_key, protected_version_id,
        digest, kind, retain_until)
      source = self.class.canonical_json(
        "anchor_set_sha256" => @anchor_set.fetch("sha256"),
        "format_version" => 1,
        "kind" => "exact-resource-delete-marker-intent",
        "namespace" => scope.delete_prefix("#{anchor.prefix}/"),
        "protected_object" => {
          "key" => protected_key.delete_prefix("#{anchor.prefix}/"),
          "kind" => kind,
          "retain_until" => retain_until.utc.iso8601,
          "sha256" => digest,
          "version_id" => protected_version_id
        }
      )
      unless protected_key.start_with?("#{scope}/") && digest.match?(DIGEST_PATTERN) &&
          PROTECTED_OBJECT_KINDS.include?(kind) && valid_version_id?(protected_version_id)
        raise Error, "Release journal anchor #{anchor.number} exact-resource delete intent is invalid"
      end
      "#{exact_resource_delete_intent_prefix(scope)}intent-#{Digest::SHA256.hexdigest(source)}"
    end

    def exact_resource_delete_intent_prefix(scope)
      "#{scope}/#{EXACT_RESOURCE_DELETE_INTENT_NAMESPACE}/"
    end

    def create_temporary_delete_marker!(anchor, key, protected_version_id: nil)
      stdout, stderr, status = execute(
        anchor, "s3api", "delete-object", *bucket_arguments(anchor), "--key", key
      )
      unless status.success?
        raise Error,
          "Release journal anchor #{anchor.number} could not create its exact-resource delete marker: #{stderr}#{stdout}"
      end
      response = JSON.parse(stdout)
      marker_version_id = response.fetch("VersionId")
      inventory = exact_versions(anchor, key)
      expected_versions = protected_version_id ? [ protected_version_id ] : []
      unless response.fetch("DeleteMarker") == true && valid_version_id?(marker_version_id) &&
          inventory.fetch(:versions).map { _1.fetch("VersionId") } == expected_versions &&
          inventory.fetch(:delete_markers).one? &&
          inventory.fetch(:delete_markers).sole.fetch("VersionId") == marker_version_id
        raise Error, "Release journal anchor #{anchor.number} exact-resource delete marker is invalid"
      end
      marker_version_id
    rescue JSON::ParserError, KeyError, NoMethodError, ArgumentError
      raise Error, "Release journal anchor #{anchor.number} exact-resource delete-marker response is invalid"
    end

    def delete_temporary_marker!(anchor, key, marker_version_id, protected_version_id:, recovery:)
      stdout, stderr, status = execute(
        anchor, "s3api", "delete-object", *bucket_arguments(anchor), "--key", key,
        "--version-id", marker_version_id
      )
      remaining = exact_versions(anchor, key)
      expected_versions = protected_version_id ? [ protected_version_id ] : []
      restored = remaining.fetch(:versions).map { _1.fetch("VersionId") } == expected_versions &&
        remaining.fetch(:delete_markers).empty?
      return true if recovery && !status.success? && restored
      unless status.success?
        raise Error,
          "Release journal anchor #{anchor.number} lacks exact-resource destructive version-delete authority: #{stderr}#{stdout}"
      end
      response = JSON.parse(stdout)
      unless response.fetch("DeleteMarker") == true &&
          response.fetch("VersionId") == marker_version_id && restored
        raise Error, "Release journal anchor #{anchor.number} exact-resource delete marker was not deleted"
      end
      true
    rescue JSON::ParserError, KeyError, NoMethodError, ArgumentError
      raise Error, "Release journal anchor #{anchor.number} exact-resource delete-marker response is invalid"
    end

    def valid_version_id?(version_id)
      version_id.is_a?(String) && version_id.bytesize.between?(1, 1_024) &&
        version_id != "null" && !version_id.match?(/[[:cntrl:]]/)
    end

    def prove_destructive_authority!(anchor, protected_key:)
      scope = destructive_authority_scope!(anchor, protected_key)
      authority_key = [ anchor.number, scope ]
      return true if @destructive_authority[authority_key]

      recover_stale_destructive_controls!(anchor, scope)
      nonce = SecureRandom.hex(16)
      key = "#{destructive_control_prefix(scope)}control-#{nonce}.json"
      source = destructive_control_source(anchor, scope, nonce)
      digest = Digest::SHA256.hexdigest(source)
      response = nil
      control_retain_until = if @default_retentions[anchor.number]
        deadline = @control_clock.call.utc + DESTRUCTIVE_CONTROL_RETENTION_SECONDS
        Time.at(deadline.to_i).utc
      end
      with_body(source) do |path|
        retention_arguments = if control_retain_until
          [
            "--object-lock-mode", "COMPLIANCE",
            "--object-lock-retain-until-date", control_retain_until.iso8601
          ]
        else
          []
        end
        stdout, stderr, status = execute(
          anchor, "s3api", "put-object", *bucket_arguments(anchor), "--key", key,
          "--body", path, "--content-type", "application/json",
          "--checksum-algorithm", "SHA256",
          "--checksum-sha256", Base64.strict_encode64([ digest ].pack("H*")),
          "--metadata", "sha256=#{digest},kind=destructive-authority-control",
          *retention_arguments,
          "--if-none-match", "*"
        )
        unless status.success?
          raise Error,
            "Release journal anchor #{anchor.number} could not create its destructive-authority control: #{stderr}#{stdout}"
        end
        response = JSON.parse(stdout)
      end
      version_id = response.fetch("VersionId")
      inventory = exact_versions(anchor, key)
      unless inventory.fetch(:versions).one? && inventory.fetch(:delete_markers).empty? &&
          validate_destructive_control!(anchor, scope, key, inventory.fetch(:versions).sole) == version_id
        raise Error, "Release journal anchor #{anchor.number} destructive-authority control is invalid"
      end

      wait_for_destructive_control_expiry!(anchor, key, version_id, expected_until: control_retain_until)
      delete_destructive_control!(anchor, key, version_id, recovery: false)
      @destructive_authority[authority_key] = true
    rescue JSON::ParserError, KeyError, NoMethodError, ArgumentError
      raise Error, "Release journal anchor #{anchor.number} destructive-authority response is invalid"
    end

    def recover_stale_destructive_controls!(anchor, scope, inventory: nil)
      inventory ||= list_versions(anchor, destructive_control_prefix(scope))
      grouped = inventory.fetch(:versions).group_by { _1.fetch("Key") }
      unless inventory.fetch(:delete_markers).empty? && grouped.values.all?(&:one?)
        raise Error, "Release journal anchor #{anchor.number} stale destructive-authority control inventory is invalid"
      end

      grouped.each do |key, versions|
        version_id = validate_destructive_control!(anchor, scope, key, versions.sole)
        wait_for_destructive_control_expiry!(anchor, key, version_id)
        delete_destructive_control!(anchor, key, version_id, recovery: true)
      end
      true
    rescue KeyError, NoMethodError, ArgumentError
      raise Error, "Release journal anchor #{anchor.number} stale destructive-authority control response is invalid"
    end

    def validate_destructive_control!(anchor, scope, key, version)
      control_prefix = destructive_control_prefix(scope)
      name = key.delete_prefix(control_prefix)
      nonce = DESTRUCTIVE_CONTROL_NAME_PATTERN.match(name)&.[](1) if key.start_with?(control_prefix)
      unless nonce
        raise Error, "Release journal anchor #{anchor.number} stale destructive-authority control address is invalid"
      end

      source = destructive_control_source(anchor, scope, nonce)
      digest = Digest::SHA256.hexdigest(source)
      checksum = Base64.strict_encode64([ digest ].pack("H*"))
      version_id = version.fetch("VersionId")
      head = json_command!(
        anchor, "s3api", "head-object", *bucket_arguments(anchor), "--key", key,
        "--version-id", version_id, "--checksum-mode", "ENABLED"
      )
      unless version_id.is_a?(String) && version_id.bytesize.between?(1, 1_024) &&
          version_id != "null" && !version_id.match?(/[[:cntrl:]]/) &&
          version.fetch("Size") == source.bytesize && head.fetch("VersionId") == version_id &&
          head.fetch("ContentLength") == source.bytesize && head.fetch("ChecksumSHA256") == checksum &&
          head.fetch("Metadata") == { "sha256" => digest, "kind" => "destructive-authority-control" }
        raise Error, "Release journal anchor #{anchor.number} stale destructive-authority control is invalid"
      end
      version_id
    end

    def wait_for_destructive_control_expiry!(anchor, key, version_id, expected_until: nil)
      retention = json_command!(
        anchor, "s3api", "get-object-retention", *bucket_arguments(anchor),
        "--key", key, "--version-id", version_id
      ).fetch("Retention")
      if retention.empty?
        if expected_until
          raise Error,
            "Release journal anchor #{anchor.number} destructive-authority control must use exact COMPLIANCE retention"
        end
        return true
      end

      unless retention.keys.sort == %w[ Mode RetainUntilDate ] && retention.fetch("Mode") == "COMPLIANCE"
        raise Error,
          "Release journal anchor #{anchor.number} destructive-authority control must use exact COMPLIANCE retention"
      end
      observed_until = Time.iso8601(retention.fetch("RetainUntilDate")).utc
      if expected_until && observed_until != expected_until
        raise Error,
          "Release journal anchor #{anchor.number} destructive-authority control must use exact COMPLIANCE retention"
      end
      now = @control_clock.call.utc
      if !expected_until && observed_until >
          now + DESTRUCTIVE_CONTROL_RETENTION_SECONDS + DESTRUCTIVE_CONTROL_EXPIRY_MARGIN_SECONDS
        raise Error,
          "Release journal anchor #{anchor.number} stale destructive-authority control retention exceeds its bounded recovery window"
      end
      wait = observed_until + DESTRUCTIVE_CONTROL_EXPIRY_MARGIN_SECONDS - now
      @sleeper.call(wait) if wait.positive?
      unless @control_clock.call.utc > observed_until
        raise Error, "Release journal anchor #{anchor.number} destructive-authority control is still retained"
      end
      true
    end

    def delete_destructive_control!(anchor, key, version_id, recovery:)
      stdout, stderr, status = execute(
        anchor, "s3api", "delete-object", *bucket_arguments(anchor), "--key", key,
        "--version-id", version_id
      )
      remaining = exact_versions(anchor, key)
      deleted = remaining.fetch(:versions).empty? && remaining.fetch(:delete_markers).empty?
      return true if recovery && !status.success? && deleted
      unless status.success?
        raise Error,
          "Release journal anchor #{anchor.number} lacks destructive version-delete authority: #{stderr}#{stdout}"
      end
      unless deleted
        raise Error, "Release journal anchor #{anchor.number} destructive-authority control was not deleted"
      end
      true
    end

    def destructive_control_prefix(scope)
      "#{scope}/#{DESTRUCTIVE_CONTROL_NAMESPACE}/"
    end

    def destructive_control_source(anchor, scope, nonce)
      JSON.generate(
        "format_version" => 1, "kind" => "destructive-authority-control",
        "namespace" => scope.delete_prefix("#{anchor.prefix}/"), "nonce" => nonce
      ) << "\n"
    end

    def destructive_authority_scope!(anchor, key)
      prefix = "#{anchor.prefix}/"
      unless key.start_with?(prefix)
        raise Error, "Release journal anchor #{anchor.number} destructive-authority key is outside its namespace"
      end
      relative = key.delete_prefix(prefix)
      if relative.start_with?("catalog/operations/")
        full_key(anchor, "catalog/operations")
      elsif match = relative.match(/\Areleases\/([0-9a-f]{64})\//)
        full_key(anchor, "releases/#{match[1]}")
      else
        raise Error,
          "Release journal anchor #{anchor.number} retained object has no destructive-authority namespace"
      end
    end

    def compliance_delete_rejection?(stdout, stderr, status, exact_resource_delete_authorized:)
      exact_resource_delete_authorized &&
        s3_delete_error_code(stdout, stderr, status) == "AccessDenied"
    end

    def s3_put_precondition_failed?(stdout, stderr, status)
      error = aws_cli_error_record(stdout, stderr, status)
      error && error.fetch(:code) == "PreconditionFailed" &&
        error.fetch(:operation) == "PutObject"
    end

    def s3_delete_error_code(stdout, stderr, status)
      error = aws_cli_error_record(stdout, stderr, status)
      error.fetch(:code) if error && error.fetch(:operation) == "DeleteObject"
    end

    def aws_cli_error_record(stdout, stderr, status)
      return unless status.respond_to?(:exited?) && status.exited? &&
        !status.success? && status.exitstatus&.positive? && stdout.empty?

      match = AWS_CLI_ERROR_RECORD.match(stderr)
      return unless match

      { code: match[1], operation: match[2], message: match[3] }
    end

    def read_object!(anchor, key, expected_sha256: nil, expected_kind:, required_until: nil, version: nil)
      versions = exact_versions(anchor, key)
      if versions.fetch(:delete_markers).any? || versions.fetch(:versions).length != 1
        raise Error, "Release journal anchor #{anchor.number} immutable object inventory changed"
      end
      version ||= versions.fetch(:versions).first
      version_id = version.fetch("VersionId", nil)
      unless version_id.is_a?(String) && version_id.bytesize.between?(1, 1_024) &&
          version_id != "null" && !version_id.match?(/[[:cntrl:]]/)
        raise Error, "Release journal anchor #{anchor.number} object version is invalid"
      end

      head = json_command!(
        anchor, "s3api", "head-object", *bucket_arguments(anchor), "--key", key,
        "--version-id", version_id, "--checksum-mode", "ENABLED"
      )
      metadata = head.fetch("Metadata")
      digest = expected_sha256 || metadata.fetch("sha256")
      checksum = Base64.strict_encode64([ digest ].pack("H*")) if digest.match?(DIGEST_PATTERN)
      unless digest.match?(DIGEST_PATTERN) && metadata == { "sha256" => digest, "kind" => expected_kind } &&
          head.fetch("VersionId", nil) == version_id && head.fetch("ChecksumSHA256", nil) == checksum
        raise Error, "Release journal anchor #{anchor.number} object checksum metadata is invalid"
      end

      source = nil
      Tempfile.create([ "campfire-release-anchor", ".json" ]) do |file|
        file.close
        response = json_command!(
          anchor, "s3api", "get-object", *bucket_arguments(anchor), "--key", key,
          "--version-id", version_id, "--checksum-mode", "ENABLED", file.path
        )
        source = File.binread(file.path)
        unless response.fetch("VersionId", nil) == version_id && response.fetch("ChecksumSHA256", nil) == checksum &&
            Digest::SHA256.hexdigest(source) == digest && head.fetch("ContentLength") == source.bytesize
          raise Error, "Release journal anchor #{anchor.number} object checksum verification failed"
        end
      end

      retention = json_command!(
        anchor, "s3api", "get-object-retention", *bucket_arguments(anchor), "--key", key,
        "--version-id", version_id
      ).fetch("Retention")
      retain_until = Time.iso8601(retention.fetch("RetainUntilDate")).utc
      unless retention.fetch("Mode") == "COMPLIANCE" &&
          (!required_until || retain_until >= required_until)
        raise Error, "Release journal anchor #{anchor.number} object is not under sufficient COMPLIANCE retention"
      end
      { source:, sha256: digest, retain_until:, version_id: }
    rescue ArgumentError, KeyError, NoMethodError
      raise Error, "Release journal anchor #{anchor.number} immutable object response is invalid"
    end

    def exact_versions(anchor, key)
      inventory = list_versions(anchor, key)
      {
        versions: inventory.fetch(:versions).select { _1.fetch("Key") == key },
        delete_markers: inventory.fetch(:delete_markers).select { _1.fetch("Key") == key }
      }
    end

    def list_versions(anchor, prefix)
      response = json_command!(
        anchor, "s3api", "list-object-versions", *bucket_arguments(anchor), "--prefix", prefix
      )
      if response.fetch("IsTruncated", false)
        raise Error, "Release journal anchor #{anchor.number} object inventory was truncated"
      end
      {
        versions: response.fetch("Versions", []),
        delete_markers: response.fetch("DeleteMarkers", [])
      }
    end

    def object_revision(key)
      Integer(key[%r{/([0-9]{20})-}, 1], 10)
    rescue ArgumentError, TypeError
      -1
    end

    def full_key(anchor, relative)
      "#{anchor.prefix}/#{relative}"
    end

    def bucket_arguments(anchor)
      [ "--bucket", anchor.bucket, "--expected-bucket-owner", anchor.account_id ]
    end

    def with_body(source)
      Tempfile.create([ "campfire-release-anchor", ".json" ]) do |file|
        file.binmode
        file.chmod(0o600)
        file.write(source)
        file.flush
        file.fsync
        yield file.path
      end
    end

    def json_command!(anchor, service, operation, *arguments, endpoint: true)
      stdout = command!(anchor, service, operation, *arguments, endpoint:)
      stdout.empty? ? {} : JSON.parse(stdout)
    rescue JSON::ParserError
      raise Error, "Release journal anchor #{anchor.number} #{operation} returned invalid JSON"
    end

    def command!(anchor, service, operation, *arguments, endpoint: true)
      stdout, _stderr, status = execute(anchor, service, operation, *arguments, endpoint:)
      unless status.success?
        raise Error, "Release journal anchor #{anchor.number} #{operation} failed"
      end
      stdout
    end

    def execute(anchor, service, operation, *arguments, endpoint: true)
      command = [
        "aws", "--profile", anchor.profile, "--no-cli-pager", "--output", "json"
      ]
      command.concat([ "--endpoint-url", anchor.endpoint_url ]) if endpoint && anchor.endpoint_url
      @executor.call(@environment, *command, service, operation, *arguments)
    rescue SystemCallError
      raise Error, "Release journal anchor #{anchor.number} AWS CLI execution failed"
    end
end
