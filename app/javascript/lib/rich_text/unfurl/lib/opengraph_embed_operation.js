import { post } from "@rails/request.js"
import { truncateString } from "helpers/string_helpers"

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
    // Check if unfurling is enabled via environment variable
    if (!this.#isUnfurlingEnabled()) {
      console.log("URL unfurling is disabled via ENABLE_URL_UNFURLING environment variable")
      return Promise.resolve()
    }

    console.log(`Attempting to unfurl URL: ${this.url}`)
    
    return this.#createOpenGraphMetadataRequest()
      .then(response => {
        console.log(`Unfurl response for ${this.url}:`, response.status, response.statusText)
        
        if (!response.ok) {
          console.warn(`Failed to fetch OpenGraph metadata for ${this.url}: ${response.status} ${response.statusText}`)
          return null
        }
        return response.json
      })
      .then(data => {
        if (data) {
          console.log(`Successfully unfurled ${this.url}:`, data)
          this.#insertOpengraphAttachment(data)
        } else {
          console.log(`No data returned for ${this.url}`)
        }
      })
      .catch(error => {
        console.warn(`Error unfurling URL ${this.url}:`, error)
      })
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
    const escapedTitle = this.#escapeHtml(truncateString(embed.title, 560))
    const escapedDescription = this.#escapeHtml(truncateString(embed.description, 560))
    const escapedImage = this.#escapeHtml(embed.image)
    
    return `<actiontext-opengraph-embed class="${this.#isTwitterAvatar(embed) ? UNFURLED_TWITTER_AVATAR_CSS_CLASS : ''}">
      <div class="og-embed">
        <div class="og-embed__content">
          <div class="og-embed__title">${escapedTitle}</div>
          <div class="og-embed__description">${escapedDescription}</div>
        </div>
        <div class="og-embed__image">
          <img src="${escapedImage}" class="image" alt="" />
        </div>
      </div>
    </actiontext-opengraph-embed>`
  }

  #escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  #isTwitterAvatar(embed) {
    return embed.image.startsWith(TWITTER_AVATAR_URL_PREFIX)
  }

  #isUnfurlingEnabled() {
    // Check if unfurling is enabled via environment variable
    // This is set by the Rails application in a meta tag
    const metaTag = document.querySelector('meta[name="enable-url-unfurling"]')
    return metaTag && metaTag.getAttribute('content') === 'true'
  }
}
