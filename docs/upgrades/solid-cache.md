# Migrating the Rails cache to Solid Cache

Production `Rails.cache` moves from Redis to Solid Cache in a dedicated SQLite database at `storage/db/production_cache.sqlite3`. The normal startup `db:prepare` creates the database and loads `db/cache_schema.rb`; no cache data needs to be migrated.

## Upgrade

Deploy the release normally. Existing Redis entries are not copied, so the cache starts cold and repopulates as requests arrive. Redis remains required for Action Cable. Campfire's bounded per-worker response and fragment caches are separate in-memory stores and are unchanged.

## Backups and restores

The cache database is disposable: `script/admin/prepare-backup` intentionally does not snapshot it, and the self-hosting backup command excludes its SQLite file and sidecars. During restore, `hooks/post-restore` removes any cache database left in the volume, including its WAL/SHM/journal files. The next `db:prepare` creates a clean cache database, avoiding entries from a different point in time than the restored application database.

No Redis-to-Solid-Cache data export or maintenance window is required. Rolling back to a release that uses Redis does not require a database rollback; the Solid Cache database is unused by that release.
