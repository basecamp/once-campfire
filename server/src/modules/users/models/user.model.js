import mongoose from 'mongoose';
import bcrypt from 'bcryptjs';
import mongoConnection from '../../../infra/storage/mongo-connection.js';

const UserSchema = new mongoose.Schema({
  email: {
    type: String,
    required: [true, "ident.required.email"],
    unique: [true, "ident.unique.email"],
    index: true,
    trim: true,
    sparse: true,
  },
  password: {
    type: String,
    required: [true, "ident.required.password"],
  },
  phone: {
    type: String,
    //required: [true, "ident.required.phone"],
    unique: [true, "ident.unique.phone"],
    index: true,
    trim: true,
    sparse: true,
  },
  telegram: {
    type: String,
  },
  fcm: {
    type: String,
    index: true,
  },
  notification: {
    email: { type: Boolean, default: false },
    telegram: { type: Boolean, default: false },
    phone: { type: Boolean, default: false },
    push: { type: Boolean, default: false },
  },
  roles: [{
    type: String,
    enum: ['member', 'administrator', 'bot'],
    default: 'member'
  }],
  active: { type: Boolean, default: true, index: true },
  status: {
    type: String,
    enum: ['active', 'banned', 'deactivated'],
    default: 'active',
    index: true
  },
  bio: {
    type: String,
    default: ''
  },
  name: {
    first: {
      type: String,
      required: [true, "required.first"],
    },
    last: { type: String },
  },

  avatarSource: {
    type: String,
    select: false, // Важно: не тянуть тяжелый исходник при каждом запросе пользователя
  },

  // Legacy field remains for backward compatibility with old payloads.
  avatar: {
    type: String,
  },

  botToken: {
    type: String,
    unique: true,
    sparse: true,
    index: true,
    trim: true
  },

  botWebhookUrl: {
    type: String,
    trim: true,
    default: null
  },

  transferId: {
    type: String,
    unique: true,
    sparse: true,
    index: true,
    trim: true
  },

  avatarSettings: {
    zoom: { type: Number, default: 1 },

    // Хранит СУММАРНЫЙ угол: (клики по 90 градусов + значение слайдера)
    // Например: 90, -180, 45, 135 и т.д.
    rotation: { type: Number, default: 0 },

    brightness: { type: Number, default: 0 },
    contrast: { type: Number, default: 0 },
    saturation: { type: Number, default: 0 },
    vignette: { type: Number, default: 0 },

    // Координаты сдвига (Pan Tool)
    panX: { type: Number, default: 0 },
    panY: { type: Number, default: 0 },
  },

  company: { type: mongoose.Schema.ObjectId, ref: "Company", index: true },
}, {
  timestamps: true
});

UserSchema.pre("save", function (next) {
  let user = this;
  if (!user.isModified("password")) return next();
  if (user.password) {
    let salt = bcrypt.genSaltSync(10);
    let hash = bcrypt.hashSync(user.password, salt);
    if (hash) {
      user.password = hash;
      next();
    }
  }
});

UserSchema.pre('validate', function (next) {
  if (this.status === 'active') {
    this.active = true;
  } else if (this.status) {
    this.active = false;
  } else if (this.active === true) {
    this.status = 'active';
  } else {
    this.status = 'deactivated';
  }
  next();
});

// Compatibility aliases for new server controllers and old payload formats.
UserSchema.virtual('emailAddress')
  .get(function getEmailAddress() {
    return this.email;
  })
  .set(function setEmailAddress(value) {
    this.email = value;
  });

UserSchema.virtual('avatarUrl')
  .get(function getAvatarUrl() {
    return this.avatarSource;
  })
  .set(function setAvatarUrl(value) {
    this.avatarSource = value;
  });

UserSchema.virtual('role')
  .get(function getRole() {
    if (Array.isArray(this.roles) && this.roles.length > 0) {
      return this.roles[0];
    }
    return 'member';
  })
  .set(function setRole(value) {
    if (!value || typeof value !== 'string') {
      return;
    }
    this.roles = [value];
  });

UserSchema.set('toJSON', { virtuals: true });
UserSchema.set('toObject', { virtuals: true });

UserSchema.index({ status: 1, roles: 1 });
UserSchema.index({ company: 1, status: 1, roles: 1 });
UserSchema.index({
  email: 'text',
  telegram: 'text',
  phone: 'text',
  'name.first': 'text',
  'name.last': 'text'
});

const User = mongoConnection.models.User || mongoConnection.model('User', UserSchema);

export default User
