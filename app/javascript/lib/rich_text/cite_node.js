import * as Lexxy from "lexxy"

const { ElementNode } = Lexxy.Lexical

export default class CiteNode extends ElementNode {
  static getType() {
    return "cite"
  }

  static clone(node) {
    return new CiteNode(node.__key)
  }

  static importJSON(serializedNode) {
    return new CiteNode().updateFromJSON(serializedNode)
  }

  static importDOM() {
    return {
      cite: () => ({ conversion: () => ({ node: new CiteNode() }), priority: 1 })
    }
  }

  exportJSON() {
    return { ...super.exportJSON(), type: "cite" }
  }

  createDOM() {
    return document.createElement("cite")
  }

  updateDOM() {
    return false
  }

  exportDOM() {
    return { element: document.createElement("cite") }
  }
}
