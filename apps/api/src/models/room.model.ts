import { Schema, model, type InferSchemaType } from 'mongoose';

const roomSchema = new Schema(
  {
    name: { type: String, trim: true },
    type: {
      type: String,
      enum: ['open', 'closed', 'direct'],
      required: true,
      default: 'open'
    },
    creatorId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    directKey: { type: String, trim: true }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

roomSchema.index({ type: 1, name: 1 });
roomSchema.index({ type: 1, directKey: 1 }, { unique: true, sparse: true });

export type RoomDocument = InferSchemaType<typeof roomSchema> & { _id: string };

export const RoomModel = model('Room', roomSchema);
