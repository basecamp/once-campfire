type CloseContext = {
  reason: string;
  reconnect: boolean;
};

type ConnectionEntry = {
  id: string;
  roomId?: string;
  close: (context: CloseContext) => void;
};

const byUserId = new Map<string, Map<string, ConnectionEntry>>();

function nextId() {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

export function registerRealtimeConnection({
  userId,
  roomId,
  close
}: {
  userId: string;
  roomId?: string;
  close: (context: CloseContext) => void;
}) {
  const id = nextId();
  const existing = byUserId.get(userId) ?? new Map<string, ConnectionEntry>();

  existing.set(id, {
    id,
    roomId,
    close
  });
  byUserId.set(userId, existing);

  return () => {
    const current = byUserId.get(userId);
    if (!current) {
      return;
    }

    current.delete(id);
    if (current.size === 0) {
      byUserId.delete(userId);
    }
  };
}

export function disconnectUser(userId: string, context: CloseContext) {
  const connections = byUserId.get(userId);
  if (!connections || connections.size === 0) {
    return;
  }

  for (const connection of connections.values()) {
    connection.close(context);
  }
}

export function disconnectUserRoom(userId: string, roomId: string, context: CloseContext) {
  const connections = byUserId.get(userId);
  if (!connections || connections.size === 0) {
    return;
  }

  for (const connection of connections.values()) {
    if (connection.roomId === roomId) {
      connection.close(context);
    }
  }
}
