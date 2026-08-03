require "mkmf"

abort "campfire_sqlite_native requires sqlite3ext.h" unless have_header("sqlite3ext.h")

create_makefile("campfire_sqlite_native/campfire_sqlite_native")
