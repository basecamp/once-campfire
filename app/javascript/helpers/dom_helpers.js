

export function scrollToBottom(container) {
  container.scrollTop = container.scrollHeight
}

export function parseHTMLFragment(html) {
  const template = document.createElement("template")
  template.innerHTML = html
  return template.content
}

export function insertHTMLFragment(fragment, container, top) {
  if (top) {
    container.prepend(fragment)
  } else {
    container.append(fragment)
  }
}

export function ignoringBriefDisconnects(element, fn) {
  requestAnimationFrame(() => {
    if (!element.isConnected) fn()
  })
}

export function trimChildren(count, container, top) {
  const children = Array.from(container.children)
  const elements = top ? children.slice(0, count) : children.slice(-count)

  keepScroll(container, top, function() {
    for (const element of elements) {
      element.remove()
    }
  })
}

export async function keepScroll(container, top, fn) {
  pauseInertiaScroll(container)

  const scrollTop = container.scrollTop
  const scrollHeight = container.scrollHeight

  await fn()

  if (top) {
    container.scrollTop = scrollTop + (container.scrollHeight - scrollHeight)
  } else {
    container.scrollTop = scrollTop
  }
}

function pauseInertiaScroll(container) {
  container.style.overflow = "hidden"

  requestAnimationFrame(() => {
    container.style.overflow = ""
  })
}
