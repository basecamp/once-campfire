import { Schema, model } from 'mongoose';

const boostSchema = new Schema(
  {
    messageId: { type: Schema.Types.ObjectId, ref: 'Message', required: true, index: true },
    boosterId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    content: { type: String, required: true, maxlength: 16 },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'boosts',
    timestamps: true
  }
);

boostSchema.index({ messageId: 1, boosterId: 1, content: 1 });

export const BoostModel = model('Boost', boostSchema);
