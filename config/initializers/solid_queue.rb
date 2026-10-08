# Stop before forking, as Puma does, so workers don't inherit the contender's flock.
SolidQueue.on_start { SqliteWalCheckpoint.stop }
SolidQueue.on_worker_start { SqliteWalCheckpoint.start }
