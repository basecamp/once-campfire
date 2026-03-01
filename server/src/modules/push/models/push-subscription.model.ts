import { Schema, model } from 'mongoose';

const pushSubscriptionSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    endpoint: { type: String, default: null },
    p256dhKey: { type: String, default: null },
    authKey: { type: String, default: null },
    userAgent: { type: String, default: null },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'push_subscriptions',
    timestamps: true
  }
);

pushSubscriptionSchema.index({ endpoint: 1, p256dhKey: 1, authKey: 1 }, { sparse: true });

export const PushSubscriptionModel = model('PushSubscription', pushSubscriptionSchema);
