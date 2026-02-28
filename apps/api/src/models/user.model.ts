import { Schema, model, type InferSchemaType } from 'mongoose';

const avatarSchema = new Schema(
  {
    data: { type: Buffer, required: true },
    contentType: { type: String, required: true, trim: true },
    filename: { type: String, required: true, trim: true },
    byteSize: { type: Number, required: true }
  },
  { _id: false }
);

const userSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    emailAddress: { type: String, required: true, unique: true, lowercase: true, trim: true },
    passwordHash: { type: String, required: true },
    bio: { type: String, default: '' },
    avatarUrl: { type: String, default: '', trim: true },
    avatar: { type: avatarSchema, required: false },
    role: {
      type: String,
      enum: ['member', 'admin', 'bot'],
      default: 'member'
    },
    status: {
      type: String,
      enum: ['active', 'deactivated', 'banned'],
      default: 'active'
    },
    botToken: { type: String, unique: true, sparse: true },
    botWebhookUrl: { type: String, trim: true, default: '' },
    transferToken: { type: String, trim: true, default: '' },
    transferExpiresAt: { type: Date }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

userSchema.index({ name: 1 });

export type UserDocument = InferSchemaType<typeof userSchema> & { _id: string };

export const UserModel = model('User', userSchema);
