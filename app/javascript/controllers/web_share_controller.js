import { Controller } from "@hotwired/stimulus"

// navigator.share() requires transient activation, which expires five seconds
// after the click. Fetching the file first spends that budget on the download:
// small attachments squeak through, a 30MB PDF never does, and the share throws
// NotAllowedError with nothing shown to the user.
//
// So the file is fetched ahead of the click — on hover or pointerdown — and
// kept. The click handler then calls navigator.share() synchronously, while the
// activation is still good. If the file is not ready yet, we do NOT call share()
// (that is the error); the button goes busy and the next click sends it.
export default class extends Controller {
  static values = { title: String, text: String, url: String, files: String }

  #file = null
  #fetch = null

  connect() {
    this.element.hidden = !this.#shareable

    if (this.filesValue) {
      this.element.addEventListener("pointerenter", this.#prepare)
      this.element.addEventListener("pointerdown", this.#prepare)
    }
  }

  disconnect() {
    this.element.removeEventListener("pointerenter", this.#prepare)
    this.element.removeEventListener("pointerdown", this.#prepare)
    this.#file = this.#fetch = null
  }

  share() {
    if (this.filesValue && !this.#file) {
      this.#prepare()
      this.#busy = true
      return
    }

    const data = this.#shareData()

    // canShare() with the real payload, not the bare feature test: a platform
    // can support sharing and still refuse this file type.
    if (navigator.canShare && !navigator.canShare(data)) return

    // Not awaited on purpose — an await here would hand the activation back.
    navigator.share(data).catch(error => {
      if (error.name !== "AbortError") console.error("Share failed:", error)
    })
  }

  get #shareable() {
    return typeof navigator.share === "function"
  }

  #shareData() {
    const data = { title: this.titleValue, text: this.textValue }

    if (this.urlValue) {
      data.url = this.urlValue
    }

    if (this.#file) {
      data.files = [ this.#file ]
    }

    return data
  }

  #prepare = () => {
    if (!this.filesValue || this.#file || this.#fetch) return

    this.#fetch = this.#fetchFile()
      .then(file => this.#file = file)
      .catch(error => console.error("Share preparation failed:", error))
      .finally(() => {
        this.#fetch = null
        this.#busy = false
      })
  }

  set #busy(busy) {
    // aria-busy is a true/false string, not a boolean attribute — toggling it
    // would leave aria-busy="" behind, which assistive tech reads as false.
    if (busy) {
      this.element.setAttribute("aria-busy", "true")
    } else {
      this.element.removeAttribute("aria-busy")
    }
  }

  async #fetchFile() {
    const response = await fetch(this.filesValue)
    const blob = await response.blob()
    const randomPrefix = `Campfire_${Math.random().toString(36).slice(2)}`
    const fileName = `${randomPrefix}.${blob.type.split('/').pop()}`

    return new File([ blob ], fileName, { type: blob.type })
  }
}
