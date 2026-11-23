import test from 'node:test';
import assert from 'node:assert/strict';
import { Room } from '../room.mjs';

const URLS = ['https://10.0.0.5:47443/'];

function fake() {
  const s = { got: [], closed: false, send(t) { this.got.push(JSON.parse(t)); }, close() { this.closed = true; } };
  s.last = () => s.got[s.got.length - 1];
  return s;
}
function setup(maxPeers = 8) {
  const room = new Room({ maxPeers, maxMessageBytes: 16384, urls: URLS });
  const conn = () => { const s = fake(); room.onOpen(s); return s; };
  const say = (s, o) => room.onMessage(s, typeof o === 'string' ? o : JSON.stringify(o));
  return { room, conn, say };
}
const SDP = 'v=0';

test('host gets id 1 and the urls; a second host is refused', () => {
  const { room, conn, say } = setup();
  const h = conn();
  say(h, { type: 'host' });
  assert.deepEqual(h.last(), { type: 'id', id: 1, urls: URLS });
  const h2 = conn();
  say(h2, { type: 'host' });
  assert.deepEqual(h2.last(), { type: 'error', code: 'host_exists' });
  assert.equal(room.counters.dropped, 1);
});

test('join without a room is refused and the socket stays open', () => {
  const { room, conn, say } = setup();
  const g = conn();
  say(g, { type: 'join' });
  assert.deepEqual(g.last(), { type: 'error', code: 'no_host' });
  assert.equal(g.closed, false);
  assert.equal(room.counters.dropped, 1);
});

test('join gives id 2 and then 3; the host sees peer_joined', () => {
  const { conn, say } = setup();
  const h = conn(); say(h, { type: 'host' });
  const g1 = conn(); say(g1, { type: 'join' });
  assert.deepEqual(g1.last(), { type: 'id', id: 2, urls: URLS });
  assert.deepEqual(h.last(), { type: 'peer_joined', id: 2 });
  const g2 = conn(); say(g2, { type: 'join' });
  assert.equal(g2.last().id, 3);
});

test('ids are not reused after a guest leaves', () => {
  const { room, conn, say } = setup();
  const h = conn(); say(h, { type: 'host' });
  const g1 = conn(); say(g1, { type: 'join' });
  room.onClose(g1);
  assert.deepEqual(h.last(), { type: 'peer_left', id: 2 });
  const g2 = conn(); say(g2, { type: 'join' });
  assert.equal(g2.last().id, 3);
});

test('offer guest->host, answer and candidates in both directions carry from', () => {
  const { room, conn, say } = setup();
  const h = conn(); say(h, { type: 'host' });
  const g = conn(); say(g, { type: 'join' });
  say(g, { type: 'offer', to: 1, sdp: SDP });
  assert.deepEqual(h.last(), { type: 'offer', from: 2, sdp: SDP });
  say(h, { type: 'answer', to: 2, sdp: 'ans' });
  assert.deepEqual(g.last(), { type: 'answer', from: 1, sdp: 'ans' });
  say(g, { type: 'candidate', to: 1, mid: '0', index: 0, name: 'cg' });
  assert.deepEqual(h.last(), { type: 'candidate', from: 2, mid: '0', index: 0, name: 'cg' });
  say(h, { type: 'candidate', to: 2, mid: '1', index: 1, name: 'ch' });
  assert.deepEqual(g.last(), { type: 'candidate', from: 1, mid: '1', index: 1, name: 'ch' });
  assert.equal(room.counters.forwarded, 4);
  assert.equal(room.counters.dropped, 0);
});

test('bad_target: guest to guest, guest to unknown, host to unknown, wrong direction', () => {
  const { room, conn, say } = setup();
  const h = conn(); say(h, { type: 'host' });
  const g1 = conn(); say(g1, { type: 'join' });
  const g2 = conn(); say(g2, { type: 'join' });
  const bad = (s, o) => { const n = s.got.length; say(s, o); assert.equal(s.got.length, n + 1); assert.deepEqual(s.last(), { type: 'error', code: 'bad_target' }); };
  bad(g1, { type: 'offer', to: 3, sdp: SDP });
  bad(g1, { type: 'candidate', to: 3, mid: '0', index: 0, name: 'c' });
  bad(g1, { type: 'offer', to: 9, sdp: SDP });
  bad(g1, { type: 'answer', to: 1, sdp: SDP });
  bad(g1, { type: 'offer', to: 2, sdp: SDP }); // to itself
  bad(h, { type: 'answer', to: 9, sdp: SDP });
  bad(h, { type: 'candidate', to: 9, mid: '0', index: 0, name: 'c' });
  bad(h, { type: 'offer', to: 2, sdp: SDP });
  bad(h, { type: 'answer', to: 1, sdp: SDP });
  assert.equal(room.counters.dropped, 9);
  assert.equal(g2.got.length, 1); // only its own id message
});

test('not_in_room: forwarding or host/join from a socket outside the room, or already in it', () => {
  const { room, conn, say } = setup();
  const x = conn();
  say(x, { type: 'offer', to: 1, sdp: SDP });
  assert.deepEqual(x.last(), { type: 'error', code: 'not_in_room' });
  say(x, { type: 'candidate', to: 1, mid: '0', index: 0, name: 'c' });
  assert.deepEqual(x.last(), { type: 'error', code: 'not_in_room' });
  const h = conn(); say(h, { type: 'host' });
  say(h, { type: 'host' });
  assert.deepEqual(h.last(), { type: 'error', code: 'not_in_room' });
  say(h, { type: 'join' });
  assert.deepEqual(h.last(), { type: 'error', code: 'not_in_room' });
  assert.equal(room.counters.dropped, 4);
});

test('bad and too large messages are answered with an error and counted', () => {
  const { room, conn, say } = setup();
  const s = conn();
  say(s, 'nope');
  assert.deepEqual(s.last(), { type: 'error', code: 'bad_message' });
  say(s, JSON.stringify({ type: 'offer', to: 1, sdp: 'a'.repeat(20000) }));
  assert.deepEqual(s.last(), { type: 'error', code: 'too_large' });
  room.noteDropped(s);
  assert.equal(room.counters.dropped, 3);
});

test('room_full at the cap (host included) and the socket is closed', () => {
  const { room, conn, say } = setup(8);
  const h = conn(); say(h, { type: 'host' });
  for (let i = 0; i < 7; i++) { const g = conn(); say(g, { type: 'join' }); assert.equal(g.last().type, 'id'); }
  assert.equal(room.size, 8);
  const extra = conn(); say(extra, { type: 'join' });
  assert.deepEqual(extra.last(), { type: 'room_full' });
  assert.equal(extra.closed, true);
  assert.equal(room.counters.dropped, 1);
  assert.equal(room.size, 8);
});

test('guest close: host gets peer_left', () => {
  const { room, conn, say } = setup();
  const h = conn(); say(h, { type: 'host' });
  const g = conn(); say(g, { type: 'join' });
  room.onClose(g);
  assert.deepEqual(h.last(), { type: 'peer_left', id: 2 });
  assert.equal(room.size, 1);
  assert.equal(room.counters.disconnections, 1);
});

test('host close: guests get host_gone and are closed, the room ends, a new host can register', () => {
  const { room, conn, say } = setup();
  const h = conn(); say(h, { type: 'host' });
  const g1 = conn(); say(g1, { type: 'join' });
  const g2 = conn(); say(g2, { type: 'join' });
  room.onClose(h);
  for (const g of [g1, g2]) {
    assert.deepEqual(g.last(), { type: 'host_gone' });
    assert.equal(g.closed, true);
  }
  assert.equal(room.hasHost, false);
  assert.equal(room.size, 0);
  room.onClose(g1); // the transport confirms the close later; must be harmless
  const h2 = conn(); say(h2, { type: 'host' });
  assert.deepEqual(h2.last(), { type: 'id', id: 1, urls: URLS });
  const g3 = conn(); say(g3, { type: 'join' });
  assert.equal(g3.last().id, 2); // a new room starts its ids again
  assert.equal(room.counters.rooms, 2);
});

test('counters: connections and disconnections', () => {
  const { room, conn } = setup();
  const a = conn(); conn();
  room.onClose(a);
  room.onClose(a);
  assert.equal(room.counters.connections, 2);
  assert.equal(room.counters.disconnections, 1);
});

test('shutdown closes every socket without host_gone (joined guests keep playing)', () => {
  const { room, conn, say } = setup();
  const h = conn(); say(h, { type: 'host' });
  const g = conn(); say(g, { type: 'join' });
  const idle = conn();
  const sent = g.got.length;
  room.shutdown();
  assert.equal(g.got.length, sent);
  assert.ok(h.closed && g.closed && idle.closed);
});
