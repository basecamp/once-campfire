import { Schema, model, type InferSchemaType } from 'mongoose';
import { isPublicIpAddress, normalizeIpAddress } from '../services/ip-address.js';

const banSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    ipAddress: {
      type: String,
      required: true,
      trim: true,
      set: (value: unknown) => {
        if (typeof value !== 'string') {
          return value;
        }

        return normalizeIpAddress(value) ?? value.trim();
      },
      validate: {
        validator: (value: string) => isPublicIpAddress(value),
        message: 'ipAddress must be a valid public IP address'
      }
    }
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
