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
4. Once both queue counts are zero, stop the old container and take a normal Campfire [backup](../self-hosting.md#backups). The pre-migration Resque payloads are not included; the application database and uploaded files are.
5. Pull the new image and recreate the container. The new release prepares the Solid Queue database before starting the web server and worker. Confirm both are healthy before removing maintenance mode.

This creates a short maintenance window, but avoids a dual-queue period and avoids losing work when the Redis-backed queue is replaced. Redis remains required for Action Cable and the Rails cache until their separate [Solid Cable](solid-cable.md) and [Solid Cache](solid-cache.md) migrations; it is no longer the job store.

## Backups and restores

Queued jobs are treated as disposable. `script/admin/prepare-backup` snapshots only the primary database, and the self-hosting backup command excludes `production_queue.sqlite3` and its sidecars. During restore, `hooks/post-restore` removes any queue database left in the volume; the next `db:prepare` creates an empty one. Jobs still pending when a backup was taken (push notifications, webhooks) are not replayed after a restore, where they would be stale anyway.

## If an upgrade needs to be rolled back

If the new release has not accepted traffic yet, it can be rolled back without moving jobs between backends. If traffic has resumed and jobs have been enqueued to Solid Queue, the old Resque release cannot process them; let the Solid Queue release finish them before rolling back, or accept that they are dropped.
