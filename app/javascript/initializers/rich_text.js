import * as Lexxy from "lexxy"
import CampfireRichTextExtension from "lib/rich_text/campfire_extension"

Lexxy.configure({
  global: {
    // Keep the content type of mention attachments (application/vnd.campfire.mention)
    // that Campfire has used since its Trix days
    attachmentContentTypeNamespace: "campfire",
    extensions: [ CampfireRichTextExtension ]
  },
  default: {
    // Campfire sends files as separate messages via the composer's own
    // attach button, never through the editor
    toolbar: { attachments: false },

    // Trix offered a single heading level, rendered as h1
    headings: [ "h1" ]
  }
})
