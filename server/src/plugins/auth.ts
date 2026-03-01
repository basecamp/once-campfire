import fp from 'fastify-plugin';
import type { FastifyPluginAsync } from 'fastify';

function normalizeUserId(value: unknown): string | null {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  }
  if (typeof value === 'number' || typeof value === 'bigint') {
    return String(value);
  }
  if (value && typeof value === 'object' && 'toString' in value && typeof value.toString === 'function') {
    const parsed = String(value.toString()).trim();
    if (parsed && parsed !== '[object Object]') {
      return parsed;
    }
  }
  return null;
}

type AuthHook = (request: unknown, reply: unknown) => Promise<void>;

const authPlugin: FastifyPluginAsync = async (app) => {
  let authHook: AuthHook | null = null;

  async function resolveAuthHook(): Promise<AuthHook> {
    if (!authHook) {
      const authJwtModule = await import('auth-jwt');
      authHook = authJwtModule.default();
    }
    return authHook;
  }

  app.decorate('authenticate', async (request, reply) => {
    const hook = await resolveAuthHook();
    await hook(request, reply);

    if (reply.sent) {
      return;
    }

    const userId = normalizeUserId(request.session?._id);
    if (!userId) {
      await reply.code(401).send({
        accessToken: request.accessToken ?? null,
        error: {
          code: 'UNAUTHORIZED',
          message: 'Unauthorized',
          details: null
        }
      });
      return;
    }

    request.authUserId = userId;
  });
};

export default fp(authPlugin, { name: 'auth' });
