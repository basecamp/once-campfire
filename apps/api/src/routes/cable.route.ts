import type { FastifyPluginAsync } from 'fastify';
import { MembershipModel } from '../models/membership.model.js';
import { UserModel } from '../models/user.model.js';
import { registerRealtimeConnection } from '../realtime/connection-manager.js';
import { realtimeBus, type RealtimeEvent } from '../realtime/event-bus.js';
import { publishRealtimeEvent } from '../realtime/redis-realtime.js';
import { absentMembership, presentMembership, refreshMembership } from '../services/membership-connection.js';
import {
  extractRoomIdFromTurboStreamName,
  resolveTurboStreamName,
  turboStreamMessageForEvent
} from '../services/turbo-stream.js';

type CableIdentifier = {
  channel: string;
  roomId?: string;
  streamName?: string;
  signedStreamName?: string;
};

type CableSubscription = {
  channel: string;
  roomId?: string;
  streamName?: string;
  unsubscribe?: () => void;
  onMessage?: (payload: Record<string, unknown>) => Promise<void>;
  onClose?: () => Promise<void>;
};

const PING_INTERVAL_MS = 3000;

function safeJsonParse<T>(input: string) {
  try {
    return JSON.parse(input) as T;
  } catch {
    return null;
  }
}

function readIdentifier(identifierRaw: string) {
  const payload = safeJsonParse<Record<string, unknown>>(identifierRaw);
  if (!payload || typeof payload.channel !== 'string') {
    return null;
  }

  return {
    channel: payload.channel,
    roomId:
      (typeof payload.room_id === 'string' ? payload.room_id : undefined) ??
      (typeof payload.roomId === 'string' ? payload.roomId : undefined),
    streamName:
      (typeof payload.stream_name === 'string' ? payload.stream_name : undefined) ??
      (typeof payload.streamName === 'string' ? payload.streamName : undefined),
    signedStreamName:
      (typeof payload.signed_stream_name === 'string' ? payload.signed_stream_name : undefined) ??
      (typeof payload.signedStreamName === 'string' ? payload.signedStreamName : undefined)
  } satisfies CableIdentifier;
}

function sendFrame(socket: { readyState: number; send: (payload: string) => void }, payload: Record<string, unknown>) {
  if (socket.readyState !== 1) {
    return;
  }

  socket.send(JSON.stringify(payload));
}

function broadcastPayloadForEvent(event: RealtimeEvent, channel: string, userId: string, roomId?: string) {
  if (channel === 'UnreadRoomsChannel') {
    if (event.type !== 'room.unread') {
      return null;
    }

    if (event.userIds && !event.userIds.includes(userId)) {
      return null;
    }

    const payloadRoomId = (event.payload.roomId as string | undefined) ?? (event.payload.room_id as string | undefined) ?? event.roomId;
    return { roomId: payloadRoomId };
  }

  if (channel === 'ReadRoomsChannel') {
    if (event.type !== 'room.read') {
      return null;
    }

    if (event.userIds && !event.userIds.includes(userId)) {
      return null;
    }

    const payloadRoomId = (event.payload.room_id as string | undefined) ?? (event.payload.roomId as string | undefined) ?? event.roomId;
    return { room_id: payloadRoomId };
  }

  if (channel === 'TypingNotificationsChannel') {
    if (event.type !== 'typing.start' && event.type !== 'typing.stop') {
      return null;
    }

    if (!roomId || event.roomId !== roomId) {
      return null;
    }

    return event.payload;
  }

  return null;
}

const cableRoutes: FastifyPluginAsync = async (app) => {
  app.get('/cable', { websocket: true }, (connection, request) => {
    void (async () => {
      const auth = await app.tryAuthenticate(request);
      if (!auth) {
        connection.socket.close(1008, 'Unauthorized');
        return;
      }

      const userId = auth.userId;
      const subscriptions = new Map<string, CableSubscription>();
      const user = await UserModel.findById(userId, { name: 1 }).lean();
      const userName = user?.name ?? 'Unknown';

      sendFrame(connection.socket, { type: 'welcome' });

      const pingTimer = setInterval(() => {
        sendFrame(connection.socket, { type: 'ping', message: Math.floor(Date.now() / 1000) });
      }, PING_INTERVAL_MS);

      const unregisterConnection = registerRealtimeConnection({
        userId,
        close: ({ reason, reconnect }) => {
          sendFrame(connection.socket, {
            type: 'disconnect',
            reason,
            reconnect
          });
          connection.socket.close(1000, reason);
        }
      });

      let closed = false;

      const cleanupSubscription = async (identifierRaw: string) => {
        const subscription = subscriptions.get(identifierRaw);
        if (!subscription) {
          return;
        }

        subscriptions.delete(identifierRaw);
        subscription.unsubscribe?.();
        if (subscription.onClose) {
          await subscription.onClose();
        }
      };

      const cleanup = async () => {
        if (closed) {
          return;
        }

        closed = true;
        clearInterval(pingTimer);
        unregisterConnection();

        const active = Array.from(subscriptions.keys());
        for (const identifierRaw of active) {
          await cleanupSubscription(identifierRaw);
        }
      };

      const rejectSubscription = (identifierRaw: string) => {
        sendFrame(connection.socket, {
          identifier: identifierRaw,
          type: 'reject_subscription'
        });
      };

      const confirmSubscription = (identifierRaw: string) => {
        sendFrame(connection.socket, {
          identifier: identifierRaw,
          type: 'confirm_subscription'
        });
      };

      connection.socket.on('message', async (rawMessage: Buffer | string) => {
        const text = typeof rawMessage === 'string' ? rawMessage : rawMessage.toString('utf-8');
        const frame = safeJsonParse<{
          command?: string;
          identifier?: string;
          data?: string | Record<string, unknown>;
        }>(text);

        if (!frame || typeof frame.command !== 'string' || typeof frame.identifier !== 'string') {
          return;
        }

        if (frame.command === 'unsubscribe') {
          await cleanupSubscription(frame.identifier);
          return;
        }

        if (frame.command === 'subscribe') {
          await cleanupSubscription(frame.identifier);

          const identifier = readIdentifier(frame.identifier);
          if (!identifier) {
            rejectSubscription(frame.identifier);
            return;
          }

          let subscription: CableSubscription | null = null;

          if (identifier.channel === 'HeartbeatChannel') {
            subscription = { channel: identifier.channel };
          } else if (identifier.channel === 'UnreadRoomsChannel' || identifier.channel === 'ReadRoomsChannel') {
            const listener = (event: RealtimeEvent) => {
              const payload = broadcastPayloadForEvent(event, identifier.channel, userId, identifier.roomId);
              if (!payload) {
                return;
              }

              sendFrame(connection.socket, {
                identifier: frame.identifier,
                message: payload
              });
            };

            const unsubscribe = realtimeBus.subscribe(listener);
            subscription = {
              channel: identifier.channel,
              unsubscribe
            };
          } else if (identifier.channel === 'PresenceChannel') {
            if (!identifier.roomId) {
              rejectSubscription(frame.identifier);
              return;
            }

            const membership = await presentMembership(identifier.roomId, userId);
            if (!membership) {
              rejectSubscription(frame.identifier);
              return;
            }

            await publishRealtimeEvent({
              type: 'room.read',
              roomId: identifier.roomId,
              payload: { room_id: identifier.roomId },
              userIds: [userId]
            });

            subscription = {
              channel: identifier.channel,
              roomId: identifier.roomId,
              onMessage: async (payload) => {
                const action = typeof payload.action === 'string' ? payload.action : '';
                if (action === 'present') {
                  const current = await presentMembership(identifier.roomId!, userId);
                  if (!current) {
                    return;
                  }

                  await publishRealtimeEvent({
                    type: 'room.read',
                    roomId: identifier.roomId!,
                    payload: { room_id: identifier.roomId! },
                    userIds: [userId]
                  });
                  return;
                }

                if (action === 'absent') {
                  await absentMembership(identifier.roomId!, userId);
                  return;
                }

                if (action === 'refresh') {
                  await refreshMembership(identifier.roomId!, userId);
                }
              },
              onClose: async () => {
                await absentMembership(identifier.roomId!, userId);
              }
            };
          } else if (identifier.channel === 'TypingNotificationsChannel') {
            if (!identifier.roomId) {
              rejectSubscription(frame.identifier);
              return;
            }

            const membership = await MembershipModel.findOne({ roomId: identifier.roomId, userId }).lean();
            if (!membership) {
              rejectSubscription(frame.identifier);
              return;
            }

            const listener = (event: RealtimeEvent) => {
              const payload = broadcastPayloadForEvent(event, identifier.channel, userId, identifier.roomId);
              if (!payload) {
                return;
              }

              sendFrame(connection.socket, {
                identifier: frame.identifier,
                message: payload
              });
            };

            const unsubscribe = realtimeBus.subscribe(listener);
            subscription = {
              channel: identifier.channel,
              roomId: identifier.roomId,
              unsubscribe,
              onMessage: async (payload) => {
                const action = typeof payload.action === 'string' ? payload.action : '';
                if (action !== 'start' && action !== 'stop') {
                  return;
                }

                await publishRealtimeEvent({
                  type: action === 'start' ? 'typing.start' : 'typing.stop',
                  roomId: identifier.roomId!,
                  payload: {
                    action,
                    user: {
                      id: userId,
                      name: userName
                    }
                  }
                });
              }
            };
          } else if (identifier.channel === 'Turbo::StreamsChannel') {
            const streamName = resolveTurboStreamName(identifier.signedStreamName, identifier.streamName);
            if (!streamName) {
              rejectSubscription(frame.identifier);
              return;
            }

            const roomIdFromStream = extractRoomIdFromTurboStreamName(streamName);
            if (roomIdFromStream && streamName.includes('messages')) {
              const membership = await MembershipModel.findOne({ roomId: roomIdFromStream, userId }).lean();
              if (!membership) {
                rejectSubscription(frame.identifier);
                return;
              }
            }

            const listener = (event: RealtimeEvent) => {
              const message = turboStreamMessageForEvent(event, streamName, userId);
              if (!message) {
                return;
              }

              sendFrame(connection.socket, {
                identifier: frame.identifier,
                message
              });
            };

            const unsubscribe = realtimeBus.subscribe(listener);
            subscription = {
              channel: identifier.channel,
              roomId: roomIdFromStream ?? undefined,
              streamName,
              unsubscribe
            };
          }

          if (!subscription) {
            rejectSubscription(frame.identifier);
            return;
          }

          subscriptions.set(frame.identifier, subscription);
          confirmSubscription(frame.identifier);
          return;
        }

        if (frame.command === 'message') {
          const subscription = subscriptions.get(frame.identifier);
          if (!subscription?.onMessage) {
            return;
          }

          const parsedPayload =
            typeof frame.data === 'string'
              ? safeJsonParse<Record<string, unknown>>(frame.data)
              : frame.data && typeof frame.data === 'object'
                ? frame.data
                : null;

          if (!parsedPayload) {
            return;
          }

          await subscription.onMessage(parsedPayload);
        }
      });

      connection.socket.on('close', () => {
        void cleanup();
      });

      connection.socket.on('error', () => {
        void cleanup();
      });
    })();
  });
};

export default cableRoutes;
