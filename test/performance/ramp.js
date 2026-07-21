import ws from 'k6/ws';
import http from 'k6/http';
import { sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import papaparse from 'https://jslib.k6.io/papaparse/5.1.1/index.js';
import { SharedArray } from 'k6/data';

// Stream names signed with the performance environment's SECRET_KEY_BASE=dummy:
// the rooms list, room 1 messages, and user 1 rooms.
const turboSignedStreamNames = [
  "InJvb21zIg==--54acd827f0a7db144c75316a9fc488c0a949f9635b1e47956ce1bd9d1cf2c41d",
  "IloybGtPaTh2WTJGdGNHWnBjbVV2VW05dmJYTTZPa05zYjNObFpDOHg6bWVzc2FnZXMi--84f0f3dde5d23eb0fdb410746c2fb76813a4ddff1e2798aac4be0c3d969702ba",
  "IloybGtPaTh2WTJGdGNHWnBjbVV2VlhObGNpOHg6cm9vbXMi--df547a679cd41f7531b53d9e48f9883c02481a4da0d862453106441d8546d084"
];

const dummyCookies = new SharedArray('cookies', function () {
  return papaparse.parse(open('cookies.txt'), { header: false }).data;
});

const host = __ENV.HOST || "127.0.0.1";
let port = ":3000";
if (__ENV.PORT) {
  port = `:${__ENV.PORT}`;
}

const users = parseInt(__ENV.USERS || "3000");
const rampS = parseInt(__ENV.RAMP_S || "480");
const holdS = parseInt(__ENV.HOLD_S || "120");
const sendIntervalS = parseFloat(__ENV.SEND_INTERVAL_S || "1");
const sample = parseInt(__ENV.SAMPLE || "25");
const totalS = rampS + holdS;

const deliveryLatency = new Trend('delivery_latency', true);
const messagesReceived = new Counter('bench_messages_received');
const socketErrors = new Counter('bench_socket_errors');

export const options = {
  discardResponseBodies: true,
  scenarios: {
    receivers: {
      executor: 'ramping-vus',
      exec: 'receiver',
      startVUs: 0,
      stages: [
        { duration: `${rampS}s`, target: users },
        { duration: `${holdS}s`, target: users },
      ],
      gracefulRampDown: '0s',
      gracefulStop: '5s',
    },
    sender: {
      executor: 'constant-vus',
      exec: 'sender',
      vus: 1,
      duration: `${totalS}s`,
      gracefulStop: '10s',
    },
  },
};

export function receiver() {
  const cookie = dummyCookies[(__VU - 1) % dummyCookies.length][0];
  const url = `ws://${host}${port}/cable`;
  const params = {
    headers: { 'Origin': 'http://localhost', 'Cookie': `session_token=${cookie}` }
  };
  const subscriptions = [
    '{"channel":"PresenceChannel", "room_id":1}',
    '{"channel":"UnreadRoomsChannel"}',
    '{"channel":"HeartbeatChannel"}',
    ...turboSignedStreamNames.map((name) =>
      `{"channel":"Turbo::StreamsChannel", "signed_stream_name":"${name}"}`)
  ];

  const res = ws.connect(url, params, function (socket) {
    let confirmed = 0;

    socket.on('open', function () {
      subscriptions.forEach((identifier) => {
        socket.send(JSON.stringify({ command: 'subscribe', identifier: identifier }));
      });
    });

    socket.on('message', function (message) {
      if (message.includes('confirm_subscription')) {
        confirmed++;
        if (confirmed === subscriptions.length) {
          console.log(`BENCH CONN ${Date.now()} ${__VU}`);
        }
      } else if (message.includes('reject_subscription')) {
        socketErrors.add(1);
        console.log(`BENCH ERR ${Date.now()} reject_subscription`);
      } else if (message.includes('bench:')) {
        const match = message.match(/bench:(\d+):(\d+)/);
        if (match) {
          const latency = Date.now() - parseInt(match[1]);
          deliveryLatency.add(latency);
          messagesReceived.add(1);
          if (__VU % sample === 0) {
            console.log(`BENCH LAT ${Date.now()} ${latency}`);
          }
        }
      }
    });

    socket.on('error', function (e) {
      if (e.error() != 'websocket: close sent') {
        socketErrors.add(1);
        console.log(`BENCH ERR ${Date.now()} ${e.error()}`);
      }
    });

    socket.setTimeout(() => socket.close(), totalS * 1000);
  });

  if (!res || res.status >= 400) {
    socketErrors.add(1);
    let status = "nil";
    if (res) {
      status = res.status;
    }
    console.log(`BENCH ERR ${Date.now()} connect_status_${status}`);
  }
}

export function sender() {
  const cookie = `session_token=${dummyCookies[0][0]}`;

  const page = http.get(`http://${host}${port}/rooms/1`, {
    headers: { "Cookie": cookie }, responseType: "text"
  });
  const csrfToken = page.body.match(/<meta name="csrf-token" content="([^"]*)"/i)[1];

  const postHeaders = {
    "Cookie": cookie,
    "Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
  };

  let seq = 0;
  const deadline = Date.now() + totalS * 1000;
  while (Date.now() < deadline) {
    seq++;
    const payload = {
      "message[body]": `bench:${Date.now()}:${seq}`,
      "message[client_message_id]": `bench-${seq}-${Math.random().toString(36)}`,
      "authenticity_token": csrfToken
    };
    const res = http.post(`http://${host}${port}/rooms/1/messages`, payload, {
      headers: postHeaders, responseType: "none", tags: { name: 'send_message' }
    });
    if (res.status >= 400) {
      console.log(`BENCH ERR ${Date.now()} post_status_${res.status}`);
    } else {
      console.log(`BENCH SENT ${Date.now()} ${seq}`);
    }
    sleep(sendIntervalS);
  }
}
