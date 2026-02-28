import { Schema, model, type InferSchemaType } from 'mongoose';

const pushSubscriptionSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    endpoint: { type: String, required: true, trim: true },
    p256dhKey: { type: String, required: true, trim: true },
    authKey: { type: String, required: true, trim: true },
    userAgent: { type: String, default: '' }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

pushSubscriptionSchema.index(
  {
    endpoint: 1,
    p256dhKey: 1,
    authKey: 1
  },
  { unique: true }
);
pushSubscriptionSchema.index({ userId: 1, createdAt: -1 });

export type PushSubscriptionDocument = InferSchemaType<typeof pushSubscriptionSchema> & { _id: string };

export const PushSubscriptionModel = model('PushSubscription', pushSubscriptionSchema);
