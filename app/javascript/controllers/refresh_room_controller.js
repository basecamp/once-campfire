import { Controller } from "@hotwired/stimulus"
import { get } from "@rails/request.js"
import { cable } from "@hotwired/turbo-rails"
import { pageIsTurboPreview } from "helpers/turbo_helpers"
import { observeSessionTermination } from "controllers/session_expiration_controller"

const OFFLINE_AFTER_DISCONNECTED_TIMEOUT = 5_000
const REFRESH_AFTER_HIDDEN_TIMEOUT = 60_000

export default class extends Controller {
  static targets = [ "message" ]
  static values = { loadedAt: Number, url: String, }

  #lastLoadedAt
  #offlineTimer = null
  #hiddenAt = null
  #active = false
  #connectionVersion = 0
  #stopObservingSessionTermination = () => {}

  async connect() {
    if (!pageIsTurboPreview()) {
      this.#active = true
      this.#lastLoadedAt = this.loadedAtValue
      this.#channelDisconnected()
      const connectionVersion = ++this.#connectionVersion
      let channel

      try {
        channel = await cable.subscribeTo({ channel: "HeartbeatChannel" }, {
          connected: () => this.#channelConnected(connectionVersion),
          disconnected: (details) => this.#channelDisconnected(details, connectionVersion)
        })
      } catch (_) {
        return
      }

      if (!this.#active || connectionVersion != this.#connectionVersion) {
        channel.unsubscribe()
        return
      }

      this.channel = channel
      this.#observeSessionTermination(connectionVersion)
    }
  }

  disconnect() {
    this.#active = false
    this.#connectionVersion += 1
    clearTimeout(this.#offlineTimer)
    this.#offlineTimer = null
    this.#stopObservingSessionTermination()
    this.channel?.unsubscribe()
    this.channel = null
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
    this.channel?.consumer.connection.monitor.visibilityDidChange()
  }

  #channelConnected(connectionVersion = this.#connectionVersion) {
    if (!this.#active || connectionVersion != this.#connectionVersion) return

    this.#observeSessionTermination(connectionVersion)
    this.#refresh("connection")

    clearTimeout(this.#offlineTimer)
    this.dispatch("online", { target: window })
  }

  #channelDisconnected(_details = {}, connectionVersion = this.#connectionVersion) {
    if (connectionVersion != this.#connectionVersion) return

    clearTimeout(this.#offlineTimer)
    this.#offlineTimer = setTimeout(() => {
      this.dispatch("offline", { target: window })
    }, OFFLINE_AFTER_DISCONNECTED_TIMEOUT)
  }

  async #refresh(reason) {
    try {
      await get(this.urlValue, {
        query: { since: this.#lastLoadedAt, reason: reason }, responseKind: "turbo-stream"
      })
    } catch (_) {
      // A transient refresh failure is handled by the connection/offline lifecycle.
    }
  }

  #observeSessionTermination(connectionVersion) {
    if (!this.#active || connectionVersion != this.#connectionVersion || !this.channel) return

    this.#stopObservingSessionTermination()
    this.#stopObservingSessionTermination = observeSessionTermination(this.channel)
  }

  #hiddenForTooLong() {
    return this.#hiddenAt && Date.now() - this.#hiddenAt > REFRESH_AFTER_HIDDEN_TIMEOUT
  }
}
