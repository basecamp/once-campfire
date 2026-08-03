import { Controller } from "@hotwired/stimulus"

const WARNING_LEAD_TIME = 5 * 60 * 1000
const MAXIMUM_TIMER_DELAY = 2_147_000_000

export default class extends Controller {
  static values = { expiresAt: Number, serverTime: Number }

  #clockOffset = 0
  #deadline
  #usesMonotonicClock = false

  connect() {
    this.visibilityChanged = this.#visibilityChanged.bind(this)
    document.addEventListener("visibilitychange", this.visibilityChanged)
    if (this.hasExpiresAtValue && this.hasServerTimeValue) {
      this.#initializeDeadline()
      if (document.visibilityState == "hidden") {
        this.#recordSuspensionAnchor()
      } else {
        this.#reconcileSuspendedTime()
      }
      this.#refresh()
    }
  }

  disconnect() {
    document.removeEventListener("visibilitychange", this.visibilityChanged)
    clearTimeout(this.warningTimer)
    clearTimeout(this.expirationTimer)
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
      this.#refresh()
    }
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
