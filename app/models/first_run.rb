class FirstRun
  class Unauthorized < StandardError; end

  ACCOUNT_NAME = "Campfire"
  FIRST_ROOM_NAME = "All Talk"
  TOKEN_ENVIRONMENT_VARIABLE = "CAMPFIRE_FIRST_RUN_TOKEN"
  MINIMUM_TOKEN_BYTES = 32

  class << self
    def authorized?(candidate)
      expected = configured_token
      candidate = candidate.to_s
      expected && candidate.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(candidate, expected)
    end

    def configured_token(env = ENV)
      token = env[TOKEN_ENVIRONMENT_VARIABLE].to_s
      token if token.bytesize >= MINIMUM_TOKEN_BYTES
    end

    def create!(user_params, token:)
      Account.transaction do
        raise Unauthorized, "first-run setup is not authorized" unless authorized?(token)

        Account.create!(name: ACCOUNT_NAME)
        room = Rooms::Open.new(name: FIRST_ROOM_NAME)

        administrator = room.creator = User.new(user_params.merge(role: :administrator))
        room.save!

        room.memberships.grant_to administrator

        administrator
      end
    end
  end
end
