import { Schema, model } from 'mongoose';

const banSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    ipAddress: { type: String, required: true, index: true },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'bans',
    timestamps: true
  }
);

banSchema.index({ ipAddress: 1 });

export const BanModel = model('Ban', banSchema);
