require "open3"

module CampfireBackup
  module Subprocess
    INHERITED_ENVIRONMENT_VARIABLES = %w[ LANG LC_ALL LC_CTYPE PATH ].freeze

    class << self
      def capture2(*command, environment: ENV, spawn_options: {})
        Open3.capture2(
          environment.slice(*INHERITED_ENVIRONMENT_VARIABLES), *command,
          **spawn_options, unsetenv_others: true
        )
      end

      def capture3(*command, environment: ENV, spawn_options: {})
        Open3.capture3(
          environment.slice(*INHERITED_ENVIRONMENT_VARIABLES), *command,
          **spawn_options, unsetenv_others: true
        )
      end
    end
  end
end
