import { Schema, model, type InferSchemaType } from 'mongoose';

const userSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    emailAddress: { type: String, required: true, unique: true, lowercase: true, trim: true },
    passwordHash: { type: String, required: true },
    bio: { type: String, default: '' },
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
    botWebhookUrl: { type: String, trim: true, default: '' }
  },
  {
    timestamps: true,
    versionKey: false
  }
);

userSchema.index({ name: 1 });

export type UserDocument = InferSchemaType<typeof userSchema> & { _id: string };

export const UserModel = model('User', userSchema);
