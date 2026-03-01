import mongoose from 'mongoose';
import Config from '../../../config/mongodb.js';

const GLOBAL_CONNECTION_KEY = '__onceCampfireMongoConnection';

/**
 * Shared Mongo connection for all models in server/src.
 * Avoid creating isolated connections inside each model file.
 */
if (!globalThis[GLOBAL_CONNECTION_KEY]) {
  globalThis[GLOBAL_CONNECTION_KEY] = mongoose.createConnection(
    Config.ident,
    Config.option ?? {}
  );
}

const mongoConnection = globalThis[GLOBAL_CONNECTION_KEY];
await mongoConnection.asPromise();

export default mongoConnection;
