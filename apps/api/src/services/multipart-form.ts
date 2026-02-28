import type { FastifyRequest } from 'fastify';

export type BinaryUpload = {
  data: Buffer;
  contentType: string;
  filename: string;
  byteSize: number;
};

type MultipartReadOptions = {
  fileFields: string[];
};

function normalizeContentType(value: string | undefined) {
  return value?.split(';')[0]?.trim() || 'application/octet-stream';
}

function extensionForMimeType(contentType: string) {
  const normalized = normalizeContentType(contentType).toLowerCase();
  if (normalized === 'image/jpeg') {
    return 'jpg';
  }
  if (normalized === 'image/png') {
    return 'png';
  }
  if (normalized === 'image/gif') {
    return 'gif';
  }
  if (normalized === 'image/webp') {
    return 'webp';
  }
  if (normalized === 'image/svg+xml') {
    return 'svg';
  }
  return 'bin';
}

function binaryUploadFromBuffer(buffer: Buffer, contentType?: string, filename?: string): BinaryUpload {
  const normalizedContentType = normalizeContentType(contentType);
  const safeFilename =
    (filename?.trim() ? filename.trim() : `upload.${extensionForMimeType(normalizedContentType)}`).replace(/"/g, '');

  return {
    data: buffer,
    contentType: normalizedContentType,
    filename: safeFilename,
    byteSize: buffer.byteLength
  };
}

export function pickField(fields: Record<string, string>, names: string[]) {
  for (const name of names) {
    if (typeof fields[name] === 'string') {
      return fields[name];
    }
  }

  return undefined;
}

export function parseBooleanField(value: string | undefined) {
  if (value === undefined) {
    return undefined;
  }

  const normalized = value.trim().toLowerCase();
  if (normalized === '1' || normalized === 'true' || normalized === 'on' || normalized === 'yes') {
    return true;
  }
  if (normalized === '0' || normalized === 'false' || normalized === 'off' || normalized === 'no') {
    return false;
  }

  return undefined;
}

export function ensureImageUpload(upload: BinaryUpload | undefined) {
  if (!upload) {
    return upload;
  }

  if (!upload.contentType.toLowerCase().startsWith('image/')) {
    const error = new Error('Unsupported upload type');
    (error as Error & { statusCode?: number }).statusCode = 422;
    throw error;
  }

  return upload;
}

export async function readMultipartForm(
  request: FastifyRequest,
  options: MultipartReadOptions
): Promise<{ fields: Record<string, string>; files: Record<string, BinaryUpload> }> {
  if (!request.isMultipart()) {
    return { fields: {}, files: {} };
  }

  const fields: Record<string, string> = {};
  const files: Record<string, BinaryUpload> = {};
  const allowedFileFields = new Set(options.fileFields);

  for await (const part of request.parts()) {
    if (part.type === 'field') {
      fields[part.fieldname] = typeof part.value === 'string' ? part.value : '';
      continue;
    }

    if (!allowedFileFields.has(part.fieldname)) {
      part.file.resume();
      continue;
    }

    const buffer = await part.toBuffer();
    if (buffer.byteLength === 0) {
      continue;
    }

    files[part.fieldname] = binaryUploadFromBuffer(buffer, part.mimetype, part.filename);
  }

  return { fields, files };
}
