import sharp from 'sharp';

const THUMBNAIL_MAX_WIDTH = 1200;
const THUMBNAIL_MAX_HEIGHT = 800;

export type StoredMessageAttachment = {
  data: Buffer;
  contentType: string;
  filename: string;
  byteSize: number;
  width?: number;
  height?: number;
  previewable?: boolean;
  variable?: boolean;
};

export function normalizeAttachmentContentType(value: string | undefined) {
  return value?.split(';')[0]?.trim() || 'application/octet-stream';
}

export function extensionForAttachmentContentType(contentType: string) {
  const normalized = normalizeAttachmentContentType(contentType).toLowerCase();

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
  if (normalized === 'application/pdf') {
    return 'pdf';
  }
  if (normalized.startsWith('video/')) {
    return normalized.split('/')[1] || 'video';
  }
  if (normalized.startsWith('text/')) {
    return 'txt';
  }

  return 'bin';
}

export function isAttachmentVariable(contentType: string) {
  return normalizeAttachmentContentType(contentType).toLowerCase().startsWith('image/');
}

export function isAttachmentPreviewable(contentType: string) {
  const normalized = normalizeAttachmentContentType(contentType).toLowerCase();
  return normalized.startsWith('video/') || normalized === 'application/pdf';
}

export async function buildMessageAttachmentFromBuffer(
  buffer: Buffer,
  contentType?: string,
  filename?: string
): Promise<StoredMessageAttachment> {
  const normalizedContentType = normalizeAttachmentContentType(contentType);
  const safeFilename =
    (filename?.trim() ? filename.trim() : `attachment.${extensionForAttachmentContentType(normalizedContentType)}`).replace(/"/g, '');

  let width: number | undefined;
  let height: number | undefined;

  if (isAttachmentVariable(normalizedContentType)) {
    try {
      const metadata = await sharp(buffer).metadata();
      if (typeof metadata.width === 'number') {
        width = metadata.width;
      }
      if (typeof metadata.height === 'number') {
        height = metadata.height;
      }
    } catch {
      // Ignore metadata extraction failures; attachment still remains available.
    }
  }

  return {
    data: buffer,
    contentType: normalizedContentType,
    filename: safeFilename,
    byteSize: buffer.byteLength,
    ...(typeof width === 'number' ? { width } : {}),
    ...(typeof height === 'number' ? { height } : {}),
    previewable: isAttachmentPreviewable(normalizedContentType),
    variable: isAttachmentVariable(normalizedContentType)
  };
}

export function serializeMessageAttachment(messageId: string, attachment: StoredMessageAttachment) {
  const path = `/api/v1/messages/${messageId}/attachment`;
  const previewable = attachment.previewable ?? isAttachmentPreviewable(attachment.contentType);
  const variable = attachment.variable ?? isAttachmentVariable(attachment.contentType);

  return {
    contentType: attachment.contentType,
    content_type: attachment.contentType,
    filename: attachment.filename,
    byteSize: attachment.byteSize,
    byte_size: attachment.byteSize,
    width: attachment.width,
    height: attachment.height,
    previewable,
    variable,
    path,
    downloadPath: `${path}?disposition=attachment`,
    download_path: `${path}?disposition=attachment`,
    previewPath: `${path}/preview`,
    preview_path: `${path}/preview`,
    thumbPath: `${path}/thumb`,
    thumb_path: `${path}/thumb`
  };
}

export async function buildAttachmentImageVariant(attachment: StoredMessageAttachment) {
  if (!(attachment.variable ?? isAttachmentVariable(attachment.contentType))) {
    return null;
  }

  try {
    const data = await sharp(attachment.data)
      .resize({
        width: THUMBNAIL_MAX_WIDTH,
        height: THUMBNAIL_MAX_HEIGHT,
        fit: 'inside',
        withoutEnlargement: true
      })
      .webp()
      .toBuffer();

    const safeName = attachment.filename.replace(/"/g, '').replace(/\.[^.]+$/, '') || 'attachment';
    return {
      data,
      contentType: 'image/webp',
      filename: `${safeName}.webp`
    };
  } catch {
    return null;
  }
}
