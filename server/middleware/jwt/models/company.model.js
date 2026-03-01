import mongoose from 'mongoose';
import { identConnection } from '../config/mongodb.js';

const companySchema = new mongoose.Schema({
  name: { type: String, unique: [true, "ident.unique.company"], required: true },
  currency: { type: String },
  address: {
    country: { type: String },
    state: { type: String },
    city: { type: String },
    index: { type: String },
    street: { type: String },
    house: { type: String },
    housing: { type: String },
    apartment: { type: String },
    pos: {
      lat: { type: Number },
      lng: { type: Number }
    }
  },
});

const Company = identConnection.model('Company', companySchema);

export default Company;
