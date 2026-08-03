import { Controller } from "@hotwired/stimulus"
import FileUploader from "models/file_uploader"
import { onNextEventLoopTick, nextFrame } from "helpers/timing_helpers"
import { escapeHTML } from "helpers/dom_helpers"

const PERMANENT_FAILURE_STATUSES = new Set([ 403, 404, 409, 413, 422 ])

export default class extends Controller {
  static classes = ["toolbar"]
  static targets = [ "clientid", "fields", "fileList", "text" ]
  static values = { roomId: Number }
  static outlets = [ "messages" ]

  #files = []
  #fileSubmissionRequested = false
  #submittingFiles = false
  #submittingMessage = false
  #activeSubmission
  #failedFiles = new Map()
  #filePreviewUrls = new Map()
  #pendingSubmissions = []
  #retryingSubmissionIds = new Set()
  #uncertainFiles = new Map()

  connect() {
    this.#checkDraftStorage()
    this.#pendingSubmissions = this.#readPendingSubmissions()
    onNextEventLoopTick(() => this.#restoreDraft())

    if (!this.#usingTouchDevice) {
      onNextEventLoopTick(() => this.textTarget.focus())
    }

    this.#updateFileList()
  }

  disconnect() {
    this.#revokeFilePreviewUrls()
  }

  beforeCache() {
    this.#files = []
    this.#failedFiles.clear()
    this.#uncertainFiles.clear()
    this.#updateFileList()
    if (this.hasMessagesOutlet) this.messagesOutlet.removePendingFileMessages()
  }

  messagesOutletConnected() {
    onNextEventLoopTick(() => this.#restorePendingSubmissions())
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

  submitEnd(event) {
    const submission = this.#activeSubmission
    this.#activeSubmission = null
    this.#submittingMessage = false
    if (!submission) return

    if (event.detail.success || this.messagesOutlet.pendingMessageCommitted(submission.clientMessageId)) {
      this.#removePendingSubmission(submission.clientMessageId)
    } else {
      const status = event.detail.fetchResponse?.statusCode || event.detail.fetchResponse?.response?.status
      submission.failureStatus = status
      this.#storePendingSubmissions()
      this.messagesOutlet.failPendingMessage(submission.clientMessageId, this.#failureOptions("message", status))
    }

    if (this.#validInput()) {
      this.saveDraft()
    } else {
      this.#clearDraft()
    }
  }

  toggleToolbar() {
    this.element.classList.toggle(this.toolbarClass)
    this.textTarget.focus()
  }

  collapseToolbar() {
    this.element.classList.remove(this.toolbarClass)
  }

  saveDraft() {
    try {
      const value = this.textTarget.value
      if (value) {
        sessionStorage.setItem(this.#draftKey, value)
        this.#markDraftStorageAvailable(true)
      } else {
        sessionStorage.removeItem(this.#draftKey)
      }
    } catch (_) {
      this.#markDraftStorageAvailable(false)
    }
  }

  replaceMessageContent(content) {
    const editor = this.textTarget.editor

    editor.recordUndoEntry("Format reply")
    editor.setSelectedRange([0, editor.getDocument().toString().length])
    editor.deleteInDirection("forward")
    editor.insertHTML(content)
    editor.setSelectedRange([editor.getDocument().toString().length - 1])
  }

  submitByKeyboard(event) {
    const toolbarVisible = this.element.classList.contains(this.toolbarClass)
    const metaEnter = event.key == "Enter" && (event.metaKey || event.ctrlKey)
    const plainEnter = event.keyCode == 13 && !event.shiftKey && !event.isComposing

    if (!this.#usingTouchDevice && (metaEnter || (plainEnter && !toolbarVisible))) {
      this.submit(event)
    }
  }

  filePicked(event) {
    for (const file of event.target.files) {
      this.#queueFile(file)
    }
    event.target.value = null
    this.#updateFileList()
  }

  fileUnpicked(event) {
    const index = event.params.index
    const restoreFocus = document.activeElement == event.currentTarget
    const [ submission ] = this.#files.splice(index, 1)
    if (submission) this.messagesOutlet.removePendingMessage(submission.clientMessageId)
    this.#updateFileList()

    if (restoreFocus) {
      onNextEventLoopTick(() => {
        const files = this.fileListTarget.querySelectorAll(".composer__file")
        const nextFile = files[Math.min(index, files.length - 1)]
        if (nextFile) {
          nextFile.focus()
        } else {
          this.textTarget.focus()
        }
      })
    }
  }

  pasteFiles(event) {
    if (event.clipboardData.files.length > 0) {
      event.preventDefault()
    }

    for (const file of event.clipboardData.files) {
      this.#queueFile(file)
    }

    this.#updateFileList()
  }

  dropFiles({ detail: { files } }) {
    for (const file of files) {
      this.#queueFile(file)
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

  confirmPendingMessage({ detail: { clientMessageId, userId } }) {
    if (Number(userId) != Number(Current.user.id)) return

    this.#removePendingSubmission(clientMessageId)
    this.#removeQueuedFile(clientMessageId)
    this.messagesOutlet.removePendingMessage(clientMessageId)
  }

  async retryPendingMessage({ detail: { action = "retry", clientMessageId } }) {
    if (action == "restore") {
      this.#restorePendingFailure(clientMessageId)
      return
    } else if (action == "discard") {
      this.#discardPendingFailure(clientMessageId)
      return
    }

    if (this.#uncertainFiles.has(clientMessageId)) {
      await this.#retryUncertainFile(clientMessageId)
      return
    }

    const submission = this.#pendingSubmissions.find((pending) => pending.clientMessageId == clientMessageId)
    if (!submission || this.#retryingSubmissionIds.has(clientMessageId)) return

    this.#retryingSubmissionIds.add(clientMessageId)
    this.messagesOutlet.retryPendingMessage(clientMessageId)

    try {
      const stream = await this.#postPendingSubmission(submission)
      Turbo.renderStreamMessage(stream)
      await nextFrame()
      await this.messagesOutlet.announcePendingMessageSent(clientMessageId)
      this.#removePendingSubmission(clientMessageId)
    } catch (error) {
      if (this.messagesOutlet.pendingMessageCommitted(clientMessageId)) {
        await this.messagesOutlet.announcePendingMessageSent(clientMessageId)
        this.#removePendingSubmission(clientMessageId)
      } else {
        submission.failureStatus = error.status
        this.#storePendingSubmissions()
        this.messagesOutlet.failPendingMessage(clientMessageId, this.#failureOptions("message", error.status))
      }
    } finally {
      this.#retryingSubmissionIds.delete(clientMessageId)
    }
  }

  get #usingTouchDevice() {
    return 'ontouchstart' in window || navigator.maxTouchPoints > 0 || navigator.msMaxTouchPoints > 0;
  }

  async #submitMessage() {
    if (this.#submittingMessage || !this.#validInput()) return

    this.#submittingMessage = true
    const submission = { clientMessageId: this.#generateClientId(), body: this.textTarget.value }
    const pendingBody = document.createElement("div")
    pendingBody.innerHTML = submission.body
    let pendingMessageInserted = false

    this.#activeSubmission = submission
    this.#addPendingSubmission(submission)
    this.#reset()
    this.#clearDraft()

    try {
      while (!pendingMessageInserted) {
        pendingMessageInserted = await this.messagesOutlet.insertPendingMessage(submission.clientMessageId, pendingBody)
        if (!pendingMessageInserted) {
          this.#removePendingSubmission(submission.clientMessageId)
          submission.clientMessageId = this.#generateClientId()
          this.#addPendingSubmission(submission)
        }
      }
      await nextFrame()

      this.clientidTarget.value = submission.clientMessageId
      this.#requestSubmitWithBody(submission.body)
    } catch (_) {
      if (pendingMessageInserted) this.messagesOutlet.failPendingMessage(submission.clientMessageId)
      this.#submittingMessage = false
      this.#activeSubmission = null
      if (!this.#validInput()) this.textTarget.editor.loadHTML(submission.body)
      if (this.#validInput()) this.saveDraft()
    }
  }

  #validInput() {
    return this.textTarget.textContent.trim().length > 0
  }

  async #submitFiles() {
    if (this.#submittingFiles) {
      this.#fileSubmissionRequested = true
      return
    }
    if (this.#files.length == 0) return

    this.#submittingFiles = true
    const submissions = this.#files.splice(0)
    this.#updateFileList()

    try {
      for (const submission of submissions) {
        if (this.messagesOutlet.pendingMessageCommitted(submission.clientMessageId)) {
          this.messagesOutlet.removePendingMessage(submission.clientMessageId)
          continue
        }

        let pendingMessageInserted = false

        try {
          const body = this.#pendingUploadProgress(submission.file.name)
          while (!pendingMessageInserted) {
            pendingMessageInserted = await this.messagesOutlet.insertPendingMessage(submission.clientMessageId, body)
            if (!pendingMessageInserted) submission.clientMessageId = this.#generateClientId()
          }

          const uploader = this.#fileUploaderFor(submission)
          const response = await uploader.upload()
          if (!this.#streamContainsMessage(response, submission.clientMessageId)) {
            throw this.#unknownUploadOutcomeError("Upload returned an unexpected response")
          }
          Turbo.renderStreamMessage(response)
        } catch (error) {
          if (this.messagesOutlet.pendingMessageCommitted(submission.clientMessageId)) {
            this.#removeQueuedFile(submission.clientMessageId)
            this.messagesOutlet.removePendingMessage(submission.clientMessageId)
          } else {
            this.#handleFileFailure(submission, error, pendingMessageInserted)
          }
        }
      }
    } finally {
      this.#submittingFiles = false
      if (this.#fileSubmissionRequested) {
        this.#fileSubmissionRequested = false
        this.#submitFiles()
      }
    }
  }

  async #retryUncertainFile(clientMessageId) {
    const submission = this.#uncertainFiles.get(clientMessageId)
    if (!submission || this.#retryingSubmissionIds.has(clientMessageId)) return

    this.#retryingSubmissionIds.add(clientMessageId)
    this.messagesOutlet.retryPendingMessage(clientMessageId, { kind: "file" })

    try {
      const response = await this.#fileUploaderFor(submission).upload()
      if (!this.#streamContainsMessage(response, clientMessageId)) {
        throw this.#unknownUploadOutcomeError("Upload retry returned an unexpected response")
      }
      Turbo.renderStreamMessage(response)
      await nextFrame()
      if (!this.messagesOutlet.pendingMessageCommitted(clientMessageId)) {
        throw this.#unknownUploadOutcomeError("Upload retry was not confirmed")
      }
      this.#uncertainFiles.delete(clientMessageId)
    } catch (error) {
      if (this.messagesOutlet.pendingMessageCommitted(clientMessageId)) {
        this.#removeQueuedFile(clientMessageId)
        this.messagesOutlet.removePendingMessage(clientMessageId)
      } else {
        this.#handleFileFailure(submission, error, true)
      }
    } finally {
      this.#retryingSubmissionIds.delete(clientMessageId)
    }
  }

  #handleFileFailure(submission, error, pendingMessageInserted) {
    const { clientMessageId } = submission
    submission.failureStatus = error.status
    this.#failedFiles.delete(clientMessageId)
    this.#uncertainFiles.delete(clientMessageId)

    if (this.#uploadOutcomeUnknown(error)) {
      this.#uncertainFiles.set(clientMessageId, submission)
      if (pendingMessageInserted) {
        this.messagesOutlet.failPendingMessage(
          clientMessageId, this.#failureOptions("file", error.status, { uncertain: true })
        )
      }
    } else if (this.#isPermanentFailure(error.status)) {
      this.#failedFiles.set(clientMessageId, submission)
      if (pendingMessageInserted) {
        this.messagesOutlet.failPendingMessage(
          clientMessageId, this.#failureOptions("file", error.status, { retryable: false })
        )
      }
    } else {
      if (pendingMessageInserted) {
        this.messagesOutlet.failPendingMessage(
          clientMessageId, this.#failureOptions("file", error.status, { retryable: false })
        )
      }
      if (!this.#files.some((file) => file.clientMessageId == clientMessageId)) this.#files.push(submission)
      this.#updateFileList()
    }
  }

  #fileUploaderFor(submission) {
    return new FileUploader(
      submission.file, this.element.action, submission.clientMessageId, this.#uploadProgress.bind(this)
    )
  }

  #uploadProgress(percent, clientMessageId, file) {
    const body = this.#pendingUploadProgress(file.name, percent)
    this.messagesOutlet.updatePendingMessage(clientMessageId, body)
  }

  #generateClientId() {
    return Math.random().toString(36).slice(2)
  }

  #queueFile(file) {
    this.#files.push({ file, clientMessageId: this.#generateClientId() })
  }

  #reset() {
    this.textTarget.value = ""
  }

  #requestSubmitWithBody(body) {
    const setBody = (event) => event.formData.set("message[body]", body)
    this.element.addEventListener("formdata", setBody, { once: true })

    try {
      this.element.requestSubmit()
    } finally {
      this.element.removeEventListener("formdata", setBody)
    }
  }

  #restoreDraft() {
    try {
      const draft = sessionStorage.getItem(this.#draftKey)
      if (draft && !this.#validInput()) this.textTarget.editor.loadHTML(draft)
      if (draft) {
        sessionStorage.setItem(this.#draftKey, draft)
        this.#markDraftStorageAvailable(true)
      }
    } catch (_) {
      this.#markDraftStorageAvailable(false)
    }
  }

  async #restorePendingSubmissions() {
    for (const submission of [ ...this.#pendingSubmissions ]) {
      if (this.messagesOutlet.pendingMessageCommitted(submission.clientMessageId)) {
        this.#removePendingSubmission(submission.clientMessageId)
        continue
      }

      if (!document.getElementById(this.#messageDomId(submission.clientMessageId))) {
        const body = document.createElement("div")
        body.innerHTML = submission.body
        await this.messagesOutlet.insertPendingMessage(
          submission.clientMessageId, body, { preservePagination: true }
        )
      }
      this.messagesOutlet.failPendingMessage(
        submission.clientMessageId, this.#failureOptions("message", submission.failureStatus)
      )
    }
  }

  #clearDraft() {
    try {
      sessionStorage.removeItem(this.#draftKey)
    } catch (_) {
      this.#markDraftStorageAvailable(false)
    }
  }

  #readPendingSubmissions() {
    try {
      const value = sessionStorage.getItem(this.#pendingSubmissionsKey)
      if (!value) return []

      const submissions = JSON.parse(value)
      if (!Array.isArray(submissions)) return []

      return submissions.filter((submission) =>
        typeof submission?.clientMessageId == "string" && typeof submission?.body == "string"
      )
    } catch (_) {
      this.#markDraftStorageAvailable(false)
      return []
    }
  }

  #addPendingSubmission(submission) {
    this.#pendingSubmissions = this.#pendingSubmissions.filter(
      (pending) => pending.clientMessageId != submission.clientMessageId
    )
    this.#pendingSubmissions.push(submission)
    this.#storePendingSubmissions()
  }

  #removePendingSubmission(clientMessageId) {
    const remainingSubmissions = this.#pendingSubmissions.filter(
      (submission) => submission.clientMessageId != clientMessageId
    )
    if (remainingSubmissions.length == this.#pendingSubmissions.length) return

    this.#pendingSubmissions = remainingSubmissions
    this.#storePendingSubmissions()
  }

  #removeQueuedFile(clientMessageId) {
    this.#failedFiles.delete(clientMessageId)
    this.#uncertainFiles.delete(clientMessageId)
    const remainingFiles = this.#files.filter((submission) => submission.clientMessageId != clientMessageId)
    if (remainingFiles.length == this.#files.length) return

    this.#files = remainingFiles
    this.#updateFileList()
  }

  #storePendingSubmissions() {
    try {
      if (this.#pendingSubmissions.length > 0) {
        sessionStorage.setItem(this.#pendingSubmissionsKey, JSON.stringify(this.#pendingSubmissions))
      } else {
        sessionStorage.removeItem(this.#pendingSubmissionsKey)
      }
      this.#markDraftStorageAvailable(true)
    } catch (_) {
      this.#markDraftStorageAvailable(false)
    }
  }

  async #postPendingSubmission(submission) {
    const body = new FormData()
    body.append("message[body]", submission.body)
    body.append("message[client_message_id]", submission.clientMessageId)
    const headers = { "Accept": "text/vnd.turbo-stream.html" }
    const csrfToken = document.querySelector("meta[name=csrf-token]")?.content
    if (csrfToken) headers["X-CSRF-Token"] = csrfToken

    const response = await fetch(this.element.action, {
      method: "POST",
      body,
      credentials: "same-origin",
      redirect: "error",
      headers
    })
    const contentType = response.headers.get("Content-Type") || ""
    const stream = await response.text()

    if (!response.ok || !contentType.includes("text/vnd.turbo-stream.html") ||
        !this.#streamContainsMessage(stream, submission.clientMessageId)) {
      const error = new Error("Message retry returned an unexpected response")
      error.status = response.status
      throw error
    }

    return stream
  }

  #streamContainsMessage(stream, clientMessageId) {
    const responseDocument = new DOMParser().parseFromString(stream, "text/html")
    return Array.from(responseDocument.querySelectorAll("turbo-stream template")).some((template) =>
      template.content.getElementById(this.#messageDomId(clientMessageId))
    )
  }

  #messageDomId(clientMessageId) {
    return `message_${this.roomIdValue}_${clientMessageId}`
  }

  #checkDraftStorage() {
    const key = `${this.#draftKey}:probe`

    try {
      sessionStorage.setItem(key, "true")
      sessionStorage.removeItem(key)
      this.#markDraftStorageAvailable(true)
    } catch (_) {
      this.#markDraftStorageAvailable(false)
    }
  }

  #markDraftStorageAvailable(available) {
    document.documentElement.dataset.draftStorageAvailable = available.toString()
  }

  get #draftKey() {
    return `campfire-draft:${Current.user.id}:${this.roomIdValue}`
  }

  get #pendingSubmissionsKey() {
    return `${this.#draftKey}:pending`
  }

  #failureOptions(kind, status, { retryable = true, uncertain = false } = {}) {
    return { kind, permanent: this.#isPermanentFailure(status), retryable, status, uncertain }
  }

  #isPermanentFailure(status) {
    return PERMANENT_FAILURE_STATUSES.has(Number(status))
  }

  #uploadOutcomeUnknown(error) {
    return error?.outcomeUnknown === true || Number(error?.status) >= 500
  }

  #unknownUploadOutcomeError(message) {
    const error = new Error(message)
    error.outcomeUnknown = true
    return error
  }

  #restorePendingFailure(clientMessageId) {
    const fileSubmission = this.#failedFiles.get(clientMessageId)

    if (fileSubmission) {
      this.#failedFiles.delete(clientMessageId)
      if (Number(fileSubmission.failureStatus) == 409) {
        fileSubmission.clientMessageId = this.#generateClientId()
      }
      this.#files.push(fileSubmission)
      this.messagesOutlet.removePendingMessage(clientMessageId)
      this.#updateFileList()
      onNextEventLoopTick(() => {
        this.fileListTarget.querySelector(
          `[data-composer-client-message-id="${fileSubmission.clientMessageId}"]`
        )?.focus()
      })
      return
    }

    const submission = this.#pendingSubmissions.find((pending) => pending.clientMessageId == clientMessageId)
    if (!submission) return

    if (this.#validInput()) {
      const editor = this.textTarget.editor
      const end = Math.max(editor.getDocument().toString().length - 1, 0)
      editor.setSelectedRange([ end ])
      editor.insertHTML("<br>")
      editor.insertHTML(submission.body)
    } else {
      this.textTarget.editor.loadHTML(submission.body)
    }

    this.#removePendingSubmission(clientMessageId)
    this.messagesOutlet.removePendingMessage(clientMessageId)
    this.saveDraft()
    this.textTarget.focus()
  }

  #discardPendingFailure(clientMessageId) {
    if (this.#uncertainFiles.has(clientMessageId)) return

    this.#failedFiles.delete(clientMessageId)
    this.#removePendingSubmission(clientMessageId)
    this.#removeQueuedFile(clientMessageId)
    this.messagesOutlet.removePendingMessage(clientMessageId)
    this.textTarget.focus()
  }

  #updateFileList() {
    this.#files.sort((a, b) => a.file.name.localeCompare(b.file.name))

    const selectedIds = new Set(this.#files.map(({ clientMessageId }) => clientMessageId))
    for (const [ clientMessageId, url ] of this.#filePreviewUrls) {
      if (!selectedIds.has(clientMessageId)) {
        URL.revokeObjectURL(url)
        this.#filePreviewUrls.delete(clientMessageId)
      }
    }

    const fileNodes = this.#files.map(({ file, clientMessageId }, index) => {
      const filename = file.name.split(".").slice(0, -1).join(".")
      const extension = file.name.split(".").pop()

      const node = document.createElement("button")
      node.setAttribute("type","button")
      node.setAttribute("style","gap: 0")
      node.setAttribute("aria-label", `Remove ${file.name}`)
      node.setAttribute("title", `Remove ${file.name}`)
      node.dataset.action = "composer#fileUnpicked"
      node.dataset.composerClientMessageId = clientMessageId
      node.dataset.composerIndexParam = index
      node.className = "btn btn--plain composer__file txt-normal position-relative unpad flex-column"
      node.innerHTML = file.type.match(/^image\/.*/) ? `<img alt="" class="flex-item-no-shrink composer__file-thumbnail" src="${this.#filePreviewUrl(clientMessageId, file)}">` : `<span class="composer__file-thumbnail composer__file-thumbnail--common colorize--black"></span>`
      node.innerHTML += `<span class="pad-inline txt-small flex align-center max-width composer__file-caption"><span class="overflow-ellipsis">${escapeHTML(filename)}.</span><span class="flex-item-no-shrink">${escapeHTML(extension)}</span></span>`

      return node
    })

    this.fileListTarget.replaceChildren(...fileNodes)
  }

  #pendingUploadProgress(filename, percent=0) {
    const escapedFilename = escapeHTML(filename)
    return `
      <div class="message__pending-upload flex align-center gap" style="--percentage: ${percent}%"
          role="progressbar" aria-label="Uploading ${escapedFilename}" aria-valuemin="0" aria-valuemax="100"
          aria-valuenow="${percent}" aria-valuetext="${percent}% uploaded">
        <div class="composer__file-thumbnail composer__file-thumbnail--common colorize--black borderless flex-item-no-shrink"></div>
        <div>${escapedFilename} - <span>${percent}%</span></div>
      </div>
    `
  }

  #filePreviewUrl(clientMessageId, file) {
    if (!this.#filePreviewUrls.has(clientMessageId)) {
      this.#filePreviewUrls.set(clientMessageId, URL.createObjectURL(file))
    }
    return this.#filePreviewUrls.get(clientMessageId)
  }

  #revokeFilePreviewUrls() {
    this.#filePreviewUrls.forEach((url) => URL.revokeObjectURL(url))
    this.#filePreviewUrls.clear()
  }
}
