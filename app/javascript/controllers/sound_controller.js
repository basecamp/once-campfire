import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { "url": String, "audioMessageDuration": Number }
  static targets = [ "soundBarContainer", "audioMessageMetadata" ]

  audioMessageMetadataTargetConnected() {
    this.#setInitialDurationMetadata();
  }

  play() {
    const sound = new Audio(this.urlValue)
    sound.play()
  }

  playAndAnimate() {
    const sound = new Audio(this.urlValue)
    sound.addEventListener("ended", () => {
        this.#removeSoundBarAnimateCss();
        this.#setInitialDurationMetadata();
    });

    sound.addEventListener("timeupdate", (event) => {
      this.audioMessageMetadataTarget.innerHTML = this.#formatTime(this.audioMessageDurationValue - sound.currentTime)
    });

    sound.play()
    this.#addSoundBarAnimateCss()
  }

  #removeSoundBarAnimateCss () {
    for (const soundBarItem of this.soundBarContainerTarget.children) {
      soundBarItem.classList.remove("sound-bar-animate")
    }
  }

  #addSoundBarAnimateCss() {
    for (const soundBarItem of this.soundBarContainerTarget.children) {
      soundBarItem.classList.add("sound-bar-animate")
    }
  }

  #formatTime(timeInSeconds) {
    let minutes = Math.floor(Math.ceil(timeInSeconds) / 60)
    let seconds = Math.ceil(timeInSeconds) % 60

    return (minutes < 10 ? '0' + minutes : minutes) + ":" + (seconds < 10 ? '0' + seconds : seconds)
  }

  #setInitialDurationMetadata() {
    this.audioMessageMetadataTarget.innerHTML = this.#formatTime(this.audioMessageDurationValue)
  }
}
