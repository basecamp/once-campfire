function buildMongoUri() {
  if (process.env.MONGODB_URI) {
    return process.env.MONGODB_URI;
  }

  const user = process.env.MONGODB_USER ?? '';
  const password = process.env.MONGODB_PASSWORD ?? '';

  if (!user || !password) {
    return 'mongodb://127.0.0.1:27017/campfire';
  }

  return `mongodb+srv://${user}:${password}@cluster0.xfv2hzn.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0`;
}

export const mongoUri = buildMongoUri();
export const mongoOptions = {};
