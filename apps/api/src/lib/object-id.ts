import { Types } from 'mongoose';

export function asObjectId(id: string) {
  if (!Types.ObjectId.isValid(id)) {
    return null;
  }

  return new Types.ObjectId(id);
}
