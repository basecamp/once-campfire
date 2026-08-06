import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const WARNING_LEAD_TIME = 5 * 60 * 1000
const MAXIMUM_TIMER_DELAY = 2_147_000_000
const SIGN_IN_PATH = "/session/new"
const SESSION_STATUS_PATH = "/session"
const SESSION_END_REASONS = new Set([ "Session expired", "Session revoked" ])
let replacingSession = false
let sessionVerification

export function replaceExpiredSession() {
  if (replacingSession) return

  replacingSession = true
  document.documentElement.dataset.sessionInvalidated = "true"
  window.Turbo?.cache?.clear()
  document.querySelectorAll(
    'meta[name="current-user-id"], meta[name="current-user-name"], meta[name="current-session-id"], ' +
    'meta[name="csrf-token"], meta[name="csrf-param"]'
  ).forEach((meta) => meta.remove())
  document.title = "Sign in"

  const replacement = document.createElement("main")
  const heading = document.createElement("h1")
  const message = document.createElement("p")
  const link = document.createElement("a")
  replacement.id = "main-content"
  heading.textContent = "Your session has ended"
  message.textContent = "Redirecting to sign in."
  link.href = SIGN_IN_PATH
  link.textContent = "Sign in"
  replacement.replaceChildren(heading, message, link)
  document.body.replaceChildren(replacement)
  window.location.replace(SIGN_IN_PATH)
}

export function observeSessionTermination(channel, callback = replaceExpiredSession) {
  const socket = channel?.consumer?.connection?.webSocket
  if (!socket?.addEventListener) return () => {}

  const received = (event) => {
    try {
      const message = JSON.parse(event.data)
      if (message.type != "disconnect") return

      if (SESSION_END_REASONS.has(message.reason)) {
        callback(message.reason)
      } else if (message.reason == "unauthorized") {
        reconcileCurrentSession(callback)
      }
    } catch (_) {
      // Ignore non-protocol frames; Action Cable remains responsible for handling them.
    }
  }
  socket.addEventListener("message", received)
  return () => socket.removeEventListener("message", received)
}

export async function reconcileCurrentSession(callback = replaceExpiredSession) {
  const sessionId = document.querySelector('meta[name="current-session-id"]')?.content
  if (!sessionId) return

  if (sessionVerification?.sessionId != sessionId) {
    const promise = (async () => {
      const url = new URL(SESSION_STATUS_PATH, window.location.origin)
      url.searchParams.set("session_id", sessionId)

      try {
        const response = await fetch(url, {
          cache: "no-store",
          credentials: "same-origin"
        })
        const redirectedToSignIn = response.redirected && new URL(response.url).pathname == SIGN_IN_PATH
        return response.status == 409 || response.status == 401 || redirectedToSignIn
      } catch (_) {
        return false
      }
    })()
    const verification = { promise, sessionId }
    sessionVerification = verification
    promise.finally(() => {
      if (sessionVerification == verification) sessionVerification = null
    })
  }

  const verification = sessionVerification
  if (await verification.promise &&
      document.querySelector('meta[name="current-session-id"]')?.content == sessionId) {
    callback("Session revoked")
  }
}

export default class extends Controller {
  static values = { expiresAt: Number, serverTime: Number }

  #clockOffset = 0
  #deadline
  #usesMonotonicClock = false
  #active = false
  #connectionVersion = 0
  #stopObservingSessionTermination = () => {}

  connect() {
    this.#active = true
    this.visibilityChanged = this.#visibilityChanged.bind(this)
    this.online = this.#reconcileSession.bind(this)
    document.addEventListener("visibilitychange", this.visibilityChanged)
    window.addEventListener("online", this.online)
    if (this.hasExpiresAtValue && this.hasServerTimeValue) {
      this.#initializeDeadline()
      if (document.visibilityState == "hidden") {
        this.#recordSuspensionAnchor()
      } else {
        this.#reconcileSuspendedTime()
      }
      this.#refresh()
    }

    if (!document.querySelector('[data-controller~="refresh-room"]')) this.#monitorSession()
  }

  disconnect() {
    this.#active = false
    this.#connectionVersion += 1
    document.removeEventListener("visibilitychange", this.visibilityChanged)
    window.removeEventListener("online", this.online)
    clearTimeout(this.warningTimer)
    clearTimeout(this.expirationTimer)
    this.#stopObservingSessionTermination()
    this.channel?.unsubscribe()
    this.channel = null
  }

  #refresh() {
    clearTimeout(this.warningTimer)
    clearTimeout(this.expirationTimer)
    const expiresIn = this.#deadline - this.#now()

    if (expiresIn <= 0) {
      this.#warn(true)
    } else if (expiresIn <= WARNING_LEAD_TIME) {
      this.#warn()
    } else {
      this.warningTimer = setTimeout(() => this.#refresh(), Math.min(expiresIn - WARNING_LEAD_TIME, MAXIMUM_TIMER_DELAY))
    }
    if (expiresIn > 0) this.expirationTimer = setTimeout(() => this.#refresh(), Math.min(expiresIn, MAXIMUM_TIMER_DELAY))
  }

  #initializeDeadline() {
    const cachedClockOffset = Number(this.element.dataset.sessionExpirationClockOffset)
    this.#clockOffset = Number.isFinite(cachedClockOffset) ?
      cachedClockOffset : this.serverTimeValue - Date.now()
    this.element.dataset.sessionExpirationClockOffset = this.#clockOffset
    this.#usesMonotonicClock = typeof performance?.now == "function"

    // Turbo snapshots retain body data, so reconnects can reuse the original monotonic deadline.
    const cachedDeadline = Number(this.element.dataset.sessionExpirationDeadline)

    if (Number.isFinite(cachedDeadline)) {
      this.#deadline = cachedDeadline
    } else {
      this.#deadline = this.#now() + (this.expiresAtValue - this.serverTimeValue)
      this.element.dataset.sessionExpirationDeadline = this.#deadline
    }
  }

  #now() {
    return this.#usesMonotonicClock ? performance.now() : Date.now() + this.#clockOffset
  }

  #visibilityChanged() {
    if (document.visibilityState == "hidden") {
      this.#recordSuspensionAnchor()
    } else {
      this.#reconcileSuspendedTime()
      if (this.hasExpiresAtValue && this.hasServerTimeValue) this.#refresh()
      this.#reconcileSession()
    }
  }

  async #monitorSession() {
    const connectionVersion = ++this.#connectionVersion
    let channel

    try {
      channel = await cable.subscribeTo({ channel: "HeartbeatChannel" }, {
        connected: () => this.#observeSessionTermination(connectionVersion)
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

  #observeSessionTermination(connectionVersion) {
    if (!this.#active || connectionVersion != this.#connectionVersion || !this.channel) return

    this.#stopObservingSessionTermination()
    this.#stopObservingSessionTermination = observeSessionTermination(this.channel)
  }

  #recordSuspensionAnchor() {
    if (!this.#usesMonotonicClock) return

    this.element.dataset.sessionExpirationWallAnchor = this.#serverWallNow()
    this.element.dataset.sessionExpirationMonotonicAnchor = performance.now()
  }

  #reconcileSuspendedTime() {
    if (!this.#usesMonotonicClock) return

    const wallAnchor = Number(this.element.dataset.sessionExpirationWallAnchor)
    const monotonicAnchor = Number(this.element.dataset.sessionExpirationMonotonicAnchor)
    if (Number.isFinite(wallAnchor) && Number.isFinite(monotonicAnchor)) {
      const wallElapsed = this.#serverWallNow() - wallAnchor
      const monotonicElapsed = performance.now() - monotonicAnchor
      const uncountedElapsed = Math.max(wallElapsed - monotonicElapsed, 0)
      if (uncountedElapsed > 0) {
        this.#deadline -= uncountedElapsed
        this.element.dataset.sessionExpirationDeadline = this.#deadline
      }
    }

    delete this.element.dataset.sessionExpirationWallAnchor
    delete this.element.dataset.sessionExpirationMonotonicAnchor
  }

  #serverWallNow() {
    return Date.now() + this.#clockOffset
  }

  #reconcileSession() {
    if (!document.querySelector('[data-controller~="refresh-room"]')) {
      if (this.channel) {
        this.channel.consumer.connection.monitor.visibilityDidChange()
      } else {
        this.#monitorSession()
      }
    }
    reconcileCurrentSession(() => {
      if (this.#active) replaceExpiredSession()
    })
  }

  #warn(expired = false) {
    document.querySelector("[data-session-expiration-warning]")?.remove()

    const flash = document.createElement("div")
    const draftGuidance = this.#draftStorageAvailable() ?
      "Saved text drafts in this tab will be restored." :
      "Browser draft storage is unavailable; copy any unsent text before signing in again."
    flash.className = "flash flash--error"
    flash.dataset.sessionExpirationWarning = ""
    flash.innerHTML = `
      <div class="flash__inner shadow" role="alert" aria-atomic="true" style="--flash-background: var(--color-negative); animation: none">
        <span class="flash__message">${expired ? "Your session has expired." : "Your session expires in less than five minutes."} ${draftGuidance} Please send pending attachments before signing in again.</span>
        <a class="btn" href="/session/new">Sign in again</a>
      </div>
    `
    document.body.prepend(flash)
  }

  #draftStorageAvailable() {
    const knownAvailability = document.documentElement.dataset.draftStorageAvailable
    if (knownAvailability) return knownAvailability == "true"

    const key = "campfire-draft-storage-probe"
    try {
      sessionStorage.setItem(key, "true")
      sessionStorage.removeItem(key)
      return true
    } catch (_) {
      return false
    }
  }
}
