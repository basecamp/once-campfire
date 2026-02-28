import 'fastify';

declare module 'fastify' {
  interface FastifyRequest {
    authUserId?: string;
    authSessionId?: string;
  }

  interface FastifyInstance {
    authenticate: (request: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
}
