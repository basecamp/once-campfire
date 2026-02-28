import { randomUUID } from 'node:crypto';
import { Schema, model, type InferSchemaType } from 'mongoose';

const attachmentSchema = new Schema(
  {
    data: { type: Buffer, required: true },
    contentType: { type: String, required: true, trim: true },
    filename: { type: String, required: true, trim: true },
    byteSize: { type: Number, required: true },
    width: { type: Number, required: false },
    height: { type: Number, required: false },
    previewable: { type: Boolean, required: false },
    variable: { type: Boolean, required: false }
  },
  { _id: false }
);

const messageSchema = new Schema(
  {
    roomId: { type: Schema.Types.ObjectId, ref: 'Room', required: true },
    creatorId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    clientMessageId: { type: String, required: true, default: () => randomUUID() },
    body: { type: String, default: '', trim: true },
    attachment: { type: attachmentSchema, required: false }
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
