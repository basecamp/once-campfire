import fp from 'fastify-plugin';
import { BanModel } from '../models/ban.model.js';
import { isPublicIpAddress, normalizeIpAddress } from '../services/ip-address.js';

async function banGuardPlugin(app: import('fastify').FastifyInstance) {
  app.addHook('onRequest', async (request, reply) => {
    if (request.method === 'GET' || request.method === 'HEAD') {
      return;
    }

    const ipAddress = normalizeIpAddress(request.ip);
    if (!ipAddress || !isPublicIpAddress(ipAddress)) {
      return;
    }

    const banned = await BanModel.exists({ ipAddress });
    if (!banned) {
      return;
    }

    await reply.code(429).send({ error: 'Too Many Requests' });
  });
}

export default fp(banGuardPlugin, {
  name: 'ban-guard'
});
