import { post } from "@rails/request.js"
import { escapeHTML, truncateString } from "helpers/string_helpers"

const UNFURLED_TWITTER_AVATAR_CSS_CLASS = "cf-twitter-avatar"
const TWITTER_AVATAR_URL_PREFIX = "https://pbs.twimg.com/profile_images"

export default class OpengraphEmbedOperation {
  constructor(paste) {
    this.paste = paste
    this.editor = this.paste.editor
    this.url = this.paste.string

    this.abortController = new AbortController()
  }

  perform() {
    return this.#createOpenGraphMetadataRequest()
      .then(response => response.json)
      .then(this.#insertOpengraphAttachment.bind(this))
      .catch(() => null)
  }

  abort() {
    this.abortController.abort()
  }

  #createOpenGraphMetadataRequest() {
    return post("/unfurl_link", {
      body: { url: this.url },
      contentType: "application/json",
      signal: this.abortController.signal
    })
  }

  #insertOpengraphAttachment(response) {
    if (this.#shouldInsertOpengraphPreview) {
      const currentRange = this.editor.getSelectedRange()
      this.editor.setSelectedRange(this.editor.getSelectedRange())
      this.editor.recordUndoEntry("Insert Opengraph preview for Pasted URL")
      this.editor.insertAttachment(this.#createOpengraphAttachment(response))
      this.editor.setSelectedRange(currentRange)
    }
  }

  get #shouldInsertOpengraphPreview() {
    return this.editor.getDocument().toString().includes(this.url)
  }

  #createOpengraphAttachment(response) {
    const { title, url, image, description } = response
    const html = this.#generateOpengraphEmbedHTML({ title, url, image, description })

    return new Trix.Attachment({
      contentType: "application/vnd.actiontext.opengraph-embed",
      content: html,
      filename: title,
      href: url,
      url: image,
      caption: description
    })
  }

  #generateOpengraphEmbedHTML(embed) {
    return `<actiontext-opengraph-embed class="${this.#isTwitterAvatar(embed) ? UNFURLED_TWITTER_AVATAR_CSS_CLASS : ''}">
      <div class="og-embed">
        <div class="og-embed__content">
          <div class="og-embed__title">${truncateString(embed.title, 560)}</div>
          <div class="og-embed__description">${truncateString(embed.description, 560)}</div>
        </div>
        <div class="og-embed__image">
          <img src="${escapeHTML(embed.image)}" class="image" alt="" />
        </div>
      </div>
    </actiontext-opengraph-embed>`
  }

  #isTwitterAvatar(embed) {
    return embed.image.startsWith(TWITTER_AVATAR_URL_PREFIX)
  }
}
