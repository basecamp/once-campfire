import 'fastify';

declare module 'fastify' {
  interface RequestPlatform {
    userAgent: string;
    appleMessages: boolean;
    ios: boolean;
    android: boolean;
    mac: boolean;
    chrome: boolean;
    firefox: boolean;
    safari: boolean;
    edge: boolean;
    mobile: boolean;
    desktop: boolean;
    windows: boolean;
    operatingSystem: string;
  }

  interface FastifyRequest {
    authUserId?: string;
    authSessionId?: string;
    platform?: RequestPlatform;
  }

  interface FastifyInstance {
    authenticate: (request: FastifyRequest, reply: FastifyReply) => Promise<void>;
    tryAuthenticate: (request: FastifyRequest) => Promise<{ userId: string; sessionId: string } | null>;
  }
}
