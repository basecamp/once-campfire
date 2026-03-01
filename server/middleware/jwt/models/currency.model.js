import mongoose from 'mongoose';
import { finConnection } from '../config/mongodb.js';

const _schema = new mongoose.Schema({
  createdAt: { type: Date },
  updatedAt: { type: Date },
  code: { type: String },
  name: { type: String },
  symbol: { type: String },
  orderIndex: { type: Number }
});

const FinCurrencies = finConnection.model('Currency', _schema);

export default FinCurrencies;
