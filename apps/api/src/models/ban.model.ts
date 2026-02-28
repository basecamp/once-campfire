import { Schema, model, type InferSchemaType } from 'mongoose';

const banSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    ipAddress: { type: String, required: true, trim: true }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

banSchema.index({ userId: 1, ipAddress: 1 }, { unique: true });
banSchema.index({ ipAddress: 1 });

export type BanDocument = InferSchemaType<typeof banSchema> & { _id: string };

export const BanModel = model('Ban', banSchema);
