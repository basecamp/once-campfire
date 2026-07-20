import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"
import { truncateString } from "helpers/string_helpers"
import { escapeHTML } from "helpers/dom_helpers"

const OPENGRAPH_EMBED_CONTENT_TYPE = "application/vnd.actiontext.opengraph-embed"

const UNFURLED_TWITTER_AVATAR_CSS_CLASS = "cf-twitter-avatar"
const TWITTER_AVATAR_URL_PREFIX = "https://pbs.twimg.com/profile_images"

export default class extends Controller {
  #abortController

  disconnect() {
    this.#abortController?.abort()
  }

  async unfurl(event) {
    if (!this.element.permitsAttachmentContentType(OPENGRAPH_EMBED_CONTENT_TYPE)) return

    const { url, insertBelowLink } = event.detail

    const metadata = await this.#fetchOpengraphMetadata(url)

    if (metadata) {
      insertBelowLink(this.#opengraphEmbedHTML(metadata), { attachment: { contentType: OPENGRAPH_EMBED_CONTENT_TYPE } })
    }
  }

  async #fetchOpengraphMetadata(url) {
    this.#abortController?.abort()
    this.#abortController = new AbortController()

    try {
      const response = await post("/unfurl_link", {
        body: { url },
        contentType: "application/json",
        signal: this.#abortController.signal
      })

      if (response.ok && response.statusCode !== 204) {
        const { title, url: href, image, description } = await response.json
        if (title && href) return { title, href, image, description }
      }
    } catch {
      // Ignore aborted and failed requests
    }

    return null
  }

  #opengraphEmbedHTML({ title, href, image, description }) {
    return `<actiontext-opengraph-embed class="${this.#embedClass(image)}">
      <div class="og-embed gap">
        <div class="og-embed__content">
          <div class="og-embed__title">
            <a href="${escapeHTML(href)}" rel="noreferrer" target="_blank">${escapeHTML(truncateString(title, 280))}</a>
          </div>
          <div class="og-embed__description">${escapeHTML(truncateString(description, 560))}</div>
        </div>
        ${this.#imageHTML(image)}
      </div>
    </actiontext-opengraph-embed>`
  }

  #embedClass(image) {
    if (this.#isTwitterAvatar(image)) {
      return UNFURLED_TWITTER_AVATAR_CSS_CLASS
    } else {
      return ""
    }
  }

  #isTwitterAvatar(image) {
    return Boolean(image) && image.startsWith(TWITTER_AVATAR_URL_PREFIX)
  }

  #imageHTML(image) {
    if (image) {
      return `<div class="og-embed__image"><img src="${escapeHTML(image)}" class="image center" alt="" /></div>`
    } else {
      return ""
    }
  }
}
