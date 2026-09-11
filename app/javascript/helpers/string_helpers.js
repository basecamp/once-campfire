const HTML_ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }

export function truncateString(string, length, omission = "…") {
  if (string.length <= length) {
    return string
  } else {
    return string.slice(0, length - omission.length) + omission
  }
}

export function escapeHTML(string) {
  return String(string).replace(/[&<>"']/g, character => HTML_ESCAPES[character])
}
