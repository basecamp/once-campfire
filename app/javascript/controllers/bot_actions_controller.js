import { Controller } from "@hotwired/stimulus"

const pendingRestores = new Map()

// Keep in sync with Messages::BotActionSelectionsController::MAX_MESSAGES, which
// rejects larger batches rather than silently truncating them.
const MAX_MESSAGES_PER_REQUEST = 100

function requestSelection(controller) {
  return new Promise((resolve, reject) => {
    const url = controller.selectionUrlValue
    if (!pendingRestores.has(url)) {
      pendingRestores.set(url, [])
      queueMicrotask(() => flushRestores(url))
    }
    pendingRestores.get(url).push({ controller, resolve, reject })
  })
}

function flushRestores(url) {
  const requests = pendingRestores.get(url)
  pendingRestores.delete(url)

  for (let index = 0; index < requests.length; index += MAX_MESSAGES_PER_REQUEST) {
    fetchSelections(url, requests.slice(index, index + MAX_MESSAGES_PER_REQUEST))
  }
}

async function fetchSelections(url, requests) {
  const selectionUrl = new URL(url, window.location.origin)
  requests.forEach(({ controller }) => selectionUrl.searchParams.append("message_ids[]", controller.messageIdValue))

  try {
    const response = await fetch(selectionUrl, { headers: { "Accept": "application/json" } })
    if (!response.ok) throw new Error(`Selection request failed: ${response.status}`)

    const selections = await response.json()
    requests.forEach(({ controller, resolve }) => resolve(selections[controller.messageIdValue] || []))
  } catch (error) {
    requests.forEach(({ reject }) => reject(error))
  }
}

export default class extends Controller {
  static targets = [ "button", "status" ]
  static values = { messageId: Number, selectionMode: String, selectionUrl: String }

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

    // Without a selection mode the buttons carry no aria-pressed state, so there's
    // nothing to fetch or restore — only failures need reporting.
    if (!this.#selectionEnabled) {
      if (submissionFailed) this.#showStatus("Couldn’t perform that action.")
      return
    }

    try {
      const values = await requestSelection(this)
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
