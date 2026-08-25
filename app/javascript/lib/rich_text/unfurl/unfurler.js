import OpengraphEmbedOperation from "lib/rich_text/unfurl/lib/opengraph_embed_operation"
import Paste from "lib/rich_text/unfurl/lib/paste"
import { debounce } from "helpers/timing_helpers"

const performOperation = (function() {
  let operation = null
  let requestId = null

  return function(operationToPerform) {
    operation?.abort()
    cancelAnimationFrame(requestId)

    requestId = requestAnimationFrame(function() {
      operation = operationToPerform
      operation.perform().then(() => operation = null)
    })
  }
})()

export default class Unfurler {
  install() {
    this.#addEventListeners()
  }

  #addEventListeners() {
    addEventListener("trix-initialize", function(event) {
      if (this.#editorElementPermitsAttribute(event.target, "href")) {
        event.target.addEventListener("trix-paste", this.#didPaste.bind(this))
        event.target.addEventListener("trix-change", this.#didChange.bind(this))
      }
    }.bind(this))
  }

  #didPaste(event) {
    const {range} = event.paste
    const {editor} = event.target

    if (range != null) {
      const paste = new Paste(range, editor).getSignificantPaste()

      if (paste.isURL()) {
        if (this.#editorElementPermitsOpengraphAttachment(event.target)) {
          performOperation(new OpengraphEmbedOperation(paste))
        }
      }
    }
  }

  #didChange(event) {
    this.#debouncedCheckForUrls(event)
  }

  #debouncedCheckForUrls = debounce(function(event) {
    const {editor} = event.target
    const document = editor.getDocument()
    const text = document.toString()
    
    // Look for URLs in the text (simple URL detection)
    const urlRegex = /(https?:\/\/[^\s]+)/g
    const urls = text.match(urlRegex)
    
    if (urls && urls.length > 0) {
      // Get the last URL (most recently typed)
      const lastUrl = urls[urls.length - 1]
      const range = editor.getDocument().getRange()
      
      // Check if the cursor is at the end of a URL
      if (range && range.getCommonAncestorContainer().textContent.endsWith(lastUrl)) {
        const paste = new Paste(range, editor)
        paste.text = lastUrl
        
        if (paste.isURL()) {
          if (this.#editorElementPermitsOpengraphAttachment(event.target)) {
            performOperation(new OpengraphEmbedOperation(paste))
          }
        }
      }
    }
  }, 1000)

  #editorElementPermitsAttribute(element, attributeName) {
    if (element.hasAttribute("data-permitted-attributes")) {
      return Array.from(element.getAttribute("data-permitted-attributes").split(" ")).includes(attributeName)
    } else {
      return true
    }
  }

  #editorElementPermitsOpengraphAttachment(element) {
    const permittedAttachmentTypes = element.getAttribute("data-permitted-attachment-types")
    return permittedAttachmentTypes && permittedAttachmentTypes.includes("application/vnd.actiontext.opengraph-embed")
  }
}
