import * as Lexxy from "lexxy"
import CiteNode from "lib/rich_text/cite_node"

export default class CampfireRichTextExtension extends Lexxy.Extension {
  get allowedElements() {
    return [
      "cite",
      "figure",
      "figcaption",
      "actiontext-opengraph-embed",
      { tag: "div", attributes: [ "sgid" ] },
      { tag: "img", attributes: [ "alt" ] },
      { tag: "a", attributes: [ "rel", "target" ] }
    ]
  }

  get lexicalExtension() {
    return this.defineExtension({
      name: "campfire/rich-text",
      nodes: [ CiteNode ]
    })
  }
}
