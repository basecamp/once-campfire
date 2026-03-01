export function serializeRoom(room: {
  _id: unknown;
  name?: string | null;
  type: string;
  createdAt: Date;
  updatedAt: Date;
}) {
  return {
    id: String(room._id),
    name: room.name ?? '',
    type: room.type,
    createdAt: room.createdAt,
    updatedAt: room.updatedAt
  };
}
