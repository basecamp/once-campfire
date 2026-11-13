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
    req.upload.addEventListener("progress", this.#uploadProgress.bind(this))

    const result = new Promise((resolve, reject) => {
      req.addEventListener("readystatechange", () => {
        if (req.readyState === XMLHttpRequest.DONE) {
          // Only a stream answer is the posted message. No answer at all (status 0, as when the network is down), an
          // error, or a page (the sign-in after the session ended, the notice of a room that's gone) means it wasn't.
          if (this.#answeredWithStream(req)) {
            resolve(req.response)
          } else {
            reject()
          }
        }
      })
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

  #answeredWithStream(req) {
    return req.getResponseHeader("Content-Type")?.startsWith("text/vnd.turbo-stream.html") ?? false
  }
}
