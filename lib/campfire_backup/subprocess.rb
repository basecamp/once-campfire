require "open3"

module CampfireBackup
  module Subprocess
    INHERITED_ENVIRONMENT_VARIABLES = %w[ LANG LC_ALL LC_CTYPE PATH ].freeze

    class << self
      def capture2(*command, environment: ENV)
        Open3.capture2(
          environment.slice(*INHERITED_ENVIRONMENT_VARIABLES), *command, unsetenv_others: true
        )
      end

      def capture3(*command, environment: ENV)
        Open3.capture3(
          environment.slice(*INHERITED_ENVIRONMENT_VARIABLES), *command, unsetenv_others: true
        )
      end
    end
  end
end
