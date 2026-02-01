export class Renderer {
  renderAutocompletableSuggestions(autocompletables, options = {}) {
    const { selectedAutocompletable } = options
    let html = ""

    autocompletables.forEach((autocompletable) => {
      const isSelected = autocompletable === selectedAutocompletable
      const multipleAttr = autocompletable.type === "group" ? "multiple" : ""
      const selectedAriaSelectedAttrs = isSelected ? "selected aria-selected" : ""

      html += `
        <suggestion-option class="autocomplete__item flex align-center gap unpad" role="option" value="${autocompletable.value}" ${multipleAttr} ${selectedAriaSelectedAttrs}>
          ${
            autocompletable.pending
              ? `Add <strong>${autocompletable.name}…</strong>`
              : autocompletable.noResultsLabel
              ? `<span class="txt--disable-truncate">${autocompletable.noResultsLabel}</span>`
              : this.renderAutocompletable(autocompletable)
          }
        </suggestion-option>
      `
    })

    return html
  }

  renderAutocompletable(autocompletable) {
    if (autocompletable.emoji) {
      return `
        <button class="autocomplete__btn btn btn--borderless btn--transparent min-width flex-item-grow justify-start" data-value="${autocompletable.value}">
          <span class="autocomplete__emoji" aria-hidden="true">${autocompletable.emoji}</span>
          <span class="autocompletable__name">${autocompletable.label || autocompletable.name}</span>
        </button>
      `
    }

    const html = `
      <button class="autocomplete__btn btn btn--borderless btn--transparent min-width flex-item-grow justify-start" data-value="${autocompletable.value}">
        <span class="avatar">
          <img src="${autocompletable.avatar_url}" class="automcomplete__avatar" role="presentation" />
        </span>
        <span class="autocompletable__name">${autocompletable.name}</span>
        <a href="#" class="autocompletable__unselect" aria-label="Remove ${autocompletable.name}" data-behavior="unselect_autocompletable">×</a>
      </button>
    `

    return html
  }
}
