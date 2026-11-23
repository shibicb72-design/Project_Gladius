// W2: relay protocol v1, pure message rules (no network). Node built-ins only.
// Client -> relay messages are parsed and checked here; relay -> client messages are built here.
// Every field is required, extra fields are refused, wrong types are refused.

export const PROTO = 1;
export const ERR = Object.freeze({
  BAD_MESSAGE: 'bad_message',
  TOO_LARGE: 'too_large',
  NO_HOST: 'no_host',
  HOST_EXISTS: 'host_exists',
  NOT_IN_ROOM: 'not_in_room',
  BAD_TARGET: 'bad_target',
});

const isInt = (v) => Number.isSafeInteger(v);
const isId = (v) => isInt(v) && v >= 1;
const isStr = (v) => typeof v === 'string';

// type -> { field: validator }. Order of keys does not matter.
const CLIENT_TYPES = {
  host: {},
  join: {},
  offer: { to: isId, sdp: (v, max) => isStr(v) && v.length > 0 && v.length <= max },
  answer: { to: isId, sdp: (v, max) => isStr(v) && v.length > 0 && v.length <= max },
  candidate: { to: isId, mid: isStr, index: (v) => isInt(v) && v >= 0, name: isStr },
};

export const CLIENT_MESSAGE_TYPES = Object.freeze(Object.keys(CLIENT_TYPES));

// Parses one client text frame. Returns { ok: true, msg } or { ok: false, code }.
export function parseClientMessage(text, maxBytes) {
  if (typeof text !== 'string') return { ok: false, code: ERR.BAD_MESSAGE };
  if (Buffer.byteLength(text, 'utf8') > maxBytes) return { ok: false, code: ERR.TOO_LARGE };
  let obj;
  try {
    obj = JSON.parse(text);
  } catch {
    return { ok: false, code: ERR.BAD_MESSAGE };
  }
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) return { ok: false, code: ERR.BAD_MESSAGE };
  const type = obj.type;
  if (!isStr(type) || !Object.hasOwn(CLIENT_TYPES, type)) return { ok: false, code: ERR.BAD_MESSAGE };
  const spec = CLIENT_TYPES[type];
  const keys = Object.keys(obj).filter((k) => k !== 'type');
  if (keys.length !== Object.keys(spec).length) return { ok: false, code: ERR.BAD_MESSAGE };
  for (const k of keys) if (!Object.hasOwn(spec, k)) return { ok: false, code: ERR.BAD_MESSAGE };
  for (const [k, check] of Object.entries(spec)) {
    if (!check(obj[k], maxBytes)) return { ok: false, code: ERR.BAD_MESSAGE };
  }
  return { ok: true, msg: obj };
}

// ---- relay -> client builders (each returns the JSON text to send)
export const buildId = (id, urls) => JSON.stringify({ type: 'id', id, urls: [...urls] });
export const buildPeerJoined = (id) => JSON.stringify({ type: 'peer_joined', id });
export const buildPeerLeft = (id) => JSON.stringify({ type: 'peer_left', id });
export const buildRoomFull = () => JSON.stringify({ type: 'room_full' });
export const buildHostGone = () => JSON.stringify({ type: 'host_gone' });
export const buildError = (code) => JSON.stringify({ type: 'error', code });
export const buildOffer = (from, sdp) => JSON.stringify({ type: 'offer', from, sdp });
export const buildAnswer = (from, sdp) => JSON.stringify({ type: 'answer', from, sdp });
export const buildCandidate = (from, mid, index, name) => JSON.stringify({ type: 'candidate', from, mid, index, name });
export const buildLanJson = (urls, maxPeers) => JSON.stringify({ lan: true, proto: PROTO, urls: [...urls], max_peers: maxPeers });
