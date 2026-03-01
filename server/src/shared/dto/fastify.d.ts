import 'fastify';
import type { FastifyReply, FastifyRequest } from 'fastify';

type SessionCompany =
  | string
  | {
      _id?: string;
      id?: string;
      [key: string]: unknown;
    };

type SessionUser =
  | {
      _id?: string;
      id?: string;
      role?: string;
      [key: string]: unknown;
    }
  | undefined;

declare module 'fastify' {
  interface FastifyInstance {
    authenticate: (request: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }

  interface FastifyRequest {
    accessToken?: string | null;
    authUserId?: string;
    authSessionId?: string;
    session?: {
      _id?: string;
      company?: SessionCompany;
      deviceId?: string;
      role?: string;
      user?: SessionUser;
      [key: string]: unknown;
    };
  }
}
