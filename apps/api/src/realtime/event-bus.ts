import { EventEmitter } from 'node:events';

export type RealtimeEvent = {
  type:
    | 'room.created'
    | 'room.removed'
    | 'message.created'
    | 'message.updated'
    | 'message.boosted'
    | 'message.boost_removed'
    | 'message.removed'
    | 'room.unread'
    | 'room.read'
    | 'typing.start'
    | 'typing.stop';
  roomId: string;
  payload: Record<string, unknown>;
  userIds?: string[];
};

class RealtimeBus extends EventEmitter {
  publishLocal(event: RealtimeEvent) {
    this.emit('event', event);
  }

  subscribe(listener: (event: RealtimeEvent) => void) {
    this.on('event', listener);

    return () => {
      this.off('event', listener);
    };
  }
}

export const realtimeBus = new RealtimeBus();
realtimeBus.setMaxListeners(0);
