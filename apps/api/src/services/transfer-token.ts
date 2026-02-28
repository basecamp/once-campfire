import type { FastifyInstance } from 'fastify';

const TRANSFER_TOKEN_PURPOSE = 'transfer';
const TRANSFER_TOKEN_EXPIRY_SECONDS = 4 * 60 * 60;

type TransferPayload = {
  sub: string;
  purpose: string;
};

export async function signTransferId(app: FastifyInstance, userId: string) {
  return app.jwt.sign(
    {
      sub: userId,
      purpose: TRANSFER_TOKEN_PURPOSE
    },
    {
      expiresIn: TRANSFER_TOKEN_EXPIRY_SECONDS
    }
  );
}

export function verifyTransferId(app: FastifyInstance, transferId: string) {
  try {
    const payload = app.jwt.verify<TransferPayload>(transferId);
    if (typeof payload === 'string' || payload.purpose !== TRANSFER_TOKEN_PURPOSE || !payload.sub) {
      return null;
    }

    return payload.sub;
  } catch {
    return null;
  }
}
