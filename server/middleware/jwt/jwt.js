import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import jwt from 'jsonwebtoken';
import { v4 as uuidv4 } from 'uuid';
import redis from './redis-client.js';

// Модели
import RefreshToken from './models/refreshToken.model.js';
import User from './models/user.model.js';
import Currencies from './models/currency.model.js';
import Company from './models/company.model.js';

// ----- Конфигурация -----
const config = {
  jwt: {
    expiresIn: process.env.TOKEN_EXPIRATION_MINUTES || '15',
    privateKeyPath: './keys/private.key',
    publicKeyPath: './keys/public.key',
  },
  redis: {
    lockTtlMs: 5000,
    resultTtlS: 10,
    pollingIntervalMs: 200,
    pollingAttempts: 25,
    channelPrefix: 'refresh:done:',
  },
  headers: {
    deviceId: 'x-device-id',
    authToken: 'x-authentication-token',
  },
  cookies: {
    refreshTokenName: 'refreshToken',
  },
  refreshTokenLifetimeDays: 60,
  deviceIdMaxLength: 128,
};

// ----- Ключи подписи / верификации -----
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const privateKey = fs.readFileSync(
  path.resolve(__dirname, config.jwt.privateKeyPath),
  'utf8',
);
const publicKey = fs.readFileSync(
  path.resolve(__dirname, config.jwt.publicKeyPath),
  'utf8',
);

// ----- Классы ошибок -----
class TokenRefreshFailedError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TokenRefreshFailedError';
  }
}
class TokenRefreshTimeoutError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TokenRefreshTimeoutError';
  }
}

// ----- Утилиты -----

/**
 * Валидация deviceId — только допустимые символы, ограничение длины.
 */
function isValidDeviceId(deviceId) {
  if (!deviceId || typeof deviceId !== 'string') return false;
  if (deviceId.length > config.deviceIdMaxLength) return false;
  // Допускаем буквы, цифры, дефисы, подчёркивания, точки
  return /^[a-zA-Z0-9\-_.]+$/.test(deviceId);
}

/**
 * Получает чистый hostname из запроса.
 */
function getHostnameFromRequest(request) {
  const hostHdr = request?.headers?.['x-forwarded-host'] || request?.headers?.host;
  if (hostHdr) return hostHdr.split(':')[0].toLowerCase();

  if (request?.hostname) return String(request.hostname).toLowerCase();
  return '';
}

/**
 * Конфигурация куки с учётом хоста/протокола.
 * - localhost/http: secure=false, sameSite=Lax
 * - https-домены: secure=true, sameSite=None (host-only)
 */
function computeCookieOptions(request, expiresTime) {
  const base = { httpOnly: true, path: '/', expires: expiresTime };
  const host = (request?.headers?.host || '').toLowerCase();
  const proto = (request?.headers?.['x-forwarded-proto'] || '').toLowerCase();
  const isLocal = host.includes('localhost') || host.includes('127.0.0.1') || proto === 'http';

  if (isLocal) {
    return { ...base, secure: false, sameSite: 'Lax' };
  }

  return { ...base, secure: true, sameSite: 'None' };
}

/**
 * Безопасный JSON.parse с обработкой ошибок.
 */
function safeJsonParse(data) {
  try {
    return JSON.parse(data);
  } catch {
    return null;
  }
}

// ----- Проверка доступности Redis -----
let redisAvailable = true;

redis.on('error', () => {
  redisAvailable = false;
});

redis.on('ready', () => {
  redisAvailable = true;
});

redis.on('connect', () => {
  redisAvailable = true;
});

// ----- Генерация access-токена -----
function generateAccessToken(payload) {
  return jwt.sign(payload, privateKey, {
    expiresIn: `${config.jwt.expiresIn}m`,
    algorithm: 'RS256',
  });
}

// ----- Cookie helpers -----
function setRefreshTokenCookie(request, reply, token) {
  const expiresTime = new Date(
    Date.now() + 1000 * 60 * 60 * 24 * config.refreshTokenLifetimeDays,
  );

  const cookieOpts = computeCookieOptions(request, expiresTime);
  reply.setCookie(config.cookies.refreshTokenName, token, cookieOpts);
}

function clearRefreshTokenCookie(request, reply) {
  reply.setCookie(config.cookies.refreshTokenName, '', {
    path: '/',
    expires: new Date(0),
    httpOnly: true,
    secure: true,
    sameSite: 'None'
  });
}

// ----- Применение результата refresh -----
function applyRefreshResult(request, reply, refreshResult) {
  const { userId, token: newRefreshToken } = refreshResult;
  const newAccessToken = generateAccessToken(userId);
  request.accessToken = newAccessToken;
  request.session = {
    _id: userId._id,
    company: userId.company?._id,
    deviceId: request.headers[config.headers.deviceId],
  };
  setRefreshTokenCookie(request, reply, newRefreshToken);
  reply.header(config.headers.authToken, newAccessToken);
}

// ----- Lua-скрипт для атомарного удаления лока (только если он наш) -----
const RELEASE_LOCK_SCRIPT = `
  if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
  else
    return 0
  end
`;

// ----- Ожидание результата refresh через pub/sub + polling fallback -----
async function waitForRefreshResult(resultKey, channel) {
  // Сначала проверяем, есть ли уже результат
  const existingResult = await redis.get(resultKey);
  if (existingResult) {
    const parsed = safeJsonParse(existingResult);
    if (!parsed) {
      throw new TokenRefreshFailedError('Corrupted refresh result data');
    }
    if (parsed.error) {
      throw new TokenRefreshFailedError(
        `Another process failed to refresh token: ${parsed.message}`,
      );
    }
    return parsed;
  }

  // Используем pub/sub + polling для ожидания результата
  return new Promise((resolve, reject) => {
    let settled = false;
    let pollTimer;
    let timeoutTimer;
    const subscriber = redis.duplicate();

    const cleanup = () => {
      if (settled) return;
      settled = true;
      clearInterval(pollTimer);
      clearTimeout(timeoutTimer);
      subscriber.unsubscribe(channel).catch(() => {});
      subscriber.disconnect();
    };

    // Pub/sub — мгновенное получение результата
    subscriber.subscribe(channel).then(() => {
      subscriber.on('message', (_ch, message) => {
        if (settled) return;
        const result = safeJsonParse(message);
        if (!result) {
          cleanup();
          return reject(new TokenRefreshFailedError('Corrupted refresh result data'));
        }
        cleanup();
        if (result.error) {
          return reject(
            new TokenRefreshFailedError(`Another process failed: ${result.message}`),
          );
        }
        return resolve(result);
      });
    }).catch(() => {
      // Если pub/sub недоступен — полагаемся на polling
    });

    // Polling fallback — на случай если pub/sub не сработал
    let attempts = 0;
    pollTimer = setInterval(async () => {
      if (settled) return;
      attempts++;
      try {
        const resultData = await redis.get(resultKey);
        if (resultData) {
          const result = safeJsonParse(resultData);
          if (!result) {
            cleanup();
            return reject(new TokenRefreshFailedError('Corrupted refresh result data'));
          }
          cleanup();
          if (result.error) {
            return reject(
              new TokenRefreshFailedError(`Another process failed: ${result.message}`),
            );
          }
          return resolve(result);
        }
      } catch {
        // Redis read error — continue polling
      }

      if (attempts >= config.redis.pollingAttempts) {
        cleanup();
        reject(new TokenRefreshTimeoutError('Timed out waiting for token refresh result.'));
      }
    }, config.redis.pollingIntervalMs);

    // Абсолютный таймаут
    timeoutTimer = setTimeout(() => {
      cleanup();
      reject(new TokenRefreshTimeoutError('Timed out waiting for token refresh result.'));
    }, config.redis.lockTtlMs + 1000);
  });
}

// ----- Ротация refresh-токена -----
const findRefreshTokenAndUpdated = async (refreshToken, deviceId) => {
  const currentDate = new Date();

  const oldTokenDoc = await RefreshToken.findOneAndDelete({
    token: refreshToken,
    deviceId,
    expired_at: { $gte: currentDate },
  }).populate({
    path: 'userId',
    select: '_id',
    model: User,
    populate: {
      path: 'company',
      select: 'currency',
      model: Company,
      populate: { path: 'currency', select: 'code', model: Currencies },
    },
  });

  if (!oldTokenDoc) {
    return null;
  }
  if (!oldTokenDoc.userId) {
    return null;
  }

  const expiredDate = new Date(
    currentDate.getTime() + 1000 * 60 * 60 * 24 * config.refreshTokenLifetimeDays,
  );

  const newRefreshToken = new RefreshToken({
    token: uuidv4(),
    userId: oldTokenDoc.userId._id,
    deviceId,
    expired_at: expiredDate,
  });
  await newRefreshToken.save();

  return { userId: oldTokenDoc.userId.toObject(), token: newRefreshToken.token };
};

// ----- Основной refresh-процесс с распределённым локом -----
const RefreshTokenUpdate = async (request, reply) => {
  const { headers, cookies } = request;
  const oldRefreshToken = cookies[config.cookies.refreshTokenName];
  const deviceId = headers[config.headers.deviceId];

  // Если Redis недоступен — выполняем refresh напрямую (без лока)
  if (!redisAvailable) {
    const result = await findRefreshTokenAndUpdated(oldRefreshToken, deviceId);
    if (!result) {
      throw new TokenRefreshFailedError(
        'Refresh token not found, expired, or already used',
      );
    }
    applyRefreshResult(request, reply, result);
    return;
  }

  const lockKey = `lock:refresh:${oldRefreshToken}`;
  const resultKey = `result:refresh:${oldRefreshToken}`;
  const channel = `${config.redis.channelPrefix}${oldRefreshToken}`;

  // Уникальный идентификатор владельца лока — защита от удаления чужого лока
  const lockOwner = `${process.pid}:${Date.now()}:${Math.random().toString(36).slice(2)}`;

  let lockAcquired;
  try {
    lockAcquired = await redis.set(
      lockKey,
      lockOwner,
      'PX',
      config.redis.lockTtlMs,
      'NX',
    );
  } catch {
    // Redis ошибка при попытке взять лок — выполняем без лока
    const result = await findRefreshTokenAndUpdated(oldRefreshToken, deviceId);
    if (!result) {
      throw new TokenRefreshFailedError(
        'Refresh token not found, expired, or already used',
      );
    }
    applyRefreshResult(request, reply, result);
    return;
  }

  if (lockAcquired) {
    try {
      const result = await findRefreshTokenAndUpdated(oldRefreshToken, deviceId);
      if (!result) {
        throw new TokenRefreshFailedError(
          'Refresh token not found, expired, or already used',
        );
      }

      const resultJson = JSON.stringify(result);

      // Сохраняем результат и публикуем для ожидающих процессов
      await Promise.all([
        redis.set(resultKey, resultJson, 'EX', config.redis.resultTtlS),
        redis.publish(channel, resultJson),
      ]);

      applyRefreshResult(request, reply, result);
    } catch (error) {
      const errorJson = JSON.stringify({ error: true, message: error.message });
      try {
        await Promise.all([
          redis.set(resultKey, errorJson, 'EX', config.redis.resultTtlS),
          redis.publish(channel, errorJson),
        ]);
      } catch {
        // Ignore Redis errors during error reporting
      }
      throw error;
    } finally {
      // Атомарное удаление лока — только если мы его владелец
      try {
        await redis.eval(RELEASE_LOCK_SCRIPT, 1, lockKey, lockOwner);
      } catch {
        // Ignore Redis errors during lock release
      }
    }
  } else {
    // Ожидаем результат от другого процесса через pub/sub + polling
    const result = await waitForRefreshResult(resultKey, channel);
    applyRefreshResult(request, reply, result);
  }
};

// ----- Вспомогательные обработчики -----
function handleServerError(reply, error) {
  console.error('Unhandled Authentication Error:', error?.message);
  return reply
    .status(500)
    .send({ success: false, code: 500, msg: 'Internal Server Error' });
}

function handleAuthFailure(request, reply) {
  clearRefreshTokenCookie(request, reply);
  return reply
    .status(401)
    .send({ success: false, code: 401, msg: 'Invalid or expired session. Please login again.' });
}

// ----- Экспортируемый хук Fastify -----
export default () => {
  const authHook = async (request, reply) => {
    const performTokenRefresh = async () => {
      try {
        await RefreshTokenUpdate(request, reply);
        return;
      } catch (error) {
        if (
          error instanceof TokenRefreshFailedError ||
          error instanceof TokenRefreshTimeoutError
        ) {
          return handleAuthFailure(request, reply);
        }
        return handleServerError(reply, error);
      }
    };

    const { headers, cookies } = request;
    const refreshToken = cookies[config.cookies.refreshTokenName];
    const deviceId = headers[config.headers.deviceId];

    if (!deviceId || !refreshToken) {
      return handleAuthFailure(request, reply);
    }

    // Валидация deviceId
    if (!isValidDeviceId(deviceId)) {
      return handleAuthFailure(request, reply);
    }

    const accessToken = headers[config.headers.authToken];
    if (accessToken) {
      try {
        // Используем публичный ключ для верификации (не приватный)
        const payloadFromToken = jwt.verify(accessToken, publicKey, {
          algorithms: ['RS256'],
        });
        const payload = payloadFromToken.payload
          ? payloadFromToken.payload
          : payloadFromToken;

        request.accessToken = accessToken;
        request.session = {
          _id: payload._id,
          company: payload.company?._id,
          deviceId,
        };
        return;
      } catch (error) {
        if (error.name === 'TokenExpiredError') {
          return performTokenRefresh();
        }
        return handleAuthFailure(request, reply);
      }
    } else {
      return performTokenRefresh();
    }
  };

  return authHook;
};
