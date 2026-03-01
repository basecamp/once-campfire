import { Schema, model } from 'mongoose';

const webhookSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    url: { type: String, default: null },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'webhooks',
    timestamps: true
  }
);

webhookSchema.index({ userId: 1 }, { unique: true });

export const WebhookModel = model('Webhook', webhookSchema);
