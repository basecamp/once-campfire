import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const REFRESH_INTERVAL = 50 * 1000 // 50 seconds

// We delay transmitting visibility changes to ignore brief periods of invisibility,
// like switching to another tab and back
const VISIBILITY_CHANGE_DELAY = 5000 // 5 seconds

export default class extends Controller {
  #active = false
  #connectionVersion = 0
  #connectionNeedsAbsent = false
  #visibilityTimer

  async connect() {
    this.#active = true
    this.wasVisible = this.#isVisible
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
      this.#visibilityTimer = setTimeout(() => {
        this.#visibilityTimer = null
        if (!this.#active) return
        this.#visible()
      }, VISIBILITY_CHANGE_DELAY)
    } else {
      this.#hidden()
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
    this.connected = false
    this.#connectionNeedsAbsent = false
    this.#stopRefreshTimer()
  }

  #visible = () => {
    if (this.connected && this.#isVisible && !this.wasVisible) {
      this.channel.send({ action: "present" })
      this.#startRefreshTimer()
      this.wasVisible = true
    }
  }

  #hidden = () => {
    if (this.connected && this.wasVisible && !this.#isVisible) {
      this.#stopRefreshTimer()
      this.channel.send({ action: "absent" })
      this.wasVisible = false
    }
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
      const becamePresent = this.#connectionNeedsAbsent
      this.#connectionNeedsAbsent = false
      this.wasVisible = true
      this.#startRefreshTimer()
      if (becamePresent) this.dispatch("present", { detail: { roomId: Current.room.id } })
    } else {
      this.#stopRefreshTimer()
      this.wasVisible = false
      if (this.channel && this.#connectionNeedsAbsent) {
        this.channel.send({ action: "absent" })
        this.#connectionNeedsAbsent = false
      }
    }
  }

  get #isVisible() {
    return document.visibilityState === "visible"
  }
}
