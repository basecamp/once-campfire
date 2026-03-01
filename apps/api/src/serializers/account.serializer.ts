import { buildAccountLogoPath } from '../services/avatar-media.js';

export function serializeAccount(account: {
  _id: unknown;
  name: string;
  joinCode: string;
  logo?: {
    contentType: string;
    filename: string;
    byteSize: number;
  } | null;
  logoUrl?: string;
  customStyles?: string;
  updatedAt?: Date;
  settings?: {
    restrictRoomCreationToAdministrators?: boolean;
  } | null;
}) {
  const logoPath = buildAccountLogoPath(account, 'large');

  return {
    id: String(account._id),
    name: account.name,
    joinCode: account.joinCode,
    join_code: account.joinCode,
    logoUrl: logoPath,
    logo_url: logoPath,
    customStyles: account.customStyles ?? '',
    custom_styles: account.customStyles ?? '',
    settings: {
      restrictRoomCreationToAdministrators: account.settings?.restrictRoomCreationToAdministrators ?? false,
      restrict_room_creation_to_administrators: account.settings?.restrictRoomCreationToAdministrators ?? false
    }
  };
}
