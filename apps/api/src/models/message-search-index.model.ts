import { Schema, model, type InferSchemaType } from 'mongoose';

const messageSearchIndexSchema = new Schema(
  {
    messageId: { type: Schema.Types.ObjectId, ref: 'Message', required: true, unique: true },
    roomId: { type: Schema.Types.ObjectId, ref: 'Room', required: true },
    body: { type: String, required: true, default: '' }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

messageSearchIndexSchema.index({ roomId: 1, updatedAt: -1 });
messageSearchIndexSchema.index({ body: 'text' });

export type MessageSearchIndexDocument = InferSchemaType<typeof messageSearchIndexSchema> & { _id: string };

export const MessageSearchIndexModel = model('MessageSearchIndex', messageSearchIndexSchema);
