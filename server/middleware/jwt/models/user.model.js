import mongoose from 'mongoose';
import { identConnection } from '../config/mongodb.js';

const UserSchema = new mongoose.Schema({
  email: {
    type: String,
  },
  phone: {
    type: String,
  },
  telegram: {
    type: String,
  },
  fcm: {
    type: String,
  },
  notification: {
    email: { type: Boolean, default: false },
    telegram: { type: Boolean, default: false },
    phone: { type: Boolean, default: false },
    push: { type: Boolean, default: false },
  },
  roles: [{ type: mongoose.Schema.ObjectId, ref: "Role" }],
  active: { type: Boolean, default: true },
  name: {
    first: {
      type: String,
    },
    last: { type: String },
  },
  avatar: {
    type: String,
  },
  company: { type: mongoose.Schema.ObjectId },
});

const User = identConnection.model('User', UserSchema);

export default User;
