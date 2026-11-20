# Extended as it loads, and again whenever it reloads, rather than loaded at boot to be extended.
Rails.autoloaders.main.on_load("ActiveStorage::Representations::BaseController") do |controller|
  controller.prepend ActiveStoragePreviewLimits
end
