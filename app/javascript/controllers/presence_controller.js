import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const REFRESH_INTERVAL = 50 * 1000 // 50 seconds

// Delay absence to ignore brief periods of invisibility, like switching tabs and back.
const VISIBILITY_CHANGE_DELAY = 5000 // 5 seconds

export default class extends Controller {
  #active = false
  #connectionVersion = 0
  #connectionNeedsAbsent = false
  #visibilityTimer

  async connect() {
    this.#active = true
    this.wasVisible = this.#isVisible
    window.addEventListener("pagehide", this.#pageHiding)
    window.addEventListener("pageshow", this.#pageShowing)
    document.addEventListener("freeze", this.#pageHiding)
    document.addEventListener("resume", this.#pageShowing)
    const connectionVersion = ++this.#connectionVersion
    let channel

    try {
      channel = await cable.subscribeTo({ channel: "PresenceChannel", room_id: Current.room.id }, {
        connected: () => this.#websocketConnected(connectionVersion),
        disconnected: () => this.#websocketDisconnected(connectionVersion)
      })
    } catch (_) {
      return
    }

    if (!this.#active || connectionVersion != this.#connectionVersion) {
      channel.unsubscribe()
      return
    }

    this.channel = channel
    this.#synchronizeConnectionVisibility()
  }

  disconnect() {
    this.#active = false
    this.#connectionVersion += 1
    window.removeEventListener("pagehide", this.#pageHiding)
    window.removeEventListener("pageshow", this.#pageShowing)
    document.removeEventListener("freeze", this.#pageHiding)
    document.removeEventListener("resume", this.#pageShowing)
    clearTimeout(this.#visibilityTimer)
    this.#visibilityTimer = null
    this.#stopRefreshTimer()
    this.channel?.unsubscribe()
    this.channel = null
    this.connected = false
    this.#connectionNeedsAbsent = false
  }

  visibilityChanged = () => {
    clearTimeout(this.#visibilityTimer)
    this.#visibilityTimer = null
    if (!this.#active) return

    if (this.#isVisible) {
      this.#visible()
    } else {
      this.#scheduleHidden()
    }
  }

  #websocketConnected = (connectionVersion) => {
    if (!this.#active || connectionVersion != this.#connectionVersion) return
    this.connected = true
    this.#connectionNeedsAbsent = true
    this.#synchronizeConnectionVisibility()
  }

  #websocketDisconnected = (connectionVersion) => {
    if (connectionVersion != this.#connectionVersion) return
    clearTimeout(this.#visibilityTimer)
    this.#visibilityTimer = null
    this.connected = false
    this.#connectionNeedsAbsent = false
    this.#stopRefreshTimer()
  }

  #visible = () => {
    if (!this.connected || !this.#isVisible) return

    const connectionBecamePresent = this.#connectionNeedsAbsent
    if (!this.wasVisible && !connectionBecamePresent) this.channel.send({ action: "present" })
    this.#connectionNeedsAbsent = false
    this.wasVisible = true
    this.#startRefreshTimer()
    if (connectionBecamePresent) this.dispatch("present", { detail: { roomId: Current.room.id } })
  }

  #hidden = () => {
    if (this.connected && (this.wasVisible || this.#connectionNeedsAbsent) && !this.#isVisible) {
      this.#becomeAbsent()
    }
  }

  #pageHiding = () => {
    clearTimeout(this.#visibilityTimer)
    this.#visibilityTimer = null
    if (this.#active) this.#becomeAbsent()
  }

  #pageShowing = () => {
    if (!this.#active) return

    if (this.#isVisible) {
      this.#visible()
    } else {
      this.#scheduleHidden()
    }
  }

  #becomeAbsent() {
    if (!this.connected || (!this.wasVisible && !this.#connectionNeedsAbsent)) return

    this.#stopRefreshTimer()
    this.channel.send({ action: "absent" })
    this.wasVisible = false
    this.#connectionNeedsAbsent = false
  }

  #scheduleHidden() {
    clearTimeout(this.#visibilityTimer)
    this.#visibilityTimer = null
    if (!this.#active || !this.connected || this.#isVisible) return

    this.#visibilityTimer = setTimeout(() => {
      this.#visibilityTimer = null
      if (!this.#active) return
      this.#hidden()
    }, VISIBILITY_CHANGE_DELAY)
  }

  #startRefreshTimer = () => {
    this.refreshTimer ??= setInterval(this.#refresh, REFRESH_INTERVAL)
  }

  #stopRefreshTimer = () => {
    clearInterval(this.refreshTimer)
    this.refreshTimer = null
  }

  #refresh = () => {
    if (this.#active && this.connected && this.channel) this.channel.send({ action: "refresh" })
  }

  #synchronizeConnectionVisibility() {
    if (!this.connected) return

    if (this.#isVisible) {
      this.#visible()
    } else {
      this.#stopRefreshTimer()
      // Subscribing makes the server present immediately; debounce the matching absence.
      this.wasVisible = true
      this.#scheduleHidden()
    }
  }

  get #isVisible() {
    return document.visibilityState === "visible"
  }
}
