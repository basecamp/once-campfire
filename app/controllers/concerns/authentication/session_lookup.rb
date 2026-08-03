module Authentication::SessionLookup
  def find_session_by_cookie(lock: false)
    if token = cookies.signed[:session_token]
      sessions = Session.includes(:identity, :user)
      sessions = sessions.lock if lock
      session = sessions.find_by(token: token)
      if session&.valid_for_authentication?
        session
      else
        nil
      end
    end
  end
end
