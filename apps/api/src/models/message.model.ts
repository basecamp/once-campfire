import { randomUUID } from 'node:crypto';
import { Schema, model, type InferSchemaType } from 'mongoose';

const messageSchema = new Schema(
  {
    roomId: { type: Schema.Types.ObjectId, ref: 'Room', required: true },
    creatorId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    clientMessageId: { type: String, required: true, default: () => randomUUID() },
    body: { type: String, required: true, trim: true }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

messageSchema.index({ roomId: 1, createdAt: -1 });
messageSchema.index({ body: 'text' });

export type MessageDocument = InferSchemaType<typeof messageSchema> & { _id: string };

export const MessageModel = model('Message', messageSchema);
