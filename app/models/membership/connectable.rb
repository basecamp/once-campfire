module Membership::Connectable
  extend ActiveSupport::Concern

  CONNECTION_TTL = 60.seconds
  MAXIMUM_PRESENCE_TOKENS = 16
  RECOVERABLE_UNTIL_KEY = "recoverable_until"
  Presence = Data.define(:token, :generation)

  included do
    scope :connected,    -> { where(connected_at: CONNECTION_TTL.ago..) }
    scope :disconnected, -> { where(connected_at: [ nil, ...CONNECTION_TTL.ago ]) }
  end

  class_methods do
    def disconnect_all
      connected.find_each { _1.send :disconnect_presence }
    end
  end

  def connected?
    connected_at? && connected_at >= CONNECTION_TTL.ago
  end

  def present(replacing: nil, clear_unread: true)
    presence = nil
    with_lock do
      now = Time.current
      stored_tokens = normalized_presence_tokens
      tokens = retained_presence_tokens(now, stored_tokens)
      delete_presence tokens, replacing
      if tokens.size >= MAXIMUM_PRESENCE_TOKENS
        update_presence_tokens(tokens, now:) if tokens != stored_tokens
        next
      end

      presence = add_presence(tokens, now)
      update_columns(
        presence_generation: presence.generation, presence_tokens: tokens, connected_at: now,
        unread_at: (clear_unread ? nil : unread_at), updated_at: now
      )
    end
    presence
  end

  def absent(presence)
    return false unless presence

    changed = false
    with_lock do
      now = Time.current
      stored_tokens = normalized_presence_tokens
      tokens = retained_presence_tokens(now, stored_tokens)
      changed = delete_presence(tokens, presence)
      update_presence_tokens(tokens, now:) if changed || tokens != stored_tokens
    end
    Message::Effect.advance_presence_reconciliation_for(self) if changed
    changed
  rescue ActiveRecord::RecordNotFound
    false
  end

  def refresh_presence(presence)
    return false unless presence

    refreshed = nil
    with_lock do
      now = Time.current
      stored_tokens = normalized_presence_tokens
      tokens = retained_presence_tokens(now, stored_tokens)
      if refreshable_presence?(stored_tokens, presence, now)
        tokens.delete presence.token
        next if tokens.size >= MAXIMUM_PRESENCE_TOKENS

        refreshed = add_presence(tokens, now)
        update_presence_tokens tokens, now:, generation: refreshed.generation
      elsif tokens != stored_tokens
        update_presence_tokens(tokens, now:)
      end
    end
    refreshed || false
  rescue ActiveRecord::RecordNotFound
    false
  end

  private
    def disconnect_presence
      with_lock do
        next false unless connected?

        now = Time.current
        recoverable_until = (now + CONNECTION_TTL).to_f
        tokens = normalized_presence_tokens.transform_values do |attributes|
          attributes.merge("refreshed_at" => 0.0, RECOVERABLE_UNTIL_KEY => recoverable_until)
        end
        update_columns(presence_tokens: tokens, connected_at: nil, updated_at: now)
        true
      end
    rescue ActiveRecord::RecordNotFound
      false
    end

    def retained_presence_tokens(now, tokens = normalized_presence_tokens)
      live_presence_tokens(now, tokens).merge(recoverable_presence_tokens(now, tokens))
    end

    def live_presence_tokens(now, tokens = normalized_presence_tokens)
      cutoff = (now - CONNECTION_TTL).to_f
      tokens.each_with_object({}) do |(token, attributes), live|
        live[token] = attributes if attributes["refreshed_at"].to_f >= cutoff
      end
    end

    def recoverable_presence_tokens(now, tokens)
      tokens.each_with_object({}) do |(token, attributes), recoverable|
        recoverable[token] = attributes if attributes[RECOVERABLE_UNTIL_KEY].to_f >= now.to_f
      end
    end

    def normalized_presence_tokens
      presence_tokens.to_h.transform_values { _1.to_h.stringify_keys }
    end

    def add_presence(tokens, now)
      generation = presence_generation + 1
      token = SecureRandom.uuid
      tokens[token] = { "generation" => generation, "refreshed_at" => now.to_f }
      Presence.new(token:, generation:)
    end

    def delete_presence(tokens, presence)
      return false unless presence
      return false unless matching_presence?(tokens, presence)

      tokens.delete presence.token
      true
    end

    def matching_presence?(tokens, presence)
      attributes = tokens[presence.token]
      attributes && attributes["generation"].to_i == presence.generation
    end

    def refreshable_presence?(tokens, presence, now)
      return false unless matching_presence?(tokens, presence)

      recoverable_until = tokens.dig(presence.token, RECOVERABLE_UNTIL_KEY)
      !recoverable_until || recoverable_until.to_f >= now.to_f
    end

    def update_presence_tokens(tokens, now:, generation: presence_generation)
      latest = live_presence_tokens(now, tokens).values.map { _1["refreshed_at"].to_f }.max
      update_columns(
        presence_generation: generation,
        presence_tokens: tokens,
        connected_at: latest ? Time.at(latest).utc : nil,
        updated_at: now
      )
    end
end
