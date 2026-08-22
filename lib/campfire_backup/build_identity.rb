require "digest"
require "json"
require "pathname"

module CampfireBackup
  module BuildIdentity
    PATH = Pathname("/etc/campfire-build-identity.json")
    REVISION_PATTERN = /\A[0-9a-f]{40}\z/
    IDENTITY_PATTERN = /\A[0-9a-f]{64}\z/

    class << self
      def release_identity(run_id:, run_attempt:, architecture:, revision:)
        unless run_id.to_s.match?(/\A[1-9]\d*\z/) && run_attempt.to_s.match?(/\A[1-9]\d*\z/) &&
            architecture.to_s.match?(/\A[a-z0-9_-]+\z/) && revision.to_s.match?(REVISION_PATTERN)
          raise "Campfire release build identity inputs are invalid"
        end

        Digest::SHA256.hexdigest(
          [ "release", run_id, run_attempt, architecture, revision ].join(":")
        )
      end

      def read!(path: PATH, environment_revision: ENV["GIT_REVISION"])
        path = Pathname(path)
        raise "Campfire build identity is missing: #{path}" unless path.file? && !path.symlink?

        identity = JSON.parse(path.read)
        unless identity.keys.sort == %w[ build_identity format_version revision ] &&
            identity.fetch("format_version") == 1 &&
            identity.fetch("revision").match?(REVISION_PATTERN) &&
            identity.fetch("build_identity").match?(IDENTITY_PATTERN)
          raise "Campfire build identity is invalid"
        end
        unless environment_revision.to_s.empty?
          if environment_revision != identity.fetch("revision")
            raise "GIT_REVISION does not match the immutable Campfire build identity"
          end
        end

        identity.freeze
      rescue JSON::ParserError, KeyError, NoMethodError
        raise "Campfire build identity is invalid"
      end
    end
  end
end
