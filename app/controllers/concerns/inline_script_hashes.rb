# Allows the scripts the importmap helper emits: the inline importmap and its
# entry-point module by content hash, and the origins its URLs point to. The
# hashes change only when the importmap does (a deploy), so cached HTML stays
# valid, unlike a per-request nonce.
module InlineScriptHashes
  extend ActiveSupport::Concern

  ENTRY_POINT_SCRIPT = %(import "application")

  included do
    # With the policy turned off there's nothing to add to, so leave the
    # request without one rather than starting an empty policy
    content_security_policy if: -> { request.content_security_policy } do |policy|
      if sources = policy.directives["script-src"]
        importmap = Rails.application.importmap.to_json(resolver: helpers)
        policy.directives["script-src"] = sources | script_origins(importmap) | script_hashes(importmap, ENTRY_POINT_SCRIPT)
      end
    end
  end

  private
    # The importmap is resolved by Rails' asset helpers, so its URLs already
    # carry any configured asset host, however it's written: with or without a
    # scheme, protocol-relative, a %d set, or a proc.
    def script_origins(importmap)
      JSON.parse(importmap)["imports"].values.filter_map do |url|
        origin = URI.join(request.base_url, url).origin
        origin unless origin == request.base_url
      end.uniq
    end

    def script_hashes(*scripts)
      scripts.map { |script| "'sha256-#{Digest::SHA256.base64digest(script)}'" }
    end
end
