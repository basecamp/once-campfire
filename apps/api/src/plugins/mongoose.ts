import fp from 'fastify-plugin';
import mongoose from 'mongoose';
import { env } from '../config/env.js';

async function mongoosePlugin() {
  mongoose.set('strictQuery', true);

  if (mongoose.connection.readyState === 1) {
    return;
  }

  await mongoose.connect(env.MONGODB_URI);
}

export default fp(mongoosePlugin, {
  name: 'mongoose'
});
