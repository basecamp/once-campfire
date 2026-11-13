web: bundle exec thrust bin/start-app
redis: redis-server config/redis.conf
workers: exec env FORK_PER_JOB=false INTERVAL=0.1 bundle exec resque-pool --term-graceful-wait
