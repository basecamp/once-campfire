import { Schema, model, type InferSchemaType } from 'mongoose';

const boostSchema = new Schema(
  {
    messageId: { type: Schema.Types.ObjectId, ref: 'Message', required: true },
    boosterId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    content: { type: String, required: true, trim: true, maxlength: 16 }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

boostSchema.index({ messageId: 1, boosterId: 1, content: 1 }, { unique: true });
boostSchema.index({ messageId: 1, createdAt: -1 });

export type BoostDocument = InferSchemaType<typeof boostSchema> & { _id: string };

export const BoostModel = model('Boost', boostSchema);
