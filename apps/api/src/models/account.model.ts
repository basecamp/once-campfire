import { Schema, model, type InferSchemaType } from 'mongoose';

const logoSchema = new Schema(
  {
    data: { type: Buffer, required: true },
    contentType: { type: String, required: true, trim: true },
    filename: { type: String, required: true, trim: true },
    byteSize: { type: Number, required: true }
  },
  { _id: false }
);

const accountSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    joinCode: { type: String, required: true, unique: true, trim: true },
    customStyles: { type: String, default: '' },
    logoUrl: { type: String, default: '', trim: true },
    logo: { type: logoSchema, required: false },
    settings: {
      restrictRoomCreationToAdministrators: { type: Boolean, default: false }
    },
    singletonGuard: { type: Number, default: 0, unique: true }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

accountSchema.index({ singletonGuard: 1 }, { unique: true });

export type AccountDocument = InferSchemaType<typeof accountSchema> & { _id: string };

export const AccountModel = model('Account', accountSchema);
