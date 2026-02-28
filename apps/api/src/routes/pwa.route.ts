import type { FastifyPluginAsync } from 'fastify';
import { env } from '../config/env.js';
import { buildAccountLogoPath } from '../services/avatar-media.js';
import { getAccount } from '../services/account-singleton.js';

const pwaRoutes: FastifyPluginAsync = async (app) => {
  app.get('/webmanifest', async () => {
    const account = await getAccount();
    const accountName = account?.name ?? 'Campfire';
    const logoLarge = account?.logoUrl || `${env.APP_BASE_URL}${buildAccountLogoPath(account, 'large')}`;
    const logoSmall = account?.logoUrl || `${env.APP_BASE_URL}${buildAccountLogoPath(account, 'small')}`;

    return {
      name: accountName,
      short_name: accountName,
      icons: [
        {
          src: logoSmall,
          type: 'image/png',
          sizes: '192x192'
        },
        {
          src: logoLarge,
          type: 'image/png',
          sizes: '512x512'
        },
        {
          src: logoLarge,
          type: 'image/png',
          sizes: '512x512',
          purpose: 'maskable'
        }
      ],
      start_url: '/',
      display: 'standalone',
      scope: '/',
      description: 'A chat app from the makers of Basecamp and HEY.',
      categories: ['social', 'business', 'productivity'],
      background_color: '#ffffff',
      theme_color: '#ffffff',
      shortcuts: [
        {
          name: 'New chat room',
          description: 'Open Campfire and start a new chat room',
          url: 'rooms/opens/new',
          icons: [{ src: `${env.APP_BASE_URL}/add.svg`, sizes: 'any' }]
        },
        {
          name: 'My profile',
          description: 'Open Campfire and view your profile',
          url: '/users/me/profile',
          icons: [{ src: `${env.APP_BASE_URL}/person.svg`, sizes: 'any' }]
        }
      ],
      screenshots: [
        {
          src: `${env.APP_BASE_URL}/screenshots/android-chat.png`,
          sizes: '1080x2400',
          form_factor: 'narrow',
          label: 'Campfire is an installable, self-hosted group chat system.'
        },
        {
          src: `${env.APP_BASE_URL}/screenshots/android-sidebar.png`,
          sizes: '1080x2400',
          form_factor: 'narrow',
          label: 'Easily invite people. Make rooms. @mentions, DMs, and mobile support.'
        },
        {
          src: `${env.APP_BASE_URL}/screenshots/android-dark-mode.png`,
          sizes: '1080x2400',
          form_factor: 'narrow',
          label: 'Full support for dark mode, customizable to your brand.'
        }
      ]
    };
  });

  app.get('/service-worker', async (request, reply) => {
    reply.header('content-type', 'application/javascript; charset=utf-8');

    return reply.send(`self.addEventListener("push", async (event) => {
  const data = await event.data.json()
  event.waitUntil(Promise.all([ showNotification(data), updateBadgeCount(data.options) ]))
})

async function showNotification({ title, options }) {
  return self.registration.showNotification(title, options)
}

async function updateBadgeCount({ data: { badge } }) {
  return self.navigator.setAppBadge?.(badge || 0)
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  const url = new URL(event.notification.data.path, self.location.origin).href
  event.waitUntil(openURL(url))
})

async function openURL(url) {
  const clients = await self.clients.matchAll({ type: "window" })
  const focused = clients.find((client) => client.focused)

  if (focused) {
    await focused.navigate(url)
  } else {
    await self.clients.openWindow(url)
  }
}`);
  });
};

export default pwaRoutes;
