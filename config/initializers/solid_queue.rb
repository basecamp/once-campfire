require "solid_queue"

# The WAL checkpoint contender owns a flock descriptor. Solid Queue forks its
# workers, dispatchers, and scheduler from the supervisor, so stop it in the
# supervisor and create a fresh contender in each child process.
SolidQueue.on_start do
  SqliteWalCheckpoint.stop
end

SolidQueue.on_worker_start do
  SqliteWalCheckpoint.start
end

SolidQueue.on_dispatcher_start do
  SqliteWalCheckpoint.start
end

SolidQueue.on_scheduler_start do
  SqliteWalCheckpoint.start
end

SolidQueue.on_worker_stop do
  SqliteWalCheckpoint.stop
end

SolidQueue.on_dispatcher_stop do
  SqliteWalCheckpoint.stop
end

SolidQueue.on_scheduler_stop do
  SqliteWalCheckpoint.stop
end
