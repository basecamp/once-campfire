import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["popup", "message"]
  static values = {
    messageId: String
  }

  connect() {
    this.isOpen = false
    this.longPressTimer = null
    this.longPressDelay = 500 // ms
  }

  disconnect() {
    this.#clearLongPress()
    this.#closePopup()
  }

  // Handle tap on message body to show reactions
  tap(event) {
    // Don't trigger on links or buttons
    if (event.target.closest("a, button, .message__actions")) return

    // Toggle popup
    if (this.isOpen) {
      this.#closePopup()
    } else {
      this.#openPopup(event)
    }
  }

  // Long press start (for mobile)
  pressStart(event) {
    if (event.target.closest("a, button, .message__actions")) return

    this.longPressTimer = setTimeout(() => {
      this.#openPopup(event)
      this.#vibrate()
    }, this.longPressDelay)
  }

  // Long press end
  pressEnd(event) {
    this.#clearLongPress()
  }

  // Close when clicking outside
  closeOnClickOutside(event) {
    if (!this.isOpen) return
    if (this.element.contains(event.target)) return

    this.#closePopup()
  }

  // Close on escape
  closeOnEscape(event) {
    if (event.key === "Escape") {
      this.#closePopup()
    }
  }

  #openPopup(event) {
    // Find the actions menu details element
    const details = this.element.querySelector(".message__actions details")
    if (details) {
      details.open = true
      this.isOpen = true
      this.element.classList.add("tap-react--active")
    }
  }

  #closePopup() {
    const details = this.element.querySelector(".message__actions details")
    if (details) {
      details.open = false
    }
    this.isOpen = false
    this.element.classList.remove("tap-react--active")
  }

  #clearLongPress() {
    if (this.longPressTimer) {
      clearTimeout(this.longPressTimer)
      this.longPressTimer = null
    }
  }

  #vibrate() {
    if ("vibrate" in navigator) {
      navigator.vibrate(15)
    }
  }
}
