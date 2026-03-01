import { Schema, model } from 'mongoose';

const roomSchema = new Schema(
  {
    name: { type: String, default: null, trim: true },
    type: {
      type: String,
      enum: ['open', 'closed', 'direct'],
      required: true,
      index: true
    },
    creatorId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    directKey: { type: String, default: null },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'rooms',
    timestamps: true
  }
);

roomSchema.index({ directKey: 1 }, { unique: true, sparse: true });
roomSchema.index({ name: 1 });

export const RoomModel = model('Room', roomSchema);
