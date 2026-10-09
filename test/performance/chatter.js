import ws from 'k6/ws';
import http from 'k6/http';
import papaparse from 'https://jslib.k6.io/papaparse/5.1.1/index.js';
import { SharedArray } from 'k6/data';

const turboSignedStreamNames = [
  "InJvb21zIg==--54acd827f0a7db144c75316a9fc488c0a949f9635b1e47956ce1bd9d1cf2c41d",
  "IloybGtPaTh2WTJGdGNHWnBjbVV2VW05dmJYTTZPa05zYjNObFpDOHg6bWVzc2FnZXMi--84f0f3dde5d23eb0fdb410746c2fb76813a4ddff1e2798aac4be0c3d969702ba",
  "IloybGtPaTh2WTJGdGNHWnBjbVV2VlhObGNpOHg6cm9vbXMi--df547a679cd41f7531b53d9e48f9883c02481a4da0d862453106441d8546d084"
];

const dummyCookies = new SharedArray('another data name', function () {
  // Load CSV file and parse it using Papa Parse
  return papaparse.parse(open('cookies.txt'), { header: false }).data;
});

const host = __ENV.HOST == "localhost" ? "host.docker.internal" : __ENV.HOST;
const port = __ENV.PORT ? `:${__ENV.PORT}` : "";
const users = parseInt(__ENV.USERS)

export const options = {
  discardResponseBodies: true,
  scenarios: {
    sockets: {
      executor: 'constant-arrival-rate',
      duration: '60s',
      rate: Math.ceil(users / 3.0),
      timeUnit: '1s',
      preAllocatedVUs: users,
      env: { SCENARIO: 'sockets' },
      gracefulStop: "0s"
    },
    messages: {
      executor: 'shared-iterations',
      iterations: 1,
      vus: 1,
      startTime: '30s',
      env: { SCENARIO: 'messages' },
      gracefulStop: "0s"
    },
  },
};

export default function() {
  if (__ENV.SCENARIO == 'sockets') {
    sockets();
  } else if (__ENV.SCENARIO == 'messages') {
    messages();
  }
}

export function sockets() {
  const cookie = dummyCookies[Math.floor(Math.random() * parseInt(__ENV.USERS))][0];
  const url = `ws://${host}${port}/cable`;
  const params = {
    headers: { 'Origin': `http://localhost`, 'Cookie': `session_token=${cookie}` }
  };

  ws.connect(url, params, function(socket) {
    socket.on('open', function open() {
      // Subscribe to an ActionCable channel
      socket.send(JSON.stringify({ command: 'subscribe', identifier: '{"channel":"PresenceChannel", "room_id":1}' }));
      socket.send(JSON.stringify({ command: 'subscribe', identifier: '{"channel":"UnreadRoomsChannel"}' }));
      socket.send(JSON.stringify({ command: 'subscribe', identifier: '{"channel":"HeartbeatChannel"}' }));
      turboSignedStreamNames.forEach((signedStreamName) => {
        socket.send(JSON.stringify({ command: 'subscribe', identifier: `{"channel":"Turbo::StreamsChannel", "signed_stream_name":"${signedStreamName}"}` }));
      });

      // Handle incoming messages
      socket.on('message', function(message) {
        if (message.includes("confirm_subscription")) {
          console.log("Subscription confirmed");
        } else if (message.includes("append")) {
          console.log("Message received");
        }
      });
    });

    socket.on('error', function(e) {
      if (e.error() != 'websocket: close sent') {
        console.log('An unexpected error occurred: ', e.error());
      }
    });
  });
}

export function messages() {
  const cookie = `session_token=${dummyCookies[0][0]}`;

  const postHeaders = {
    "Cookie": cookie,
    "Sec-Fetch-Site": "same-origin",
    "Origin": `http://${host}${port}`,
    "Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
  }

  const payload = {
    "message[body]": "Hello from k6",
    "message[client_message_id]": Math.random().toString(36)
  };

  for (let i = 0; i < 100; i++) {
    http.post(`http://${host}${port}/rooms/1/messages`, payload, { headers: postHeaders, responseType: "text" });
  };
}
