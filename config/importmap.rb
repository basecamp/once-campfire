pin "application"

pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "@hotwired/turbo-rails", to: "turbo.js"
pin "@rails/actioncable", to: "actioncable.esm.js"
pin "@rails/request.js", to: "@rails--request.js" # @0.0.8
pin "trix", to: "trix.esm.min.js" # @2.1.19
pin "@rails/actiontext", to: "actiontext.js"
pin "highlight.js", to: "highlight.js/core.js"

pin_all_from "app/javascript/initializers", under: "initializers"
pin_all_from "app/javascript/lib", under: "lib"
pin_all_from "app/javascript/channels", under: "channels"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/helpers", under: "helpers"
pin_all_from "app/javascript/models", under: "models"
pin_all_from "vendor/javascript/languages", under: "languages"
