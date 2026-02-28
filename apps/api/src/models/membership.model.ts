import { Schema, model, type InferSchemaType } from 'mongoose';

const membershipSchema = new Schema(
  {
    roomId: { type: Schema.Types.ObjectId, ref: 'Room', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    involvement: {
      type: String,
      enum: ['invisible', 'nothing', 'mentions', 'everything'],
      default: 'mentions'
    },
    connections: { type: Number, default: 0 },
    connectedAt: { type: Date },
    unreadAt: { type: Date }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

membershipSchema.index({ roomId: 1, userId: 1 }, { unique: true });
membershipSchema.index({ userId: 1, createdAt: -1 });

export type MembershipDocument = InferSchemaType<typeof membershipSchema> & { _id: string };

export const MembershipModel = model('Membership', membershipSchema);
