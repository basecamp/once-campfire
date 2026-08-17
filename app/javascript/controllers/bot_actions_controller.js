import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "button" ]
  static values = { selectionMode: String, selectionUrl: String }

  #confirmedValues = []
  #restoreVersion = 0

  connect() {
    if (this.#selectionEnabled) this.restore()
  }

  choose({ currentTarget }) {
    if (!this.#selectionEnabled) return

    this.#restoreVersion++

    const value = currentTarget.dataset.botActionValue
    const values = this.selectionModeValue === "multiple" ? this.#selectedValues : []

    if (values.includes(value) || currentTarget.getAttribute("aria-pressed") === "true") {
      this.#select(values.filter((selectedValue) => selectedValue !== value))
    } else {
      this.#select([ ...values, value ])
    }
  }

  #select(values) {
    this.buttonTargets.forEach((button) => {
      button.setAttribute("aria-pressed", values.includes(button.dataset.botActionValue))
    })
  }

  async restore() {
    const version = ++this.#restoreVersion

    try {
      const response = await fetch(this.selectionUrlValue, { headers: { "Accept": "application/json" } })
      if (!response.ok) throw new Error(`Selection request failed: ${response.status}`)

      const values = (await response.json()).values
      if (version === this.#restoreVersion) {
        this.#confirmedValues = values
        this.#select(values)
      }
    } catch {
      if (version === this.#restoreVersion) this.#select(this.#confirmedValues)
    }
  }

  get #selectionEnabled() {
    return this.selectionModeValue !== "none"
  }

  get #selectedValues() {
    return this.buttonTargets.filter((button) => button.getAttribute("aria-pressed") === "true").map((button) => button.dataset.botActionValue)
  }
}
