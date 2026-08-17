import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "button", "status" ]
  static values = { selectionMode: String, selectionUrl: String }

  #confirmedValues = []
  #restoreVersion = 0

  connect() {
    if (this.#selectionEnabled) this.restore()
  }

  choose({ currentTarget }) {
    if (!this.#selectionEnabled) return

    this.#restoreVersion++
    this.#showStatus("")

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

  async restore(event) {
    const version = ++this.#restoreVersion
    const submissionFailed = event?.type === "turbo:submit-end" && !event.detail.success

    try {
      const response = await fetch(this.selectionUrlValue, { headers: { "Accept": "application/json" } })
      if (!response.ok) throw new Error(`Selection request failed: ${response.status}`)

      const values = (await response.json()).values
      if (version === this.#restoreVersion) {
        this.#confirmedValues = values
        this.#select(values)
        if (submissionFailed) this.#showStatus("Couldn’t perform that action.")
      }
    } catch {
      if (version === this.#restoreVersion) {
        this.#select(this.#confirmedValues)
        if (event?.type === "turbo:submit-end") this.#showStatus("Couldn’t perform that action.")
      }
    }
  }

  #showStatus(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }

  get #selectionEnabled() {
    return this.selectionModeValue !== "none"
  }

  get #selectedValues() {
    return this.buttonTargets.filter((button) => button.getAttribute("aria-pressed") === "true").map((button) => button.dataset.botActionValue)
  }
}
