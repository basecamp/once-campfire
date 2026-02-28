import type { FastifyPluginAsync } from 'fastify';
import QRCode from 'qrcode';

const qrCodeRoutes: FastifyPluginAsync = async (app) => {
  app.get('/qr_code/:id', async (request, reply) => {
    const { id } = request.params as { id: string };

    let decoded: string;
    try {
      decoded = Buffer.from(id, 'base64url').toString('utf8');
    } catch {
      return reply.code(400).send({ error: 'Invalid QR payload' });
    }

    if (!decoded) {
      return reply.code(400).send({ error: 'Invalid QR payload' });
    }

    const svg = await QRCode.toString(decoded, {
      type: 'svg',
      color: {
        dark: '#000000',
        light: '#FFFFFF'
      }
    });

    reply.header('content-type', 'image/svg+xml');
    reply.header('cache-control', 'public, max-age=31536000');
    return reply.send(svg);
  });
};

export default qrCodeRoutes;
