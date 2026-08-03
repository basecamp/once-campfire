web: bin/start-web
redis: redis-server config/redis.conf
workers: FORK_PER_JOB=false INTERVAL=0.1 bundle exec resque-pool --term-graceful-wait --single-process-group
dispatcher: bin/rails runner ReliableWork::Dispatcher.run
