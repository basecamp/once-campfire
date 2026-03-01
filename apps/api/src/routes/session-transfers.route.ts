import type { FastifyPluginAsync, FastifyReply, FastifyRequest } from 'fastify';
import { isApiPath } from '../lib/request-format.js';
import { setAuthCookie } from '../plugins/auth.js';
import { UserModel } from '../models/user.model.js';
import { createSession } from '../services/session-auth.js';
import { verifyTransferId } from '../services/transfer-token.js';

function renderTransferPage(transferId: string) {
  const encoded = encodeURIComponent(transferId);

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Session transfer</title>
  </head>
  <body>
    <p>Signing you in...</p>
    <script>
      fetch('/session/transfers/${encoded}', { method: 'PATCH', credentials: 'include' })
        .then((response) => {
          if (response.ok) {
            window.location.replace('/');
            return;
          }
          document.body.textContent = 'Invalid transfer link.';
        })
        .catch(() => {
          document.body.textContent = 'Invalid transfer link.';
        });
    </script>
  </body>
</html>`;
}

const sessionTransfersRoutes: FastifyPluginAsync = async (app) => {
  app.get('/session/transfers/:id', async (request, reply) => {
    const apiRequest = isApiPath(request);
    const { id } = request.params as { id: string };

    if (!apiRequest) {
      reply.header('content-type', 'text/html; charset=utf-8');
      return reply.code(200).send(renderTransferPage(id));
    }

    const userId = verifyTransferId(app, id);

    if (!userId) {
      return reply.code(400).send({ valid: false });
    }

    const user = await UserModel.findOne({
      _id: userId,
      status: 'active'
    }).lean();

    if (!user) {
      return reply.code(400).send({ valid: false });
    }

    return { valid: true };
  });

  const updateTransfer = async (request: FastifyRequest, reply: FastifyReply) => {
    const apiRequest = isApiPath(request);
    const { id } = request.params as { id: string };
    const userId = verifyTransferId(app, id);

    if (!userId) {
      if (!apiRequest) {
        return reply.code(400).send();
      }
      return reply.code(400).send({ error: 'Invalid transfer id' });
    }

    const user = await UserModel.findOne({
      _id: userId,
      status: 'active'
    });

    if (!user) {
      if (!apiRequest) {
        return reply.code(400).send();
      }
      return reply.code(400).send({ error: 'Invalid transfer id' });
    }

    const session = await createSession({
      userId: String(user._id),
      userAgent: request.headers['user-agent'] ?? '',
      ipAddress: request.ip
    });

    setAuthCookie(reply, session.token);

    if (!apiRequest) {
      return reply.redirect('/');
    }

    return { ok: true };
  };

  app.patch('/session/transfers/:id', updateTransfer);
  app.put('/session/transfers/:id', updateTransfer);
};

export default sessionTransfersRoutes;
