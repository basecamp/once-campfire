require "zlib"

module CachedResponses
  extend ActiveSupport::Concern

  CACHE_HEADERS = %w[ content-type content-encoding cache-control etag last-modified vary ].freeze

  included do
    prepend_before_action :capture_response_cache_version
  end

  def perform_caching
    return false unless super && @response_cache_version.present? && !ActiveRecord::Base.connection_pool.active_connection?&.transaction_open?

    # Check again after authentication, before the first native fragment lookup.
    # Later renders retain this immutable namespace and cannot poison a new epoch.
    unless defined?(@fragment_cache_snapshot_valid)
      @fragment_cache_snapshot_valid = @response_cache_version == ResponseCache.instance.version
    end
    @fragment_cache_snapshot_valid
  end

  # Keep the class store (including shared rate limits) and Rails.cache unchanged.
  def cache_store
    FragmentCache.store
  end

  def combined_fragment_cache_key(key)
    @fragment_cache_context ||= [
      request.base_url, request.script_name, request.format.to_s, I18n.locale,
      Current.user&.id, (Digest::SHA256.hexdigest(Current.session.token) if Current.session)
    ].freeze
    version = @response_cache_version unless Array(key).flatten.any? { |part| part.is_a?(FragmentCache::ContentKey) }
    super([ version, @fragment_cache_context, key ])
  end

  private
    def read_record_cache_version
      @response_cache_version if request.get? || request.head?
    end

    def capture_response_cache_version
      # Capture for native HTML/JSON/stream renders too, even with page reuse off.
      # Detached renderers do not run callbacks and therefore render uncached.
      @response_cache_version = ResponseCache.instance.version
    end

    # Register after room authorization, but before presentation queries.
    def cache_read_response
      if cacheable_read_request?
        encoding = Rack::Utils.select_best_encoding(%w[ gzip identity ], Rack::Utils.q_values(request.headers["Accept-Encoding"]))
        return yield unless encoding

        key = response_cache_key(encoding)
        return yield if key.bytesize > ResponseCache::MAX_KEY_BYTES

        entry = ResponseCache.instance.read(key, @response_cache_version)
        rendered = false
        unless entry
          ResponseCache.instance.synchronize_render(key, @response_cache_version) do
            entry = ResponseCache.instance.read(key, @response_cache_version)
            if !entry && ResponseCache.instance.version == @response_cache_version
              original_session = session.to_hash.deep_dup
              yield
              rendered = true
              entry = cache_completed_response(key, original_session, encoding)
            end
          end
        end

        if entry
          response.headers.merge!(entry[:headers])
          response.headers.delete("Content-Length")
          self.response_body = entry[:body]
        elsif !rendered
          # A queued request retains its pre-auth snapshot. If it has expired,
          # render outside the stripe instead of blocking the next generation.
          yield
        end
      else
        yield
      end
    end

    def cache_completed_response(key, original_session, encoding)
      if response.status == 200 && response.media_type == "text/html" && session.to_hash == original_session && !response.headers["Content-Encoding"]
        body = encoding == "gzip" ? Zlib.gzip(response.body) : response.body
        unless body.empty? || response.headers["ETag"] || response.headers["Last-Modified"]
          # Match Rack::ETag once, rather than hashing the same bytes on each hit.
          response.headers["ETag"] = %(W/"#{Digest::SHA256.hexdigest(body).byteslice(0, 32)}")
        end
        response.headers["Content-Encoding"] = "gzip" if encoding == "gzip"
        response.headers["Vary"] = (response.headers["Vary"].to_s.split(/,\s*/) | [ "Accept-Encoding" ]).join(", ")
        headers = response.headers.slice(*CACHE_HEADERS).to_h.freeze
        entry = { body: body.freeze, headers: headers }.freeze
        ResponseCache.instance.write(key, @response_cache_version, entry)
        entry
      end
    end

    def cacheable_read_request?
      ResponseCache.instance.budget.positive? && @response_cache_version && request.get? && request.format.html? && Current.session &&
        !authenticated_by.bot_key? && flash.empty? &&
        !request.headers["If-None-Match"] && !request.headers["If-Modified-Since"] &&
        !Rails.application.config.content_security_policy_nonce_generator &&
        !ActiveRecord::Base.connection_pool.active_connection?&.transaction_open?
    end

    def response_cache_key(encoding)
      ActiveSupport::JSON.encode([
        controller_path, request.fullpath, request.base_url, request.user_agent, encoding,
        request.headers["Accept"], request.headers["Turbo-Frame"], I18n.locale,
        # Old token-bearing installation cookies remain valid without affecting HTML.
        Current.user.id, Current.session.token, session.to_hash.except("_csrf_token"),
        cookies.to_h.except("_campfire_session", "session_token")
      ])
    end
end
