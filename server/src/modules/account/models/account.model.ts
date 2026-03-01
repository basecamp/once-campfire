import { Schema, model } from 'mongoose';

const accountSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    joinCode: { type: String, required: true, trim: true, index: true },
    logoUrl: { type: String, default: null, trim: true },
    customStyles: { type: String, default: '' },
    settings: {
      restrictRoomCreationToAdministrators: { type: Boolean, default: false }
    },
    createdAt: { type: Date, default: Date.now, index: true },
    updatedAt: { type: Date, default: Date.now }
  },
  {
    collection: 'accounts',
    timestamps: true
  }
);

export const AccountModel = model('Account', accountSchema);
