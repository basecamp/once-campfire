import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"
import { pageIsTurboPreview } from "helpers/turbo_helpers"
import { onNextEventLoopTick } from "helpers/timing_helpers"
import { getCookie, setCookie } from "lib/cookie"

const pageSynchronizations = new Map()
const recentSynchronizations = new Map()
const SYNCHRONIZATION_TTL = 30_000

export default class extends Controller {
  static values = { subscriptionsUrl: String }
  static targets = [ "notAllowedNotice", "bell", "details" ]
  static classes = [ "attention" ]

  #enrolling = false
  #originalBellLabel

  async connect() {
    if (!pageIsTurboPreview()) {
      this.#prepareBellStatus()
      const firstTimeReady = await this.isEnabled()

      this.#pulseBellButton()

      if (firstTimeReady) {
        onNextEventLoopTick(() => this.dispatch("ready"))
      } else {
        this.#showBellAlert()
      }
    }
  }

  async attemptToSubscribe() {
    if (this.#enrolling) return

    this.#enrolling = true
    this.#setEnrollmentBusy(true)
    let enrollmentFailed = false

    try {
      if (this.#allowed) {
        const registration = await this.#serviceWorkerRegistration || await this.#registerServiceWorker()

        switch(Notification.permission) {
          case "denied":  { this.#revealNotAllowedNotice(); break }
          case "granted": { enrollmentFailed = !await this.#subscribe(registration); break }
          case "default": { enrollmentFailed = await this.#requestPermissionAndSubscribe(registration) === false }
        }
      } else {
        this.#revealNotAllowedNotice()
      }
    } catch {
      enrollmentFailed = true
    } finally {
      this.#enrolling = false
      this.#setEnrollmentBusy(false)
      if (enrollmentFailed) this.#showEnrollmentFailure()
      this.#endFirstRun()
    }
  }

  async isEnabled() {
    try {
      if (this.#allowed) {
        const registration = await this.#serviceWorkerRegistration
        const existingSubscription = await registration?.pushManager?.getSubscription()

        return Notification.permission == "granted" && registration && existingSubscription &&
          await this.#syncPushSubscription(existingSubscription)
      }
      return false
    } catch {
      return false
    }
  }

  get #allowed() {
    return navigator.serviceWorker && window.Notification
  }

  get #serviceWorkerRegistration() {
    return navigator.serviceWorker.getRegistration(window.location.origin)
  }

  #registerServiceWorker() {
    return navigator.serviceWorker.register("/service-worker.js")
  }

  #revealNotAllowedNotice() {
    if (this.#originalBellLabel) this.#setBellLabel(this.#originalBellLabel)
    this.notAllowedNoticeTarget.showModal()
    this.#openSingleOption()
  }

  #openSingleOption() {
    const visibleElements = this.detailsTargets.filter(item => !this.#isHidden(item))

    if (visibleElements.length === 1) {
      this.detailsTargets.forEach(item => item.toggleAttribute("open", item === visibleElements[0]))
    }
  }

  #showBellAlert() {
    const [ loadingIcon, alertIcon ] = this.bellTarget.querySelectorAll("img")
    if (loadingIcon) loadingIcon.hidden = true
    if (alertIcon) alertIcon.hidden = false
  }

  #pulseBellButton() {
    if (!this.#hasSeenFirstRun) {
      this.bellTarget.classList.add(this.attentionClass)
    }
  }

  #endFirstRun() {
    this.bellTarget.classList.remove(this.attentionClass)
    this.#markFirstRunSeen()
  }

  async #subscribe(registration) {
    const subscription = await registration.pushManager
      .subscribe({ userVisibleOnly: true, applicationServerKey: this.#vapidPublicKey })

    if (await this.#syncPushSubscription(subscription, { force: true })) {
      this.#setBellLabel("Notifications enabled.")
      this.dispatch("ready")
      return true
    }

    return false
  }

  async #syncPushSubscription(subscription, { force = false } = {}) {
    const key = this.#synchronizationKey(subscription)
    if (pageSynchronizations.has(key)) return pageSynchronizations.get(key)
    const age = Date.now() - (recentSynchronizations.get(key) || 0)
    if (!force && age >= 0 && age < SYNCHRONIZATION_TTL) return true

    const synchronization = (async () => {
      try {
        const response = await post(this.subscriptionsUrlValue, {
          body: this.#extractJsonPayloadAsString(subscription),
          responseKind: "turbo-stream"
        })
        return response.ok
      } catch {
        return false
      }
    })()

    pageSynchronizations.set(key, synchronization)
    try {
      const synchronized = await synchronization
      if (synchronized) recentSynchronizations.set(key, Date.now())
      return synchronized
    } finally {
      if (pageSynchronizations.get(key) == synchronization) pageSynchronizations.delete(key)
    }
  }

  #synchronizationKey(subscription) {
    const sessionId = document.querySelector('meta[name="current-session-id"]')?.content
    return JSON.stringify([ sessionId || "unknown", this.#extractCapability(subscription) ])
  }

  async #requestPermissionAndSubscribe(registration) {
    const permission = await Notification.requestPermission()
    if (permission === "granted") return await this.#subscribe(registration)

    this.#revealNotAllowedNotice()
    return null
  }

  get #vapidPublicKey() {
    const encodedVapidPublicKey = document.querySelector('meta[name="vapid-public-key"]').content
    return this.#urlBase64ToUint8Array(encodedVapidPublicKey)
  }

  get #hasSeenFirstRun() {
    if (this.#isPWA) {
      return getCookie("notifications-pwa-first-run-seen")
    } else {
      return getCookie("notifications-first-run-seen")
    }
  }

  #markFirstRunSeen = (event) => {
    if (this.#isPWA) {
      setCookie("notifications-pwa-first-run-seen", true)
    } else {
      setCookie("notifications-first-run-seen", true)
    }
  }

  #extractJsonPayloadAsString(subscription) {
    return JSON.stringify({ push_subscription: this.#extractCapability(subscription) })
  }

  #extractCapability(subscription) {
    const { endpoint, keys: { p256dh, auth } } = subscription.toJSON()
    return { endpoint, p256dh_key: p256dh, auth_key: auth }
  }

  #prepareBellStatus() {
    const label = this.bellTarget.querySelector(".for-screen-reader")
    if (!label) return

    this.#originalBellLabel ??= label.textContent
    label.setAttribute("role", "status")
    label.setAttribute("aria-live", "polite")
    label.setAttribute("aria-atomic", "true")
  }

  #setEnrollmentBusy(busy) {
    this.bellTarget.disabled = busy
    this.bellTarget.toggleAttribute("aria-busy", busy)
    if (busy) this.#setBellLabel("Enabling notifications…")
  }

  #showEnrollmentFailure() {
    this.#showBellAlert()
    this.#setBellLabel("Notifications could not be enabled. Try again.")
  }

  #setBellLabel(value) {
    const label = this.bellTarget.querySelector(".for-screen-reader")
    if (label) label.textContent = value
  }

  // VAPID public key comes encoded as base64 but service worker registration needs it as a Uint8Array
  #urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - base64String.length % 4) % 4)
    const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")

    const rawData = window.atob(base64)
    const outputArray = new Uint8Array(rawData.length)

    for (let i = 0; i < rawData.length; ++i) {
      outputArray[i] = rawData.charCodeAt(i)
    }

    return outputArray
  }

  #isHidden(item) {
    return (item.offsetParent === null)
  }

  get #isPWA() {
    return window.matchMedia("(display-mode: standalone)").matches
  }
}
