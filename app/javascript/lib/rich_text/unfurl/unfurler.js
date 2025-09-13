import OpengraphEmbedOperation from "lib/rich_text/unfurl/lib/opengraph_embed_operation"
import Paste from "lib/rich_text/unfurl/lib/paste"

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
        return event.target.addEventListener("trix-paste", this.#didPaste.bind(this))
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
