# Allows the scripts the importmap helper emits and nothing else: the inline
# importmap and its entry-point module by content hash, and the asset
# directory its URLs point into. Not the whole origin, because uploads are
# served from this origin too. The hashes change only when the importmap does
# (a deploy), so cached HTML stays valid, unlike a per-request nonce.
module InlineScriptHashes
  extend ActiveSupport::Concern

  ENTRY_POINT_SCRIPT = %(import "application")

  included do
    # With the policy turned off there's nothing to add to, so leave the
    # request without one rather than starting an empty policy
    content_security_policy if: -> { request.content_security_policy } do |policy|
      if sources = policy.directives["script-src"]
        importmap = Rails.application.importmap.to_json(resolver: helpers)
        policy.directives["script-src"] = (sources - [ "'self'" ]) | script_locations(importmap) | script_hashes(importmap, ENTRY_POINT_SCRIPT)
        policy.worker_src "#{request.host_with_port}#{service_worker_path(format: :js)}"
      end
    end
  end

  private
    # The importmap is resolved by Rails' asset helpers, so its URLs already
    # carry any relative root and asset host, however the host is written:
    # with or without a scheme, protocol-relative, a %d set, or a proc. Each
    # is allowed up to its asset directory, the last one in its path, since an
    # asset host's own path may contain one too; a URL outside it is allowed
    # exactly.
    #
    # This origin's own sources leave out the scheme, so they match the page's
    # scheme even behind a proxy that terminates TLS without saying so.
    #
    # A path only limits the first request: browsers check just the origin
    # after a redirect. Nothing under the asset directory redirects.
    def script_locations(importmap)
      assets = File.join(config.relative_url_root.to_s, Rails.application.config.assets.prefix, "")

      JSON.parse(importmap)["imports"].values.map do |url|
        url = URI.join(request.base_url, url)
        origin = url.origin == request.base_url ? request.host_with_port : url.origin
        directory = url.path[0, url.path.rindex(assets) + assets.length] if url.path.include?(assets)
        "#{origin}#{directory || url.path}"
      end.uniq
    end

    def script_hashes(*scripts)
      scripts.map { |script| "'sha256-#{Digest::SHA256.base64digest(script)}'" }
    end
end
