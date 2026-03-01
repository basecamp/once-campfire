module.exports = {
  apps: [
    {
      name: 'campfire-api',
      script: 'server/dist/server.js',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      max_memory_restart: '512M',
      env: {
        NODE_ENV: 'production',
        DOMAIN: 'api.meteorhr.com',
        MONGODB_USER: 'ruslankhissamov',
        MONGODB_PASSWORD: '6qEHcxKtouFxceH0',
        REDIS_HOST: 'redis-19573.c11.us-east-1-3.ec2.redns.redis-cloud.com',
        REDIS_PORT: '19573',
        REDIS_PASSWORD: '8mpL7HmjTZVeaT9qTJaOB84rcSOPI2Mc',
        TOKEN_EXPIRATION_MINUTES: 15
      }
    }
  ]
};
