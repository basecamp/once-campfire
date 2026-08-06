export default class FileUploader {
  #request
  #rejectRequest

  constructor(file, url, clientMessageId, progressCallback) {
    this.file = file
    this.url = url
    this.clientMessageId = clientMessageId
    this.progressCallback = progressCallback
  }

  upload() {
    if (this.#request) throw new Error("Upload is already in progress")

    const formdata = new FormData()
    formdata.append("message[attachment]", this.file)
    formdata.append("message[client_message_id]", this.clientMessageId)

    const req = new XMLHttpRequest()
    this.#request = req
    req.open("POST", this.url)
    req.setRequestHeader("X-CSRF-Token", document.querySelector("meta[name=csrf-token]").content)
    req.upload.addEventListener("progress", this.#uploadProgress.bind(this))
    req.timeout = 5 * 60 * 1000

    const result = new Promise((resolve, reject) => {
      this.#rejectRequest = reject
      req.addEventListener("load", () => {
        const contentType = req.getResponseHeader("Content-Type") || ""
        if (req.status >= 200 && req.status < 300 && contentType.includes("text/vnd.turbo-stream.html")) {
          resolve(req.response)
        } else {
          const error = new Error("Upload returned an unexpected response")
          error.status = req.status
          error.outcomeUnknown = req.status == 0 || req.status >= 500 || (req.status >= 200 && req.status < 300)
          reject(error)
        }
      })
      req.addEventListener("error", () => reject(this.#unknownOutcomeError("Upload failed")))
      req.addEventListener("abort", () => reject(this.#unknownOutcomeError("Upload was canceled")))
      req.addEventListener("timeout", () => reject(this.#unknownOutcomeError("Upload timed out")))
    })

    try {
      req.send(formdata)
    } catch (error) {
      this.#request = null
      this.#rejectRequest = null
      throw error
    }
    return result.finally(() => {
      if (this.#request == req) {
        this.#request = null
        this.#rejectRequest = null
      }
    })
  }

  abort() {
    if (!this.#request) return false

    const canAbort = this.#request.readyState != XMLHttpRequest.DONE
    if (canAbort) this.#request.abort()
    this.#rejectRequest?.(this.#unknownOutcomeError("Upload was canceled"))
    return canAbort
  }

  #uploadProgress(event) {
    if (event.lengthComputable) {
      const percent = Math.round((event.loaded / event.total) * 100)
      this.progressCallback(percent, this.clientMessageId, this.file)
    }
  }

  #unknownOutcomeError(message) {
    const error = new Error(message)
    error.outcomeUnknown = true
    return error
  }
}
