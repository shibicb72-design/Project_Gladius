// W2: a throwaway self-signed TLS certificate made with Node built-ins only (no openssl).
// EC P-256 key, X.509 v3 certificate hand-encoded in DER, signed ecdsa-with-SHA256.
// This is a local web-server key for the home-network relay. It is not a signing or release key.
import crypto from 'node:crypto';

// ---- minimal DER encoder
function derLen(n) {
  if (n < 0x80) return Buffer.from([n]);
  const bytes = [];
  for (let v = n; v > 0; v = Math.floor(v / 256)) bytes.unshift(v & 0xff);
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}
const tlv = (tag, ...parts) => {
  const body = Buffer.concat(parts);
  return Buffer.concat([Buffer.from([tag]), derLen(body.length), body]);
};
const seq = (...p) => tlv(0x30, ...p);
const set = (...p) => tlv(0x31, ...p);
const oid = (dotted) => {
  const n = dotted.split('.').map(Number);
  const out = [n[0] * 40 + n[1]];
  for (const v of n.slice(2)) {
    const chunk = [v & 0x7f];
    for (let r = Math.floor(v / 128); r > 0; r = Math.floor(r / 128)) chunk.unshift((r & 0x7f) | 0x80);
    out.push(...chunk);
  }
  return tlv(0x06, Buffer.from(out));
};
const utf8 = (s) => tlv(0x0c, Buffer.from(s, 'utf8'));
const ia5 = (s) => tlv(0x16, Buffer.from(s, 'ascii'));
const octets = (...p) => tlv(0x04, ...p);
const bitString = (buf) => tlv(0x03, Buffer.from([0]), buf);
const bool = (v) => tlv(0x01, Buffer.from([v ? 0xff : 0x00]));
const intUnsigned = (buf) => {
  let b = buf;
  while (b.length > 1 && b[0] === 0) b = b.subarray(1);
  if (b[0] & 0x80) b = Buffer.concat([Buffer.from([0]), b]);
  return tlv(0x02, b);
};
function utcTime(d) {
  const p = (n) => String(n).padStart(2, '0');
  const y = d.getUTCFullYear();
  if (y < 1950 || y >= 2050) throw new Error('certificate date outside UTCTime range');
  return tlv(0x17, Buffer.from(`${p(y % 100)}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`, 'ascii'));
}
function ipv4Bytes(ip) {
  const parts = String(ip).split('.');
  if (parts.length !== 4 || parts.some((x) => !/^\d{1,3}$/.test(x) || Number(x) > 255)) throw new Error(`not an IPv4 address: ${ip}`);
  return Buffer.from(parts.map(Number));
}

const OID_ECDSA_SHA256 = '1.2.840.10045.4.3.2';
const OID_CN = '2.5.4.3';
const OID_SAN = '2.5.29.17';
const OID_BASIC = '2.5.29.19';
const OID_KEY_USAGE = '2.5.29.15';
const OID_EKU = '2.5.29.37';
const OID_SERVER_AUTH = '1.3.6.1.5.5.7.3.1';

export const CERT_CN = 'Gladius LAN relay';

// Pure apart from key generation and the random serial. Returns { keyPem, certPem }.
export function makeSelfSigned({ ips = [], dnsNames = [], days = 825, now = new Date() } = {}) {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const spki = publicKey.export({ type: 'spki', format: 'der' });

  const serial = crypto.randomBytes(16);
  serial[0] &= 0x7f;
  if (serial[0] === 0) serial[0] = 1;

  const name = seq(set(seq(oid(OID_CN), utf8(CERT_CN))));
  const notBefore = new Date(now.getTime() - 24 * 3600 * 1000);
  const notAfter = new Date(now.getTime() + days * 24 * 3600 * 1000);
  const sigAlg = seq(oid(OID_ECDSA_SHA256));

  const names = [
    ...dnsNames.map((d) => tlv(0x82, Buffer.from(d, 'ascii'))),
    ...ips.map((ip) => tlv(0x87, ipv4Bytes(ip))),
  ];
  const extensions = seq(
    seq(oid(OID_SAN), octets(seq(...names))),
    seq(oid(OID_BASIC), bool(true), octets(seq())), // critical, CA:FALSE (default)
    seq(oid(OID_KEY_USAGE), bool(true), octets(tlv(0x03, Buffer.from([0x07, 0x80])))), // digitalSignature
    seq(oid(OID_EKU), octets(seq(oid(OID_SERVER_AUTH)))),
  );

  const tbs = seq(
    tlv(0xa0, tlv(0x02, Buffer.from([2]))), // version v3
    intUnsigned(serial),
    sigAlg,
    name,
    seq(utcTime(notBefore), utcTime(notAfter)),
    name,
    spki,
    tlv(0xa3, extensions),
  );
  const signature = crypto.sign('sha256', tbs, privateKey); // DER-encoded ECDSA
  const cert = seq(tbs, sigAlg, bitString(signature));

  const pem = (label, der) => `-----BEGIN ${label}-----\n${der.toString('base64').match(/.{1,64}/g).join('\n')}\n-----END ${label}-----\n`;
  return {
    keyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    certPem: pem('CERTIFICATE', cert),
  };
}
