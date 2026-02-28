import { randomBytes } from 'node:crypto';
import { AccountModel } from '../models/account.model.js';

const DEFAULT_ACCOUNT_NAME = 'Campfire';

export function generateJoinCode() {
  const raw = randomBytes(6).toString('base64url').replace(/[^a-zA-Z0-9]/g, '').slice(0, 12);
  const padded = raw.padEnd(12, '0');
  return padded.match(/.{1,4}/g)?.join('-') ?? padded;
}

export async function getAccount() {
  return AccountModel.findOne().sort({ createdAt: 1 });
}

export async function getOrCreateAccount() {
  const existing = await getAccount();
  if (existing) {
    return existing;
  }

  try {
    return await AccountModel.create({
      name: DEFAULT_ACCOUNT_NAME,
      joinCode: generateJoinCode(),
      customStyles: '',
      settings: {
        restrictRoomCreationToAdministrators: false
      },
      singletonGuard: 0
    });
  } catch {
    const raceWinner = await getAccount();
    if (!raceWinner) {
      throw new Error('Unable to initialize account singleton');
    }
    return raceWinner;
  }
}
