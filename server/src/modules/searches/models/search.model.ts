import { Schema, model } from 'mongoose';

const searchSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    query: { type: String, required: true },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'searches',
    timestamps: true
  }
);

searchSchema.index({ userId: 1, updatedAt: -1 });

export const SearchModel = model('Search', searchSchema);
