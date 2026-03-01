import { Schema, model } from 'mongoose';

const membershipSchema = new Schema(
  {
    roomId: { type: Schema.Types.ObjectId, ref: 'Room', required: true, index: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    involvement: {
      type: String,
      enum: ['invisible', 'nothing', 'mentions', 'everything'],
      default: 'mentions',
      index: true
    },
    connectedAt: { type: Date, default: null },
    connections: { type: Number, default: 0 },
    unreadAt: { type: Date, default: null, index: true },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'memberships',
    timestamps: true
  }
);

membershipSchema.index({ roomId: 1, userId: 1 }, { unique: true });

export const MembershipModel = model('Membership', membershipSchema);
