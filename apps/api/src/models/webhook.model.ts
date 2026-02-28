import { Schema, model, type InferSchemaType } from 'mongoose';

const webhookSchema = new Schema(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    url: { type: String, required: true, trim: true },
    secret: { type: String, trim: true, default: '' },
    active: { type: Boolean, default: true },
    events: {
      type: [String],
      enum: ['message.created', 'message.boosted'],
      default: ['message.created', 'message.boosted']
    },
    roomIds: { type: [Schema.Types.ObjectId], default: [] },
    lastSuccessAt: { type: Date },
    lastError: { type: String, default: '' }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

webhookSchema.index({ userId: 1, createdAt: -1 });

export type WebhookDocument = InferSchemaType<typeof webhookSchema> & { _id: string };

export const WebhookModel = model('Webhook', webhookSchema);
