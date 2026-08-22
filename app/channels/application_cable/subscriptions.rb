require "monitor"
require "set"

module ApplicationCable
  class Subscriptions < ActionCable::Connection::Subscriptions
    MAXIMUM_IDENTIFIER_BYTES = 4.kilobytes

    def initialize(connection, maximum: Connection::MAXIMUM_SUBSCRIPTIONS_PER_CONNECTION)
      super(connection)
      @maximum = maximum
      # Pubsub confirmation can run while Action Cable is inside a base transition.
      @transition_monitor = Monitor.new
      @registry_monitor = Monitor.new
      @backend_by_client = {}
      @clients_by_backend = {}
      @backend_by_semantic_identifier = {}
      @semantic_identifier_by_backend = {}
      @confirmed_backends = Set.new
    end

    def add(data)
      @transition_monitor.synchronize do
        identifier = data["identifier"]
        return super unless identifier.is_a?(String)
        return reject(identifier) if identifier.bytesize > MAXIMUM_IDENTIFIER_BYTES

        new_backend = false
        confirmed_backend = false
        over_limit = false
        @registry_monitor.synchronize do
          return if @backend_by_client.key?(identifier)
          if @backend_by_client.size >= @maximum
            over_limit = true
            next
          end

          semantic_identifier = turbo_stream_identifier(identifier)
          if semantic_identifier && (backend_identifier = @backend_by_semantic_identifier[semantic_identifier])
            register(identifier, backend_identifier, semantic_identifier)
            confirmed_backend = @confirmed_backends.include?(backend_identifier)
          else
            register(identifier, identifier, semantic_identifier)
            new_backend = true
          end
        end

        return reject(identifier) if over_limit
        return confirm(identifier) if confirmed_backend
        return unless new_backend

        begin
          super
        ensure
          @registry_monitor.synchronize { forget_backend(identifier) } unless identifiers.include?(identifier)
        end
      end
    end

    def remove(data)
      @transition_monitor.synchronize do
        client_identifier = data["identifier"]
        backend_identifier, remove_backend = @registry_monitor.synchronize do
          backend_identifier = @backend_by_client[client_identifier]
          clients = @clients_by_backend[backend_identifier] if backend_identifier
          [ backend_identifier, clients&.one? ]
        end

        return super unless backend_identifier
        return @registry_monitor.synchronize { unregister(client_identifier) } unless remove_backend

        super(data.merge("identifier" => backend_identifier))
      end
    end

    def perform_action(data)
      @transition_monitor.synchronize do
        identifier = @registry_monitor.synchronize do
          @backend_by_client.fetch(data["identifier"], data["identifier"])
        end
        super(data.merge("identifier" => identifier))
      end
    end

    def remove_subscription(subscription)
      @transition_monitor.synchronize do
        super
        @registry_monitor.synchronize { forget_backend subscription.identifier }
      end
    end

    def unsubscribe_from_all
      @transition_monitor.synchronize do
        super
        @registry_monitor.synchronize { clear_registry }
      end
    end

    def identifiers
      @transition_monitor.synchronize { super }
    end

    def client_subscription_count
      @registry_monitor.synchronize { @backend_by_client.size }
    end

    def delivery_identifiers_for(backend_identifier)
      @registry_monitor.synchronize do
        @clients_by_backend.fetch(backend_identifier, Set[backend_identifier]).to_a
      end
    end

    def confirmation_identifiers_for(backend_identifier)
      @registry_monitor.synchronize do
        return unless @clients_by_backend.key?(backend_identifier)

        @confirmed_backends << backend_identifier
        @clients_by_backend.fetch(backend_identifier).to_a
      end
    end

    private
      def turbo_stream_identifier(identifier)
        options = ActiveSupport::JSON.decode(identifier)
        return unless options.is_a?(Hash) && options["channel"] == "Turbo::StreamsChannel"

        if stream_name = Turbo::StreamsChannel.verified_stream_name(options["signed_stream_name"])
          [ options["channel"], stream_name ]
        end
      rescue JSON::ParserError, TypeError
        nil
      end

      def register(client_identifier, backend_identifier, semantic_identifier)
        @backend_by_client[client_identifier] = backend_identifier
        (@clients_by_backend[backend_identifier] ||= Set.new) << client_identifier
        if semantic_identifier
          @backend_by_semantic_identifier[semantic_identifier] = backend_identifier
          @semantic_identifier_by_backend[backend_identifier] = semantic_identifier
        end
      end

      def unregister(client_identifier)
        return unless backend_identifier = @backend_by_client.delete(client_identifier)

        clients = @clients_by_backend.fetch(backend_identifier)
        clients.delete client_identifier
        forget_backend(backend_identifier) if clients.empty?
        backend_identifier
      end

      def forget_backend(backend_identifier)
        @clients_by_backend.delete(backend_identifier)&.each { @backend_by_client.delete(_1) }
        @confirmed_backends.delete backend_identifier
        if semantic_identifier = @semantic_identifier_by_backend.delete(backend_identifier)
          @backend_by_semantic_identifier.delete semantic_identifier
        end
      end

      def clear_registry
        @backend_by_client.clear
        @clients_by_backend.clear
        @backend_by_semantic_identifier.clear
        @semantic_identifier_by_backend.clear
        @confirmed_backends.clear
      end

      def confirm(identifier)
        connection.transmit(
          identifier:, type: ActionCable::INTERNAL[:message_types][:confirmation]
        )
      end

      def reject(identifier)
        connection.transmit(
          identifier:, type: ActionCable::INTERNAL[:message_types][:rejection]
        )
      end
  end
end
