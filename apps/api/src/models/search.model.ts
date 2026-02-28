import { Schema, model, type InferSchemaType } from 'mongoose';

const searchSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    query: { type: String, required: true, trim: true, maxlength: 200 }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

searchSchema.index({ userId: 1, createdAt: -1 });

export type SearchDocument = InferSchemaType<typeof searchSchema> & { _id: string };

export const SearchModel = model('Search', searchSchema);
