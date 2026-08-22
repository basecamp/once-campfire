Gem::Specification.new do |spec|
  spec.name = "campfire_sqlite_native"
  spec.version = "0.1.0"
  spec.authors = [ "37signals" ]
  spec.summary = "Campfire SQLite main-file identity verifier"
  spec.homepage = "https://github.com/basecamp/once-campfire"
  spec.license = "MIT"

  spec.files = %w[
    ext/campfire_sqlite_native/campfire_sqlite_native.c
    ext/campfire_sqlite_native/extconf.rb
    lib/campfire_sqlite_native.rb
  ]
  spec.require_paths = [ "lib" ]
  spec.extensions = [ "ext/campfire_sqlite_native/extconf.rb" ]
  spec.required_ruby_version = ">= 3.2"
end
