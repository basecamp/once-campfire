# Migrating Action Cable from Redis to Solid Cable

This release changes Action Cable's production adapter to Solid Cable, backed by its own SQLite database at `storage/db/production_cable.sqlite3`. Together with Solid Cache and Solid Queue, this removes Redis as a runtime requirement.

## Upgrade

No Redis data migration or queue-drain step is needed for this change. Deploy the release normally; `db:prepare` creates the cable database and loads `db/cable_schema.rb`. Existing Redis broadcasts are transient and are not copied. Active WebSocket connections will reconnect as the application restarts.

Solid Cable polls for broadcasts every 100 ms by default, and the configured one-day message retention is only for its internal delivery window. These defaults trade a small amount of broadcast latency and database activity for not requiring a separate Redis service. The 100 ms interval is a starting point, not a Campfire-specific performance claim; measure under representative traffic before tuning it.

Every web and job process must connect to the same Solid Cable database. Separate per-host SQLite files partition broadcasts and remote disconnects, and a rolling deployment that mixes Redis and Solid Cable processes cannot exchange broadcasts between them. Keep the processes on one adapter and a shared database for the cutover; if the deployment cannot provide shared SQLite storage, use a shared database service or retain Redis instead.

After confirming the new release is healthy, remove the Redis service/container and any `REDIS_URL` configuration from your deployment. Redis remains necessary when running a release from before this migration.

## Backups and restores

The cable database contains transient broadcasts, not durable chat history. It is intentionally omitted from `script/admin/prepare-backup` and the self-hosting archive, and `hooks/post-restore` removes any cable database and SQLite sidecars left in the volume. The next `db:prepare` creates a clean database. This prevents messages from an unrelated point in time being delivered after restore.

No additional maintenance window is required. For an application rollback to a release that uses the Redis adapter, restore the matching release and provide its Redis service as before; Solid Cable's database can remain unused.
