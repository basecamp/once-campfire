import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"
import FileUploader from "models/file_uploader"
import { onNextEventLoopTick, nextFrame, delay } from "helpers/timing_helpers"
import { escapeHTML } from "helpers/string_helpers"

const PREVIOUS_MESSAGE_TIMEOUT = 10_000

export default class extends Controller {
  static classes = ["toolbar"]
  static targets = [ "clientid", "fields", "fileList", "text" ]
  static values = { roomId: Number }
  static outlets = [ "messages" ]

  #files = []
  #sending = Promise.resolve()

  connect() {
    this.#restoreDraft()

    if (!this.#usingTouchDevice) {
      onNextEventLoopTick(() => this.textTarget.focus())
    }
  }

  saveDraft() {
    if (this.textTarget.isBlank) {
      localStorage.removeItem(this.#draftKey)
    } else {
      localStorage.setItem(this.#draftKey, this.textTarget.value)
    }
  }

  submit(event) {
    event.preventDefault()

    if (!this.fieldsTarget.disabled) {
      this.#submitFiles()
      this.#submitMessage()
      this.collapseToolbar()
      this.textTarget.focus()
    }
  }

  toggleToolbar() {
    this.element.classList.toggle(this.toolbarClass)
    this.textTarget.focus()
  }

  collapseToolbar() {
    this.element.classList.remove(this.toolbarClass)
  }

  replaceMessageContent(content) {
    this.textTarget.value = content
    this.textTarget.focus()
    this.textTarget.selection.placeCursorAtTheEnd()
  }

  submitByKeyboard(event) {
    if (event.key != "Enter" || this.textTarget.hasOpenPrompt) return

    const toolbarVisible = this.element.classList.contains(this.toolbarClass)
    const metaEnter = event.metaKey || event.ctrlKey
    const plainEnter = !event.shiftKey && !event.isComposing

    if (!this.#usingTouchDevice && (metaEnter || (plainEnter && !toolbarVisible))) {
      event.stopPropagation()
      this.submit(event)
    }
  }

  filePicked(event) {
    for (const file of event.target.files) {
      this.#files.push(file)
    }
    event.target.value = null
    this.#updateFileList()
  }

  fileUnpicked(event) {
    this.#files.splice(event.params.index, 1)
    this.#updateFileList()
  }

  pasteFiles(event) {
    if (event.clipboardData.files.length > 0) {
      event.preventDefault()
    }

    for (const file of event.clipboardData.files) {
      this.#files.push(file)
    }

    this.#updateFileList()
  }

  dropFiles({ detail: { files } }) {
    for (const file of files) {
      this.#files.push(file)
    }

    this.#updateFileList()
  }

  preventAttachment(event) {
    event.preventDefault()
  }

  online() {
    this.fieldsTarget.disabled = false
  }

  offline() {
    this.fieldsTarget.disabled = true
  }

  #restoreDraft() {
    const draft = localStorage.getItem(this.#draftKey)

    if (draft) {
      this.textTarget.value = draft
      this.textTarget.selection.placeCursorAtTheEnd()
    }
  }

  get #draftKey() {
    return `composer-draft-${this.roomIdValue}`
  }

  get #usingTouchDevice() {
    return 'ontouchstart' in window || navigator.maxTouchPoints > 0 || navigator.msMaxTouchPoints > 0;
  }

  async #submitMessage() {
    if (this.#validInput()) {
      const clientMessageId = this.#generateClientId()
      const messages = this.messagesOutlet

      await messages.insertPendingMessage(clientMessageId, this.textTarget)
      await nextFrame()

      this.clientidTarget.value = clientMessageId
      const body = new FormData(this.element)
      this.#reset()
      this.dispatch("submit")

      this.#send(body, clientMessageId, messages)
    }
  }

  // Each message has its own request: submitting the form again would cancel the request of the one before, losing it
  // if it hadn't reached the server yet. It waits for the one before to be answered, so they're posted in order, but
  // for no longer than ten seconds after that one went out, so one that's never answered doesn't hold up the rest.
  #send(body, clientMessageId, messages) {
    const send = () => Promise.race([ this.#post(body, clientMessageId, messages), delay(PREVIOUS_MESSAGE_TIMEOUT) ])
    this.#sending = this.#sending.then(send, send)
  }

  async #post(body, clientMessageId, messages) {
    const response = await post(this.element.action, { body, responseKind: "turbo-stream" }).catch(() => null)

    // Answered after its room's page was left: what follows would act on the page that's open now.
    if (!messages.element.isConnected) return

    if (response?.redirected) {
      // Signed out meanwhile: to the sign in page, as a form submission would go.
      Turbo.visit(response.response.url)
    } else if (!(response?.ok && response.isTurboStream)) {
      // A refusal can still say why, as when the room was deleted.
      if (response?.isTurboStream) await response.renderTurboStream()

      messages.failPendingMessage(clientMessageId)
    }
  }

  #validInput() {
    return !this.textTarget.isBlank
  }

  async #submitFiles() {
    const files = this.#files

    this.#files = []
    this.#updateFileList()

    for (const file of files) {
      const clientMessageId = this.#generateClientId()
      const uploader = new FileUploader(file, this.element.action, clientMessageId, this.#uploadProgress.bind(this))

      const body = this.#pendingUploadProgress(file.name)
      await this.messagesOutlet.insertPendingMessage(clientMessageId, body)

      const resp = await uploader.upload()

      Turbo.renderStreamMessage(resp)
    }
  }

  #uploadProgress(percent, clientMessageId, file) {
    const body = this.#pendingUploadProgress(file.name, percent)
    this.messagesOutlet.updatePendingMessage(clientMessageId, body)
  }

  #generateClientId() {
    return Math.random().toString(36).slice(2)
  }

  #reset() {
    this.textTarget.value = ""
    localStorage.removeItem(this.#draftKey)
  }

  #updateFileList() {
    this.#files.sort((a, b) => a.name.localeCompare(b.name))

    const fileNodes = this.#files.map((file, index) => {
      const filename = file.name.split(".").slice(0, -1).join(".")
      const extension = file.name.split(".").pop()

      const node = document.createElement("button")
      node.setAttribute("type","button")
      node.setAttribute("style","gap: 0")
      node.dataset.action = "composer#fileUnpicked"
      node.dataset.composerIndexParam = index
      node.className = "btn btn--plain composer__file txt-normal position-relative unpad flex-column"
      node.innerHTML = file.type.match(/^image\/.*/) ? `<img role="presentation" class="flex-item-no-shrink composer__file-thumbnail" src="${URL.createObjectURL(file)}">` : `<span class="composer__file-thumbnail composer__file-thumbnail--common colorize--black"></span>`
      node.innerHTML += `<span class="pad-inline txt-small flex align-center max-width composer__file-caption"><span class="overflow-ellipsis">${escapeHTML(filename)}.</span><span class="flex-item-no-shrink">${escapeHTML(extension)}</span></span>`

      return node
    })

    this.fileListTarget.replaceChildren(...fileNodes)
  }

  #pendingUploadProgress(filename, percent=0) {
    return `
      <div class="message__pending-upload flex align-center gap" style="--percentage: ${percent}%">
        <div class="composer__file-thumbnail composer__file-thumbnail--common colorize--black borderless flex-item-no-shrink"></div>
        <div>${escapeHTML(filename)} - <span>${percent}%</span></div>
      </div>
    `
  }
}
