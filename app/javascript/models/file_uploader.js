export default class FileUploader {
  constructor(file, url, clientMessageId, progressCallback) {
    this.file = file
    this.url = url
    this.clientMessageId = clientMessageId
    this.progressCallback = progressCallback
  }

  upload() {
    const formdata = new FormData()
    formdata.append("message[attachment]", this.file)
    formdata.append("message[client_message_id]", this.clientMessageId)

    const req = new XMLHttpRequest()
    req.open("POST", this.url)
    req.setRequestHeader("X-CSRF-Token", document.querySelector("meta[name=csrf-token]").content)
    req.upload.addEventListener("progress", this.#uploadProgress.bind(this))
    req.timeout = 5 * 60 * 1000

    const result = new Promise((resolve, reject) => {
      req.addEventListener("load", () => {
        const contentType = req.getResponseHeader("Content-Type") || ""
        if (req.status >= 200 && req.status < 300 && contentType.includes("text/vnd.turbo-stream.html")) {
          resolve(req.response)
        } else {
          const error = new Error("Upload returned an unexpected response")
          error.status = req.status
          error.outcomeUnknown = req.status == 0 || req.status >= 500
          reject(error)
        }
      })
      req.addEventListener("error", () => reject(this.#unknownOutcomeError("Upload failed")))
      req.addEventListener("abort", () => reject(this.#unknownOutcomeError("Upload was canceled")))
      req.addEventListener("timeout", () => reject(this.#unknownOutcomeError("Upload timed out")))
    })

    req.send(formdata)
    return result
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
