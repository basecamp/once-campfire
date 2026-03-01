import mongoose from 'mongoose';
import { identConnection } from '../config/mongodb.js';

const RefreshTokenSchema = new mongoose.Schema({
  token: {
    type: String,
    required: true,
    unique: true
  },
  fcm: {
    type: String
  },
  deviceId: {
    type: String,
    required: true,
  },
  userId: {
    type: String,
    required: true,
    ref: 'User'
  },
  expired_at: {
    type: Date
  },
  created_at: {
    type: Date,
    default: Date.now
  },
  updated_at: {
    type: Date,
    default: Date.now
  }
});

RefreshTokenSchema.pre('save', function(next) {
  this.updated_at = new Date();
  return next();
});

const RefreshToken = identConnection.model('RefreshToken', RefreshTokenSchema);

export default RefreshToken;
