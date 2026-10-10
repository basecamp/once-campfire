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
  #fileUrl = null
  #fetch = null

  connect() {
    this.element.hidden = !this.#shareable

    // Registered unconditionally: the lightbox reuses one button and only fills
    // in filesValue when an attachment opens, so gating on it here would mean
    // the listeners are never attached there. #prepare ignores an empty value.
    this.element.addEventListener("pointerenter", this.#prepare)
    this.element.addEventListener("pointerdown", this.#prepare)
  }

  disconnect() {
    this.element.removeEventListener("pointerenter", this.#prepare)
    this.element.removeEventListener("pointerdown", this.#prepare)
    this.#discard()
  }

  // Same reuse, sharper edge: the lightbox reassigns filesValue for every image
  // it opens on that one button, so a file cached for the previous attachment
  // would be shared for the next one. Tie the cache to the URL it came from.
  filesValueChanged() {
    if (this.#fileUrl !== this.filesValue) this.#discard()
  }

  share() {
    if (this.filesValue && !this.#ready) {
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

    if (this.#ready) {
      data.files = [ this.#file ]
    }

    return data
  }

  get #ready() {
    return this.#file && this.#fileUrl === this.filesValue
  }

  #discard() {
    this.#file = this.#fileUrl = null
  }

  #prepare = () => {
    const url = this.filesValue
    if (!url || this.#ready || this.#fetch) return

    this.#fetch = this.#fetchFile(url)
      .then(file => {
        // The lightbox may have moved on to another attachment while this was
        // in flight; that file is not the one to share now.
        if (this.filesValue === url) {
          this.#file = file
          this.#fileUrl = url
        }
      })
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

  async #fetchFile(url) {
    const response = await fetch(url)
    const blob = await response.blob()
    const randomPrefix = `Campfire_${Math.random().toString(36).slice(2)}`
    const fileName = `${randomPrefix}.${blob.type.split('/').pop()}`

    return new File([ blob ], fileName, { type: blob.type })
  }
}
