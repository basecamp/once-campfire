import { Controller } from "@hotwired/stimulus"
import FileUploader from "models/file_uploader"
import { onNextEventLoopTick, nextFrame } from "helpers/timing_helpers"
import { escapeHTML } from "helpers/dom_helpers"

const PERMANENT_FAILURE_STATUSES = new Set([ 403, 404, 409, 413, 422 ])
const UNCERTAIN_FILE_RECORD_TTL = 24 * 60 * 60 * 1000
const MAX_UNCERTAIN_FILE_RECORDS = 20
const PENDING_SUBMISSIONS_HISTORY_KEY = "campfirePendingSubmissions"
const uncertainFileSubmissions = new Map()

export default class extends Controller {
  static classes = ["toolbar"]
  static targets = [ "clientid", "fields", "fileInput", "fileList", "text" ]
  static values = { reconciliationUrl: String, roomId: Number }
  static outlets = [ "messages" ]

  #files = []
  #activeUploads = new Map()
  #fileSubmissionRequested = false
  #submittingFiles = false
  #submittingMessage = false
  #activeSubmission
  #failedFiles = new Map()
  #filePreviewUrls = new Map()
  #pendingSubmissions = []
  #retryingSubmissionIds = new Set()
  #uncertainFiles = new Map()
  #uncertainFileRecords = new Map()
  #reselectingFileId

  connect() {
    document.addEventListener("turbo:before-visit", this.#beforeVisit)
    window.addEventListener("beforeunload", this.#beforeUnload)
    window.addEventListener("pagehide", this.#pageHide)
    this.#checkDraftStorage()
    this.#pendingSubmissions = this.#readPendingSubmissions()
    this.#uncertainFileRecords = this.#readUncertainFileRecords()
    this.#loadUncertainFiles()
    onNextEventLoopTick(() => this.#restoreDraft())

    if (!this.#usingTouchDevice) {
      onNextEventLoopTick(() => this.textTarget.focus())
    }

    this.#updateFileList()
  }

  disconnect() {
    document.removeEventListener("turbo:before-visit", this.#beforeVisit)
    window.removeEventListener("beforeunload", this.#beforeUnload)
    window.removeEventListener("pagehide", this.#pageHide)
    this.#abortActiveUploads()
    this.#revokeFilePreviewUrls()
  }

  beforeCache() {
    this.#abortActiveUploads()
    const retainedIds = new Set(this.#uncertainFiles.keys())
    const removableSubmissions = [ ...this.#files, ...this.#failedFiles.values() ]
    for (const { clientMessageId } of removableSubmissions) {
      if (!retainedIds.has(clientMessageId)) this.messagesOutlet.removePendingMessage(clientMessageId)
    }

    this.#files = []
    this.#failedFiles.clear()
    this.#updateFileList()
  }

  messagesOutletConnected() {
    onNextEventLoopTick(async () => {
      await this.#restorePendingSubmissions()
      await this.#restoreUncertainFiles()
    })
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

    if (this.messagesOutlet.pendingMessageCommitted(submission.clientMessageId)) {
      this.#commitPendingSubmission(submission)
    } else {
      const status = event.detail.fetchResponse?.statusCode || event.detail.fetchResponse?.response?.status
      submission.failureStatus = status
      this.#storePendingSubmissions()
      this.messagesOutlet.failPendingMessage(
        submission.clientMessageId,
        this.#failureOptions("message", status, {
          persistenceUnavailable: submission.persistenceUnavailable,
          uncertain: this.#messageOutcomeUnknown(status)
        })
      )
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
    let reselectingFileId = this.#reselectingFileId
    for (const file of event.target.files) {
      this.#queueFile(file, reselectingFileId)
      reselectingFileId = null
    }
    this.#reselectingFileId = null
    event.target.value = null
    this.#updateFileList()
  }

  fileUnpicked(event) {
    const index = event.params.index
    const restoreFocus = document.activeElement == event.currentTarget
    const [ submission ] = this.#files.splice(index, 1)
    if (submission) {
      this.messagesOutlet.removePendingMessage(submission.clientMessageId)
      if (this.#uncertainFileRecords.has(submission.clientMessageId)) {
        this.#uncertainFiles.delete(submission.clientMessageId)
        uncertainFileSubmissions.delete(this.#uncertainFileKey(submission.clientMessageId))
      }
    }
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

  #beforeVisit = (event) => {
    const hasUnpersistedMessage = this.#pendingSubmissions.some(
      (submission) => submission.persistenceUnavailable
    )
    if (this.#activeUploads.size == 0 && !hasUnpersistedMessage) return

    const warning = this.#activeUploads.size > 0 && hasUnpersistedMessage ?
      "An attachment is still uploading and an uncertain message ID could not be saved. Leave this page? The upload may still be sent, and returning may make a safe message retry impossible." :
      this.#activeUploads.size > 0 ?
        "An attachment is still uploading. Leave this page? The upload will be canceled where possible, but it may still be sent." :
        "An uncertain message ID could not be saved. Leave this page? Returning may make a safe retry impossible."
    const leave = window.confirm(warning)
    if (leave) {
      this.#abortActiveUploads()
    } else {
      event.preventDefault()
    }
  }

  #beforeUnload = (event) => {
    const hasUnpersistedMessage = this.#pendingSubmissions.some(
      (submission) => submission.persistenceUnavailable
    )
    if (this.#activeUploads.size == 0 && !hasUnpersistedMessage) return

    this.#recordActiveUploadMetadata()
    if (document.documentElement.dataset.sessionInvalidated == "true") return

    event.preventDefault()
    event.returnValue = ""
  }

  #pageHide = () => {
    this.#recordActiveUploadMetadata()
  }

  confirmPendingMessage({ detail: { clientMessageId, userId } }) {
    if (Number(userId) != Number(Current.user.id)) return

    const submission = this.#pendingSubmissions.find((pending) => pending.clientMessageId == clientMessageId)
    if (submission) this.#commitPendingSubmission(submission)
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
    } else if (action == "reconcile") {
      await this.#reconcileUncertainFile(clientMessageId)
      return
    } else if (action == "select-file") {
      this.#reselectingFileId = clientMessageId
      this.fileInputTarget.click()
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
      const reconciliation = await this.#reconcileClientMessage(clientMessageId)
      if (reconciliation == "committed") {
        await this.messagesOutlet.announcePendingMessageSent(clientMessageId)
        this.#removePendingSubmission(clientMessageId)
        return
      } else if (reconciliation == "unavailable") {
        submission.failureStatus = 404
        this.#storePendingSubmissions()
        this.messagesOutlet.failPendingMessage(
          clientMessageId, this.#failureOptions("message", 404, {
            persistenceUnavailable: submission.persistenceUnavailable
          })
        )
        return
      }

      const stream = await this.#postPendingSubmission(submission)
      Turbo.renderStreamMessage(stream)
      await nextFrame()
      if (!this.messagesOutlet.pendingMessageCommitted(clientMessageId)) {
        throw new Error("Message retry was not confirmed")
      }
      await this.messagesOutlet.announcePendingMessageSent(clientMessageId)
      this.#removePendingSubmission(clientMessageId)
    } catch (error) {
      if (this.messagesOutlet.pendingMessageCommitted(clientMessageId)) {
        await this.messagesOutlet.announcePendingMessageSent(clientMessageId)
        this.#removePendingSubmission(clientMessageId)
      } else {
        submission.failureStatus = error.status
        this.#storePendingSubmissions()
        this.messagesOutlet.failPendingMessage(
          clientMessageId,
          this.#failureOptions("message", error.status, {
            persistenceUnavailable: submission.persistenceUnavailable,
            uncertain: this.#messageOutcomeUnknown(error.status)
          })
        )
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

    const retainedSubmission = this.#pendingSubmissions.find((submission) =>
      submission.body == this.textTarget.value && !this.#isPermanentFailure(submission.failureStatus)
    )
    if (retainedSubmission) {
      await this.retryPendingMessage({ detail: { clientMessageId: retainedSubmission.clientMessageId } })
      return
    }

    this.#submittingMessage = true
    const submission = {
      clientMessageId: this.#generateClientId(), body: this.textTarget.value,
      editorRetained: false, persistenceUnavailable: false
    }
    const pendingBody = document.createElement("div")
    pendingBody.innerHTML = submission.body
    let pendingMessageInserted = false

    this.#activeSubmission = submission
    submission.editorRetained = !this.#addPendingSubmission(submission)
    submission.persistenceUnavailable = submission.editorRetained
    if (!submission.persistenceUnavailable) this.#storePendingSubmissions()
    if (!submission.editorRetained) {
      this.#reset()
      this.#clearDraft()
    }

    try {
      while (!pendingMessageInserted) {
        pendingMessageInserted = await this.messagesOutlet.insertPendingMessage(submission.clientMessageId, pendingBody)
        if (!pendingMessageInserted) {
          this.#removePendingSubmission(submission.clientMessageId)
          submission.clientMessageId = this.#generateClientId()
          if (!this.#addPendingSubmission(submission)) {
            submission.editorRetained = true
            submission.persistenceUnavailable = true
            if (!this.#validInput()) this.textTarget.editor.loadHTML(submission.body)
          } else {
            submission.persistenceUnavailable = false
            this.#storePendingSubmissions()
          }
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

          const response = await this.#uploadFile(submission, pendingMessageInserted)
          if (!this.#streamContainsMessage(response, submission.clientMessageId)) {
            throw this.#unknownUploadOutcomeError("Upload returned an unexpected response")
          }
          Turbo.renderStreamMessage(response)
          await nextFrame()
          if (!this.messagesOutlet.pendingMessageCommitted(submission.clientMessageId)) {
            throw this.#unknownUploadOutcomeError("Upload was not confirmed")
          }
          this.#forgetUncertainFile(submission.clientMessageId)
        } catch (error) {
          if (this.messagesOutlet.pendingMessageCommitted(submission.clientMessageId)) {
            this.#removeQueuedFile(submission.clientMessageId)
            this.messagesOutlet.removePendingMessage(submission.clientMessageId)
          } else {
            this.#handleFileFailure(submission, error, pendingMessageInserted)
          }
        } finally {
          this.#activeUploads.delete(submission.clientMessageId)
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
      const response = await this.#uploadFile(submission, true)
      if (!this.#streamContainsMessage(response, clientMessageId)) {
        throw this.#unknownUploadOutcomeError("Upload retry returned an unexpected response")
      }
      Turbo.renderStreamMessage(response)
      await nextFrame()
      if (!this.messagesOutlet.pendingMessageCommitted(clientMessageId)) {
        throw this.#unknownUploadOutcomeError("Upload retry was not confirmed")
      }
      this.#forgetUncertainFile(clientMessageId)
    } catch (error) {
      if (this.messagesOutlet.pendingMessageCommitted(clientMessageId)) {
        this.#removeQueuedFile(clientMessageId)
        this.messagesOutlet.removePendingMessage(clientMessageId)
      } else {
        this.#handleFileFailure(submission, error, true)
      }
    } finally {
      this.#activeUploads.delete(clientMessageId)
      this.#retryingSubmissionIds.delete(clientMessageId)
    }
  }

  async #reconcileUncertainFile(clientMessageId) {
    const record = this.#uncertainFileRecords.get(clientMessageId)
    if (!record || this.#retryingSubmissionIds.has(clientMessageId)) return

    this.#retryingSubmissionIds.add(clientMessageId)
    this.messagesOutlet.retryPendingMessage(clientMessageId, { kind: "file" })

    try {
      const reconciliation = await this.#reconcileClientMessage(clientMessageId)
      if (reconciliation == "committed") {
        this.#forgetUncertainFile(clientMessageId)
      } else {
        this.messagesOutlet.failPendingMessage(
          clientMessageId, this.#failureOptions("file", record.failureStatus, { uncertain: true })
        )
        this.#configureUploadReconciliation(record, { absent: reconciliation == "absent" })
      }
    } finally {
      this.#retryingSubmissionIds.delete(clientMessageId)
    }
  }

  #handleFileFailure(submission, error, pendingMessageInserted) {
    const { clientMessageId } = submission
    submission.failureStatus = error.status
    this.#failedFiles.delete(clientMessageId)
    this.#forgetUncertainFile(clientMessageId)

    if (this.#uploadOutcomeUnknown(error)) {
      this.#rememberUncertainFile(submission)
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

  async #uploadFile(submission, pendingMessageInserted) {
    const uploader = this.#fileUploaderFor(submission)
    const activeUpload = { uploader, submission, pendingMessageInserted }
    this.#activeUploads.set(submission.clientMessageId, activeUpload)

    return await uploader.upload()
  }

  #abortActiveUploads() {
    for (const { uploader, submission, pendingMessageInserted } of this.#activeUploads.values()) {
      if (!this.#uncertainFiles.has(submission.clientMessageId)) {
        this.#handleFileFailure(
          submission, this.#unknownUploadOutcomeError("Upload was interrupted"), pendingMessageInserted
        )
      }
      uploader.abort()
    }
  }

  #recordActiveUploadMetadata() {
    for (const { submission } of this.#activeUploads.values()) this.#recordUncertainFile(submission)
  }

  #rememberUncertainFile(submission) {
    this.#uncertainFiles.set(submission.clientMessageId, submission)
    uncertainFileSubmissions.set(this.#uncertainFileKey(submission.clientMessageId), submission)
    this.#recordUncertainFile(submission)
  }

  #recordUncertainFile(submission) {
    const record = {
      clientMessageId: submission.clientMessageId,
      filename: submission.file.name,
      size: submission.file.size,
      type: submission.file.type,
      lastModified: submission.file.lastModified,
      failureStatus: submission.failureStatus,
      recordedAt: Date.now()
    }
    this.#uncertainFileRecords.delete(record.clientMessageId)
    this.#uncertainFileRecords.set(record.clientMessageId, record)
    while (this.#uncertainFileRecords.size > MAX_UNCERTAIN_FILE_RECORDS) {
      this.#uncertainFileRecords.delete(this.#uncertainFileRecords.keys().next().value)
    }
    this.#storeUncertainFileRecords()
  }

  #uploadProgress(percent, clientMessageId, file) {
    const body = this.#pendingUploadProgress(file.name, percent)
    this.messagesOutlet.updatePendingMessage(clientMessageId, body)
  }

  #generateClientId() {
    return Math.random().toString(36).slice(2)
  }

  #queueFile(file, requestedClientMessageId = null) {
    let record = requestedClientMessageId && this.#uncertainFileRecords.get(requestedClientMessageId)
    if (requestedClientMessageId && !record) return false
    if (record && !this.#fileMatchesRecord(file, record)) {
      this.#configureUploadReconciliation(record, { mismatch: true })
      return false
    }

    record ||= [ ...this.#uncertainFileRecords.values() ].find((candidate) =>
      !this.#uncertainFiles.has(candidate.clientMessageId) &&
      !this.#files.some((submission) => submission.clientMessageId == candidate.clientMessageId) &&
      this.#fileMatchesRecord(file, candidate)
    )

    const submission = { file, clientMessageId: record?.clientMessageId || this.#generateClientId() }
    this.#files.push(submission)
    if (record) {
      this.#uncertainFiles.set(submission.clientMessageId, submission)
      uncertainFileSubmissions.set(this.#uncertainFileKey(submission.clientMessageId), submission)
      this.messagesOutlet.removePendingMessage(submission.clientMessageId)
    }
    return true
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

      if (!this.#isPermanentFailure(submission.failureStatus)) {
        const reconciliation = await this.#reconcileClientMessage(submission.clientMessageId)
        if (reconciliation == "committed") {
          this.#removePendingSubmission(submission.clientMessageId)
          continue
        } else if (reconciliation == "unavailable") {
          submission.failureStatus = 404
          this.#storePendingSubmissions()
        }
      }

      if (!document.getElementById(this.#messageDomId(submission.clientMessageId))) {
        const body = document.createElement("div")
        body.innerHTML = submission.body
        await this.messagesOutlet.insertPendingMessage(
          submission.clientMessageId, body, { preservePagination: true }
        )
      }
      this.messagesOutlet.failPendingMessage(
        submission.clientMessageId,
        this.#failureOptions("message", submission.failureStatus, {
          persistenceUnavailable: submission.persistenceUnavailable,
          uncertain: this.#messageOutcomeUnknown(submission.failureStatus)
        })
      )
    }
  }

  async #restoreUncertainFiles() {
    for (const record of [ ...this.#uncertainFileRecords.values() ]) {
      const { clientMessageId } = record
      if (this.messagesOutlet.pendingMessageCommitted(clientMessageId)) {
        this.#forgetUncertainFile(clientMessageId)
        continue
      }

      const submission = this.#uncertainFiles.get(clientMessageId)
      if (!document.getElementById(this.#messageDomId(clientMessageId))) {
        await this.messagesOutlet.insertPendingMessage(
          clientMessageId,
          submission ? this.#pendingUploadProgress(submission.file.name) : this.#pendingUploadOutcome(record.filename),
          { preservePagination: true }
        )
      }
      this.messagesOutlet.failPendingMessage(
        clientMessageId, this.#failureOptions("file", record.failureStatus, { uncertain: true })
      )
      if (!submission) this.#configureUploadReconciliation(record)
    }
  }

  #loadUncertainFiles() {
    const prefix = `${Current.user.id}:${this.roomIdValue}:`
    for (const [ key, submission ] of uncertainFileSubmissions) {
      if (key.startsWith(prefix)) {
        this.#uncertainFiles.set(submission.clientMessageId, submission)
        if (!this.#uncertainFileRecords.has(submission.clientMessageId)) {
          this.#recordUncertainFile(submission)
        }
      }
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
    let storedValue
    try {
      storedValue = sessionStorage.getItem(this.#pendingSubmissionsKey)
      if (storedValue) {
        const submissions = this.#validPendingSubmissions(JSON.parse(storedValue))
        this.#storePendingSubmissionsInHistory([])
        return submissions
      }
    } catch (_) {
      this.#markDraftStorageAvailable(false)
    }

    const capturedRecord = window.campfirePendingSubmissionsFromHistory
    delete window.campfirePendingSubmissionsFromHistory
    const record = history.state?.[PENDING_SUBMISSIONS_HISTORY_KEY] || capturedRecord
    if (record?.key != this.#pendingSubmissionsKey) return []

    const submissions = this.#validPendingSubmissions(record.submissions)
    if (submissions.length > 0) this.#storePendingSubmissionsInHistory(submissions)
    return submissions
  }

  #validPendingSubmissions(submissions) {
    if (!Array.isArray(submissions)) return []

    return submissions.filter((submission) =>
      typeof submission?.clientMessageId == "string" && typeof submission?.body == "string"
    )
  }

  #readUncertainFileRecords() {
    try {
      const value = sessionStorage.getItem(this.#uncertainFilesKey)
      if (!value) return new Map()

      const now = Date.now()
      const records = JSON.parse(value)
      if (!Array.isArray(records)) return new Map()

      return new Map(records.filter((record) =>
        typeof record?.clientMessageId == "string" && /^[a-z0-9]{1,64}$/.test(record.clientMessageId) &&
        typeof record?.filename == "string" && record.filename.length <= 255 &&
        Number.isFinite(record?.size) && record.size >= 0 && typeof record?.type == "string" &&
        Number.isFinite(record?.lastModified) &&
        Number.isFinite(record?.recordedAt) && now - record.recordedAt < UNCERTAIN_FILE_RECORD_TTL
      ).slice(-MAX_UNCERTAIN_FILE_RECORDS).map((record) => [ record.clientMessageId, record ]))
    } catch (_) {
      this.#markDraftStorageAvailable(false)
      return new Map()
    }
  }

  #addPendingSubmission(submission) {
    this.#pendingSubmissions = this.#pendingSubmissions.filter(
      (pending) => pending.clientMessageId != submission.clientMessageId
    )
    this.#pendingSubmissions.push(submission)
    return this.#storePendingSubmissions()
  }

  #commitPendingSubmission(submission) {
    if (submission.editorRetained && this.textTarget.value == submission.body) {
      this.#reset()
      this.#clearDraft()
    }
    this.#removePendingSubmission(submission.clientMessageId)
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
    this.#forgetUncertainFile(clientMessageId)
    const remainingFiles = this.#files.filter((submission) => submission.clientMessageId != clientMessageId)
    if (remainingFiles.length == this.#files.length) return

    this.#files = remainingFiles
    this.#updateFileList()
  }

  #storePendingSubmissions() {
    try {
      if (this.#pendingSubmissions.length > 0) {
        sessionStorage.setItem(this.#pendingSubmissionsKey, JSON.stringify(this.#pendingSubmissions))
        this.#markDraftStorageAvailable(true)
      } else {
        sessionStorage.removeItem(this.#pendingSubmissionsKey)
      }
      this.#storePendingSubmissionsInHistory([])
      return true
    } catch (_) {
      this.#markDraftStorageAvailable(false)
      return this.#storePendingSubmissionsInHistory()
    }
  }

  #storePendingSubmissionsInHistory(submissions = this.#pendingSubmissions) {
    try {
      const state = history.state && typeof history.state == "object" ? { ...history.state } : {}
      if (submissions.length > 0) {
        state[PENDING_SUBMISSIONS_HISTORY_KEY] = { key: this.#pendingSubmissionsKey, submissions }
      } else if (state[PENDING_SUBMISSIONS_HISTORY_KEY]?.key == this.#pendingSubmissionsKey) {
        delete state[PENDING_SUBMISSIONS_HISTORY_KEY]
      }
      history.replaceState(state, "", window.location.href)
      window.campfirePendingSubmissionsFromHistory = state[PENDING_SUBMISSIONS_HISTORY_KEY]
      return true
    } catch (_) {
      return false
    }
  }

  #storeUncertainFileRecords() {
    try {
      if (this.#uncertainFileRecords.size > 0) {
        sessionStorage.setItem(this.#uncertainFilesKey, JSON.stringify([ ...this.#uncertainFileRecords.values() ]))
        this.#markDraftStorageAvailable(true)
      } else {
        sessionStorage.removeItem(this.#uncertainFilesKey)
      }
      return true
    } catch (_) {
      this.#markDraftStorageAvailable(false)
      return false
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

  async #reconcileClientMessage(clientMessageId) {
    const url = new URL(this.reconciliationUrlValue, window.location.origin)
    url.searchParams.set("client_message_id", clientMessageId)

    try {
      const response = await fetch(url, {
        cache: "no-store",
        credentials: "same-origin",
        headers: { "Accept": "text/vnd.turbo-stream.html" }
      })
      if (response.status == 204) return "absent"
      if (response.status == 404) return "unavailable"
      if (!response.ok) return "unknown"

      const contentType = response.headers.get("Content-Type") || ""
      const stream = await response.text()
      if (!contentType.includes("text/vnd.turbo-stream.html") ||
          !this.#streamContainsMessage(stream, clientMessageId)) return "unknown"

      Turbo.renderStreamMessage(stream)
      await nextFrame()
      return this.messagesOutlet.pendingMessageCommitted(clientMessageId) ? "committed" : "unknown"
    } catch (_) {
      return "unknown"
    }
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

  get #uncertainFilesKey() {
    return `${this.#draftKey}:uncertain-files`
  }

  #forgetUncertainFile(clientMessageId) {
    this.#uncertainFiles.delete(clientMessageId)
    uncertainFileSubmissions.delete(this.#uncertainFileKey(clientMessageId))
    if (this.#uncertainFileRecords.delete(clientMessageId)) this.#storeUncertainFileRecords()
  }

  #uncertainFileKey(clientMessageId) {
    return `${Current.user.id}:${this.roomIdValue}:${clientMessageId}`
  }

  #failureOptions(kind, status, { persistenceUnavailable = false, retryable = true, uncertain = false } = {}) {
    return {
      kind, permanent: this.#isPermanentFailure(status), persistenceUnavailable,
      retryable, status, uncertain
    }
  }

  #isPermanentFailure(status) {
    return PERMANENT_FAILURE_STATUSES.has(Number(status))
  }

  #uploadOutcomeUnknown(error) {
    return error?.outcomeUnknown === true || Number(error?.status) >= 500
  }

  #messageOutcomeUnknown(status) {
    const numericStatus = Number(status)
    return status == null || numericStatus == 0 || numericStatus >= 500 ||
      (numericStatus >= 200 && numericStatus < 300)
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

  #configureUploadReconciliation(record, { absent = false, mismatch = false } = {}) {
    const { clientMessageId, filename } = record
    const message = document.getElementById(this.#messageDomId(clientMessageId))
    const status = message?.querySelector("[data-client-message-status]")
    const retryButton = message?.querySelector("[data-client-message-retry]")
    if (!status || !retryButton) return

    if (absent) {
      status.textContent = `No committed upload was found for ${filename}. Select the same file to retry with its original ID.`
      retryButton.textContent = "Select file again"
      retryButton.dataset.clientMessageAction = "select-file"
    } else if (mismatch) {
      status.textContent = `The selected file does not match ${filename}. Select the original file to keep the safe retry ID.`
      retryButton.textContent = "Select original file"
      retryButton.dataset.clientMessageAction = "select-file"
    } else {
      status.textContent = `Upload outcome for ${filename} is unknown. Check the server before selecting the file again.`
      retryButton.textContent = "Check server again"
      retryButton.dataset.clientMessageAction = "reconcile"
    }
    retryButton.disabled = false
    retryButton.hidden = false
  }

  #fileMatchesRecord(file, record) {
    return file.name == record.filename && file.size == record.size && file.type == record.type &&
      file.lastModified == record.lastModified
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

  #pendingUploadOutcome(filename) {
    return `
      <div class="message__pending-upload flex align-center gap">
        <div class="composer__file-thumbnail composer__file-thumbnail--common colorize--black borderless flex-item-no-shrink"></div>
        <div>${escapeHTML(filename)}</div>
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
