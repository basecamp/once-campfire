# Disable unfuzzed libvips operations.
#
# To block loaders we need to call `Vips.block` after Rails and image_processing set their
# defaults. Force the order of operations by autoloading the file now.
ActiveStorage::Transformers::Vips
Vips.block_untrusted(true)
Vips.block("VipsForeignLoadOpenslide", true) # prevent sqlite segfault in forked parallel workers
Rails.application.config.active_storage.variable_content_types -=
    %w[ image/bmp image/vnd.microsoft.icon image/vnd.adobe.photoshop ]
