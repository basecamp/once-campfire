import { Schema, model } from 'mongoose';

const messageSchema = new Schema(
  {
    roomId: { type: Schema.Types.ObjectId, ref: 'Room', required: true, index: true },
    creatorId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    clientMessageId: { type: String, required: true, index: true },
    bodyHtml: { type: String, default: '' },
    bodyPlain: { type: String, default: '' },
    attachment: {
      key: { type: String, default: null },
      filename: { type: String, default: null },
      contentType: { type: String, default: null },
      byteSize: { type: Number, default: null }
    },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'messages',
    timestamps: true
  }
);

messageSchema.index({ roomId: 1, createdAt: 1 });
messageSchema.index({ clientMessageId: 1 }, { unique: true });

export const MessageModel = model('Message', messageSchema);
