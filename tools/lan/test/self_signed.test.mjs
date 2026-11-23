import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import https from 'node:https';
import { makeSelfSigned } from '../self_signed.mjs';

const IPS = ['192.168.1.20', '10.0.0.7', '127.0.0.1'];

test('certificate parses and carries the SAN entries', () => {
  const { keyPem, certPem } = makeSelfSigned({ ips: IPS, dnsNames: ['localhost'], days: 825, now: new Date() });
  const x = new crypto.X509Certificate(certPem);
  for (const ip of IPS) assert.ok(x.subjectAltName.includes(`IP Address:${ip}`), x.subjectAltName);
  assert.ok(x.subjectAltName.includes('DNS:localhost'));
  assert.equal(x.checkIP('192.168.1.20'), '192.168.1.20');
  assert.equal(x.checkIP('10.9.9.9'), undefined);
  assert.ok(x.checkHost('localhost'));
  assert.equal(x.ca, false);
  assert.match(x.subject, /Gladius LAN relay/);
  assert.equal(x.subject, x.issuer);
  assert.ok(x.checkPrivateKey(crypto.createPrivateKey(keyPem)));
  assert.ok(x.verify(x.publicKey), 'signed by its own key');
  const other = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).publicKey;
  assert.equal(x.verify(other), false);
});

test('validity window follows now and days', () => {
  const now = new Date('2026-06-01T12:00:00Z');
  const { certPem } = makeSelfSigned({ ips: ['127.0.0.1'], dnsNames: [], days: 100, now });
  const x = new crypto.X509Certificate(certPem);
  assert.equal(new Date(x.validFrom).toISOString(), '2026-05-31T12:00:00.000Z');
  assert.equal(new Date(x.validTo).toISOString(), '2026-09-09T12:00:00.000Z');
});

test('a real https server with this certificate is trusted by a client that pins it', async () => {
  const { keyPem, certPem } = makeSelfSigned({ ips: ['127.0.0.1'], dnsNames: ['localhost'] });
  const server = https.createServer({ key: keyPem, cert: certPem }, (req, res) => res.end('hello'));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    const body = await new Promise((resolve, reject) => {
      const req = https.get({
        host: '127.0.0.1', port: server.address().port, path: '/', ca: certPem,
        rejectUnauthorized: true, agent: false,
      }, (res) => {
        let s = '';
        res.on('data', (c) => { s += c; });
        res.on('end', () => resolve(s));
      });
      req.on('error', reject);
    });
    assert.equal(body, 'hello');
  } finally {
    server.closeAllConnections();
    await new Promise((r) => server.close(r));
  }
});
