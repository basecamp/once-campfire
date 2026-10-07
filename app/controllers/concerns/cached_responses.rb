module CachedResponses
  extend ActiveSupport::Concern

  CACHE_HEADERS = %w[ content-type cache-control etag last-modified vary ].freeze
  CSRF_TAG = /<meta\b[^>]*\bname="csrf-token"[^>]*>|<input\b[^>]*\bname="authenticity_token"[^>]*>/

  included do
    prepend_before_action :capture_response_cache_version
  end

  def perform_caching
    super && @response_cache_version.present? && !ActiveRecord::Base.connection.transaction_open?
  end

  # Keep the class store (including shared rate limits) and Rails.cache unchanged.
  def cache_store
    FragmentCache.store
  end

  def combined_fragment_cache_key(key)
    @fragment_cache_namespace ||= [
      @response_cache_version, request.base_url, request.script_name, request.format.to_s, I18n.locale,
      Current.user&.id, Current.session&.token,
      (Digest::SHA256.hexdigest(real_csrf_token) if request.format.html? || request.format.turbo_stream?)
    ].freeze
    super([ @fragment_cache_namespace, key ])
  end

  private
    def capture_response_cache_version
      # Capture for native HTML/JSON/stream renders too, even with page reuse off.
      # Detached renderers do not run callbacks and therefore render uncached.
      @response_cache_version = ResponseCache.instance.version
    end

    # Register after room authorization, but before presentation queries.
    def cache_read_response
      if cacheable_read_request?
        token = form_authenticity_token
        key = response_cache_key
        original_session = session.to_hash.deep_dup

        return yield if key.bytesize > ResponseCache::MAX_KEY_BYTES

        entry = ResponseCache.instance.read(key, @response_cache_version)
        rendered = false
        unless entry
          ResponseCache.instance.synchronize_render(key, @response_cache_version) do
            entry = ResponseCache.instance.read(key, @response_cache_version)
            if !entry && ResponseCache.instance.version == @response_cache_version
              yield
              rendered = true
              cache_completed_response(key, original_session)
            end
          end
        end

        if entry
          response.headers.merge!(entry[:headers])
          self.response_body = entry[:body].gsub(entry[:marker], token)
        elsif !rendered
          # A queued request retains its pre-auth snapshot. If it has expired,
          # render outside the stripe instead of blocking the next generation.
          yield
        end
      else
        yield
      end
    end

    def cache_completed_response(key, original_session)
      if response.status == 200 && response.media_type == "text/html" && session.to_hash == original_session
        marker = "campfire-csrf-#{SecureRandom.hex(32)}"
        # Replace only framework token attributes, never a matching token in
        # message text. Postprocessing also leaves fragment caches untouched.
        body = csrf_neutral_body(response.body, marker)
        headers = response.headers.slice(*CACHE_HEADERS).to_h.freeze
        ResponseCache.instance.write(key, @response_cache_version, { body: body.freeze, marker: marker.freeze, headers: headers }.freeze)
      end
    end

    def cacheable_read_request?
      ResponseCache.instance.budget.positive? && @response_cache_version && request.get? && request.format.html? && Current.session &&
        !authenticated_by.bot_key? && flash.empty? &&
        !request.headers["If-None-Match"] && !request.headers["If-Modified-Since"] &&
        !Rails.application.config.content_security_policy_nonce_generator &&
        !ActiveRecord::Base.connection.transaction_open?
    end

    def response_cache_key
      ActiveSupport::JSON.encode([
        controller_path, request.fullpath, request.base_url, request.user_agent,
        request.headers["Accept"], request.headers["Turbo-Frame"], I18n.locale,
        # Tokens are hydrated per request, including clients that replay an old
        # cookie. Their raw CSRF secret does not select a presentation variant.
        Current.user.id, Current.session.token, session.to_hash.except("_csrf_token"),
        cookies.to_h.except("_campfire_session", "session_token")
      ])
    end

    def csrf_neutral_body(body, marker)
      body.gsub(CSRF_TAG) do |tag|
        attribute = tag.start_with?("<meta") ? "content" : "value"
        tag.sub(/\b#{attribute}="[^"]*"/, %(#{attribute}="#{marker}"))
      end
    end
end
