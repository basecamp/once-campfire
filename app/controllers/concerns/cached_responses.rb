module CachedResponses
  extend ActiveSupport::Concern

  CACHE_HEADERS = %w[ content-type cache-control etag last-modified vary ].freeze
  CSRF_TAG = /<meta\b[^>]*\bname="csrf-token"[^>]*>|<input\b[^>]*\bname="authenticity_token"[^>]*>/

  included do
    prepend_before_action :capture_response_cache_version
  end

  def perform_caching
    super && !@rendering_uncached_response
  end

  private
    def capture_response_cache_version
      if request.get? && ResponseCache.instance.budget.positive?
        @response_cache_version = ResponseCache.instance.version
      end
    end

    # Register after room authorization, but before presentation queries.
    def cache_read_response
      if cacheable_read_request?
        token = form_authenticity_token
        key = response_cache_key
        original_session = session.to_hash.deep_dup

        if key.bytesize <= ResponseCache::MAX_KEY_BYTES && (entry = ResponseCache.instance.read(key, @response_cache_version))
          response.headers.merge!(entry[:headers])
          self.response_body = entry[:body].gsub(entry[:marker], token)
        else
          render_fresh_response { yield }
          if response.status == 200 && response.media_type == "text/html" && session.to_hash == original_session
            marker = "campfire-csrf-#{SecureRandom.hex(32)}"
            # Replace only framework token attributes, never a matching token in
            # message text. Postprocessing also leaves fragment caches untouched.
            body = csrf_neutral_body(response.body, marker)
            headers = response.headers.slice(*CACHE_HEADERS).to_h.freeze
            ResponseCache.instance.write(key, @response_cache_version, { body: body.freeze, marker: marker.freeze, headers: headers }.freeze)
          end
        end
      else
        render_fresh_response { yield }
      end
    end

    def cacheable_read_request?
      @response_cache_version && request.get? && request.format.html? && Current.session &&
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

    def render_fresh_response
      # Foreign SQL can change content without bumping fragment timestamps.
      # A whole-page miss renders fresh instead of creating unbounded Redis
      # fragment namespaces for every database commit.
      @rendering_uncached_response = true
      yield
    ensure
      @rendering_uncached_response = false
    end

    def csrf_neutral_body(body, marker)
      body.gsub(CSRF_TAG) do |tag|
        attribute = tag.start_with?("<meta") ? "content" : "value"
        tag.sub(/\b#{attribute}="[^"]*"/, %(#{attribute}="#{marker}"))
      end
    end
end
