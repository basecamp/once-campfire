import { Controller } from "@hotwired/stimulus"
import { get } from "@rails/request.js"
import { cable } from "@hotwired/turbo-rails"
import { pageIsTurboPreview } from "helpers/turbo_helpers"

const OFFLINE_AFTER_DISCONNECTED_TIMEOUT = 5_000
const RECONNECT_AFTER_DISCONNECTED_TIMEOUT = 1_000
const RECONNECT_AFTER_DISCONNECTED_JITTER = 1_000
const REFRESH_AFTER_HIDDEN_TIMEOUT = 60_000

export default class extends Controller {
  static targets = [ "message" ]
  static values = { loadedAt: Number, url: String, }

  #lastLoadedAt
  #offlineTimer = null
  #reconnectTimer = null
  #hiddenAt = null

  async connect() {
    if (!pageIsTurboPreview()) {
      this.#lastLoadedAt = this.loadedAtValue
      this.#channelDisconnected()

      this.channel = await cable.subscribeTo({ channel: "HeartbeatChannel" }, {
        connected: this.#channelConnected.bind(this),
        disconnected: this.#channelDropped.bind(this)
      })
    }
  }

  disconnect() {
    clearTimeout(this.#reconnectTimer)
    this.channel?.unsubscribe()
  }

  messageTargetConnected(target) {
    this.#lastLoadedAt = Math.max(this.#lastLoadedAt, target.dataset.messageUpdatedAt || 0)
  }

  visibilityChanged() {
    if (document.visibilityState === "visible") {
      if (this.#hiddenForTooLong()) {
        this.#refresh("visibility")
        this.dispatch("visible")
      }
      this.#hiddenAt = null
    } else {
      this.#hiddenAt = Date.now()
    }
  }

  online() {
    // Trigger reconnection attempt whenever the browser comes back
    // from being offline
    this.channel.consumer.connection.monitor.visibilityDidChange()
  }

  #channelConnected() {
    this.#refresh("connection")

    clearTimeout(this.#offlineTimer)
    clearTimeout(this.#reconnectTimer)
    this.dispatch("online", { target: window })
  }

  #channelDisconnected() {
    this.#offlineTimer = setTimeout(() => {
      this.dispatch("offline", { target: window })
    }, OFFLINE_AFTER_DISCONNECTED_TIMEOUT)
  }

  #channelDropped({ willAttemptReconnect } = {}) {
    this.#channelDisconnected()
    if (willAttemptReconnect) this.#reconnectSoon()
  }

  // Action Cable leaves a dropped connection alone for at least six seconds, so that the clients
  // of a server that went away don't all come back at once. But the server is often still there:
  // it was replaced behind a proxy, or it closed the connection itself, as it does to the members
  // of a room that's deleted. So try once, sooner, each client at a moment of its own. If that
  // fails, Action Cable carries on as it always has.
  #reconnectSoon() {
    clearTimeout(this.#reconnectTimer)
    this.#reconnectTimer = setTimeout(() => {
      this.channel.consumer.connect()
    }, RECONNECT_AFTER_DISCONNECTED_TIMEOUT + Math.random() * RECONNECT_AFTER_DISCONNECTED_JITTER)
  }

  #refresh(reason) {
    get(this.urlValue, { query: { since: this.#lastLoadedAt, reason: reason }, responseKind: "turbo-stream" })
  }

  #hiddenForTooLong() {
    return this.#hiddenAt && Date.now() - this.#hiddenAt > REFRESH_AFTER_HIDDEN_TIMEOUT
  }
}
