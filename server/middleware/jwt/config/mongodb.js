import mongoose from 'mongoose';

const config = {
  fin: 'mongodb+srv://'+process.env.MONGODB_USER+':'+process.env.MONGODB_PASSWORD+'@cluster0.xfv2hzn.mongodb.net/?retryWrites=true&w=majority',
  ident: 'mongodb+srv://'+process.env.MONGODB_USER+':'+process.env.MONGODB_PASSWORD+'@cluster0.xfv2hzn.mongodb.net/?retryWrites=true&w=majority',
  option: {}
};

// Shared connections — one per database, reused across all models
const identConnection = await mongoose.createConnection(config.ident, config.option);
const finConnection = await mongoose.createConnection(config.fin, config.option);

identConnection.on('error', (err) => {
  console.error('MongoDB ident connection error:', err.message);
});

finConnection.on('error', (err) => {
  console.error('MongoDB fin connection error:', err.message);
});

export { identConnection, finConnection };
export default config;
