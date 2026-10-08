# Migrating from Resque to Solid Queue

This release changes the Active Job backend from Resque to Solid Queue. It does not copy queued Resque payloads into Solid Queue: the safest migration is to let the old workers finish them before replacing the container.

## Before upgrading

1. Put the instance into maintenance at the reverse proxy or host firewall so it receives no new HTTP or webhook requests. Keep the Campfire container running; its Resque workers need to continue processing jobs. Do not stop or pause the container during this step.
2. Check the old Resque queues from inside the running container. For Docker:

   ```sh
   docker exec campfire bin/rails runner -e production '
     require "resque"
     info = Resque.info
     puts "pending=#{info[:pending]} working=#{info[:working]} failed=#{info[:failed]}"
     Resque.queue_sizes.each { |queue, size| puts "#{queue}=#{size}" }
   '
   ```

   With Docker Compose, use `docker compose exec web` instead of `docker exec campfire`.
3. Keep the instance in maintenance until `pending=0` and `working=0` on repeated checks at least 30 seconds apart. If `failed` is nonzero, inspect or export those failure records and decide how to handle them before proceeding; they are not transferred to Solid Queue.
4. Once both queue counts are zero, stop the old container and take a normal Campfire backup using the [quiesced backup procedure](../self-hosting.md#backups). The pre-migration Resque payloads are not included; the application database and uploaded files are.
5. Pull the new image and recreate the container. The new release prepares the Solid Queue database before starting the web server and worker. Confirm both are healthy before removing maintenance mode.

This creates a short maintenance window, but avoids a dual-queue period and avoids losing work when the Redis-backed queue is replaced. Redis remains required for Action Cable and the Rails cache until their separate migrations; it is no longer the job store.

After this migration, keep both the primary and queue databases quiesced together for backups. `script/admin/prepare-backup` snapshots them one after another and cannot by itself make live writes to separate databases atomic. The ONCE pre-backup hook intentionally fails to request ONCE's safe paused-volume copy; for other hosting setups, stop every web and queue process before calling the backup script and copying storage.

## If an upgrade or restore needs to be rolled back

If the new release has not accepted traffic yet, it can be rolled back without moving jobs between backends. If traffic has resumed and jobs have been enqueued to Solid Queue, keep the `production_queue.sqlite3` database and its WAL files; the old Resque release cannot process those jobs. Restore a compatible Solid Queue release to resume them rather than deleting the queue database.

Backups created before this migration have no `production_queue.sqlite3` snapshot. The restore hook refuses to overwrite an existing queue database when that snapshot is missing. For a restore to a pre-migration point in time, first stop Campfire and preserve the current queue database separately; then remove `storage/db/production_queue.sqlite3` and its `-wal`/`-shm` files only if you have decided that post-backup Solid Queue jobs should be discarded. Run the restore hook after that, then start Campfire.
