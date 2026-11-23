import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseClientMessage, CLIENT_MESSAGE_TYPES, buildId, buildPeerJoined, buildPeerLeft, buildRoomFull, buildHostGone,
  buildError, buildOffer, buildAnswer, buildCandidate, buildLanJson,
} from '../lan_protocol.mjs';

const MAX = 16384;
const ok = (o) => parseClientMessage(JSON.stringify(o), MAX);
const code = (text) => {
  const r = parseClientMessage(text, MAX);
  assert.equal(r.ok, false, `expected refusal for ${text}`);
  return r.code;
};

test('every client message type is accepted in its exact shape', () => {
  assert.deepEqual([...CLIENT_MESSAGE_TYPES].sort(), ['answer', 'candidate', 'host', 'join', 'offer']);
  for (const m of [
    { type: 'host' },
    { type: 'join' },
    { type: 'offer', to: 1, sdp: 'v=0' },
    { type: 'answer', to: 2, sdp: 'v=0' },
    { type: 'candidate', to: 3, mid: '0', index: 0, name: 'candidate:1 1 UDP 1 10.0.0.1 5000 typ host' },
    { type: 'candidate', to: 1, mid: '', index: 2, name: '' },
  ]) {
    const r = ok(m);
    assert.equal(r.ok, true, JSON.stringify(m));
    assert.deepEqual(r.msg, m);
  }
});

test('refuses non-JSON, non-objects and unknown types', () => {
  assert.equal(code('not json'), 'bad_message');
  assert.equal(code(''), 'bad_message');
  for (const t of ['[]', '1', '"host"', 'null', 'true']) assert.equal(code(t), 'bad_message');
  assert.equal(code('{}'), 'bad_message');
  assert.equal(code('{"type":"ping"}'), 'bad_message');
  assert.equal(code('{"type":5}'), 'bad_message');
  assert.equal(code('{"type":"__proto__"}'), 'bad_message');
  assert.equal(code('{"type":"toString"}'), 'bad_message');
  assert.equal(parseClientMessage(5, MAX).code, 'bad_message');
});

test('refuses missing, extra and wrongly typed fields', () => {
  assert.equal(code('{"type":"host","x":1}'), 'bad_message');
  assert.equal(code('{"type":"join","to":1}'), 'bad_message');
  assert.equal(code('{"type":"offer","to":1}'), 'bad_message');
  assert.equal(code('{"type":"offer","sdp":"v=0"}'), 'bad_message');
  assert.equal(code('{"type":"offer","to":1,"sdp":"v=0","x":1}'), 'bad_message');
  assert.equal(code('{"type":"offer","to":"1","sdp":"v=0"}'), 'bad_message');
  assert.equal(code('{"type":"offer","to":1.5,"sdp":"v=0"}'), 'bad_message');
  assert.equal(code('{"type":"offer","to":0,"sdp":"v=0"}'), 'bad_message');
  assert.equal(code('{"type":"offer","to":1,"sdp":5}'), 'bad_message');
  assert.equal(code('{"type":"offer","to":1,"sdp":""}'), 'bad_message');
  assert.equal(code('{"type":"answer","to":1,"sdp":null}'), 'bad_message');
  assert.equal(code('{"type":"candidate","to":1,"mid":"0","index":0}'), 'bad_message');
  assert.equal(code('{"type":"candidate","to":1,"mid":0,"index":0,"name":"c"}'), 'bad_message');
  assert.equal(code('{"type":"candidate","to":1,"mid":"0","index":"0","name":"c"}'), 'bad_message');
  assert.equal(code('{"type":"candidate","to":1,"mid":"0","index":0,"name":5}'), 'bad_message');
});

test('refuses a bad candidate index', () => {
  for (const idx of ['-1', '1.5', '1e999', 'null']) {
    assert.equal(code(`{"type":"candidate","to":1,"mid":"0","index":${idx},"name":"c"}`), 'bad_message', idx);
  }
});

test('refuses oversized messages as too_large and caps the sdp', () => {
  const big = JSON.stringify({ type: 'offer', to: 1, sdp: 'a'.repeat(MAX) });
  assert.equal(code(big), 'too_large');
  assert.equal(parseClientMessage(JSON.stringify({ type: 'host' }), 5).code, 'too_large');
  // multi-byte characters count as bytes
  const wide = JSON.stringify({ type: 'offer', to: 1, sdp: String.fromCharCode(233).repeat(MAX / 2) });
  assert.equal(code(wide), 'too_large');
  const edge = { type: 'offer', to: 1, sdp: 'a'.repeat(MAX - 40) };
  assert.equal(parseClientMessage(JSON.stringify(edge), MAX).ok, true);
});

test('builders produce the exact shapes', () => {
  assert.deepEqual(JSON.parse(buildId(1, ['https://10.0.0.5:1/'])), { type: 'id', id: 1, urls: ['https://10.0.0.5:1/'] });
  assert.deepEqual(JSON.parse(buildPeerJoined(2)), { type: 'peer_joined', id: 2 });
  assert.deepEqual(JSON.parse(buildPeerLeft(3)), { type: 'peer_left', id: 3 });
  assert.deepEqual(JSON.parse(buildRoomFull()), { type: 'room_full' });
  assert.deepEqual(JSON.parse(buildHostGone()), { type: 'host_gone' });
  assert.deepEqual(JSON.parse(buildError('no_host')), { type: 'error', code: 'no_host' });
  assert.deepEqual(JSON.parse(buildOffer(2, 'sdp')), { type: 'offer', from: 2, sdp: 'sdp' });
  assert.deepEqual(JSON.parse(buildAnswer(1, 'sdp')), { type: 'answer', from: 1, sdp: 'sdp' });
  assert.deepEqual(JSON.parse(buildCandidate(2, '0', 1, 'c')), { type: 'candidate', from: 2, mid: '0', index: 1, name: 'c' });
  assert.deepEqual(JSON.parse(buildLanJson(['https://a/'], 8)), { lan: true, proto: 1, urls: ['https://a/'], max_peers: 8 });
});
