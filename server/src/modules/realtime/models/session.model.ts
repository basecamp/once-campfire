import { Schema, model } from 'mongoose';

const sessionSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    token: { type: String, required: true, index: true },
    ipAddress: { type: String, default: null },
    userAgent: { type: String, default: null },
    lastActiveAt: { type: Date, default: Date.now, index: true },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'sessions',
    timestamps: true
  }
);

sessionSchema.index({ token: 1 }, { unique: true });

export const SessionModel = model('Session', sessionSchema);
