module Authentication::SessionLookup
  def find_session_by_cookie
    if token = cookies.signed[:session_token]
      version = @response_cache_version if @response_cache_version && (request.get? || request.head?)
      session, user = RecordCache.fetch([ "session", Digest::SHA256.hexdigest(token.to_s) ], version) do
        session = Session.find_by(token: token)
        [ session, session&.user ]
      end
      session&.tap { |record| record.user = user }
    end
  end
end
