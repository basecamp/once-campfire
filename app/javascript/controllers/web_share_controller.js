import { Controller } from "@hotwired/stimulus"

const PREPARED_DATA_TTL = 60 * 1000

export default class extends Controller {
  static values = { title: String, text: String, url: String, files: String, filename: String }
  static targets = [ "label" ]

  #originalLabel
  #originalLabelWasForScreenReader
  #originalTitle
  #preparationAbortController
  #preparedDataTimer
  #preparationVersion = 0
  #preparing = false
  #readyData
  #restoreFocusAfterOperation = false
  #sharing = false

  connect() {
    this.element.hidden = typeof navigator.share != "function" || typeof navigator.canShare != "function"
    if (this.hasLabelTarget) {
      this.#originalLabel = this.labelTarget.textContent
      this.#originalLabelWasForScreenReader = this.labelTarget.classList.contains("for-screen-reader")
      this.labelTarget.setAttribute("aria-live", "polite")
      this.labelTarget.setAttribute("aria-atomic", "true")
    }
    this.#originalTitle = this.element.title
    this.beforeCache = this.#invalidatePreparation.bind(this)
    document.addEventListener("turbo:before-cache", this.beforeCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.beforeCache)
    this.#invalidatePreparation()
  }

  filesValueChanged() {
    this.#invalidatePreparation()
  }

  filenameValueChanged() {
    this.#invalidatePreparation()
  }

  share() {
    if (this.filesValue) {
      if (this.#readyData) {
        this.#shareNow(this.#readyData)
      } else {
        this.#prepareFileShare()
      }
    } else {
      this.#shareNow(this.#shareData())
    }
  }

  #shareData() {
    const data = { title: this.titleValue, text: this.textValue }

    if (this.urlValue) {
      data.url = this.urlValue
    }

    return data
  }

  async #getFileObject(signal) {
    const response = await fetch(this.filesValue, { credentials: "same-origin", redirect: "error", signal })
    const contentType = response.headers.get("Content-Type")?.split(";")[0]
    const disposition = response.headers.get("Content-Disposition")

    if (!response.ok || response.redirected || !contentType || !disposition || !this.filenameValue) {
      throw new Error("Attachment response was not shareable")
    }

    const blob = await response.blob()

    return new File([ blob ], this.filenameValue, { type: contentType })
  }

  async #prepareFileShare() {
    if (this.#preparing) return

    const version = ++this.#preparationVersion
    const abortController = new AbortController()
    this.#preparationAbortController = abortController
    this.#preparing = true
    this.#beginOperation()
    this.#setLabel(`Preparing ${this.filenameValue} for sharing...`)

    try {
      const data = this.#shareData()
      data.files = [ await this.#getFileObject(abortController.signal) ]
      if (version != this.#preparationVersion) return
      if (!navigator.canShare(data)) throw new Error("This browser cannot share the requested content")

      this.#readyData = data
      this.#expirePreparedDataLater()
      this.#setLabel(`Share ${this.filenameValue} now`)
    } catch (_) {
      if (version != this.#preparationVersion) return

      this.#showFailure()
      this.#setLabel(`Try preparing ${this.filenameValue} again`)
    } finally {
      if (version == this.#preparationVersion) {
        this.#preparationAbortController = null
        this.#preparing = false
        this.#finishOperation()
      }
    }
  }

  #shareNow(data) {
    if (this.#sharing) return

    try {
      if (!navigator.canShare(data)) throw new Error("This browser cannot share the requested content")

      this.#sharing = true
      this.#beginOperation()
      if (data == this.#readyData) this.#clearPreparedData()
      if (this.filesValue) this.#setLabel(`Sharing ${this.filenameValue}...`)
      const sharing = navigator.share(data)
      Promise.resolve(sharing).then(
        () => this.#shareSucceeded(),
        (error) => this.#shareFailed(error)
      )
    } catch (error) {
      this.#shareFailed(error)
    }
  }

  #shareSucceeded() {
    this.#sharing = false
    this.#clearPreparedData()
    if (this.filesValue) {
      this.#setLabel(`${this.filenameValue} was shared. Share again`)
    } else {
      this.#restoreLabel()
    }
    this.#finishOperation()
  }

  #shareFailed(error) {
    this.#sharing = false
    this.#clearPreparedData()

    if (error?.name == "AbortError") {
      this.#restoreLabel()
      this.#finishOperation()
      return
    }

    this.#showFailure()
    if (this.filesValue) {
      this.#setLabel(`Try preparing ${this.filenameValue} again`)
    } else {
      this.#restoreLabel()
    }
    this.#finishOperation()
  }

  #invalidatePreparation() {
    this.#preparationAbortController?.abort()
    this.#preparationAbortController = null
    this.#preparationVersion += 1
    this.#preparing = false
    this.#clearPreparedData()
    this.#sharing = false
    this.#restoreFocusAfterOperation = false
    this.element.disabled = false
    this.#restoreLabel()
  }

  #expirePreparedDataLater() {
    clearTimeout(this.#preparedDataTimer)
    this.#preparedDataTimer = setTimeout(() => {
      this.#preparedDataTimer = null
      this.#readyData = null
      if (!this.#preparing && !this.#sharing) this.#restoreLabel()
    }, PREPARED_DATA_TTL)
  }

  #clearPreparedData() {
    clearTimeout(this.#preparedDataTimer)
    this.#preparedDataTimer = null
    this.#readyData = null
  }

  #beginOperation() {
    this.#restoreFocusAfterOperation = document.activeElement == this.element
    this.element.disabled = true
  }

  #finishOperation() {
    this.element.disabled = false
    if (this.#restoreFocusAfterOperation && this.element.isConnected &&
        (document.activeElement == document.body || document.activeElement == this.element)) {
      this.element.focus({ preventScroll: true })
    }
    this.#restoreFocusAfterOperation = false
  }

  #setLabel(label) {
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = label
      this.labelTarget.classList.remove("for-screen-reader")
    }
    this.element.title = label
  }

  #restoreLabel() {
    if (this.hasLabelTarget && this.#originalLabel != null) {
      this.labelTarget.textContent = this.#originalLabel
      this.labelTarget.classList.toggle("for-screen-reader", this.#originalLabelWasForScreenReader)
    }
    if (this.#originalTitle != null) this.element.title = this.#originalTitle
  }

  #showFailure() {
    document.querySelector("[data-web-share-failure]")?.remove()

    const flash = document.createElement("div")
    flash.className = "flash flash--error"
    flash.dataset.controller = "element-removal"
    flash.dataset.webShareFailure = ""
    flash.innerHTML = `
      <div class="flash__inner shadow" role="alert" aria-atomic="true" style="--flash-background: var(--color-negative)">
        <span class="flash__message">${this.filesValue ? "The file" : "This item"} could not be shared. Check your access and try again.</span>
        <button type="button" class="btn" data-action="element-removal#remove">Dismiss notification</button>
      </div>
    `
    document.body.prepend(flash)
  }
}
