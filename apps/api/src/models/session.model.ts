import { randomUUID } from 'node:crypto';
import { Schema, model, type InferSchemaType } from 'mongoose';

const sessionSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    token: { type: String, required: true, unique: true, default: () => randomUUID() },
    ipAddress: { type: String, default: '' },
    userAgent: { type: String, default: '' },
    lastActiveAt: { type: Date, default: () => new Date() }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

sessionSchema.index({ userId: 1, createdAt: -1 });

export type SessionDocument = InferSchemaType<typeof sessionSchema> & { _id: string };

export const SessionModel = model('Session', sessionSchema);
