// W0: a tiny static file server for the Godot web export (docs/WEB.md). Node built-ins only.
// Binds 127.0.0.1 only. Correct MIME types for .wasm / .pck. Path traversal safe (every path is resolved and must
// stay inside the root). The single-threaded export needs no COOP/COEP headers; none are sent.
//
//   node tools/web/serve.mjs [root=build/web] [port=8060]     (port 0 = pick a free port)
//
// smoke.mjs imports startServer() from here.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
};

// Resolves a URL path inside root; null when it escapes root or is malformed.
export function resolveInside(root, urlPath) {
  let rel;
  try {
    rel = decodeURIComponent(urlPath.split('?')[0].split('#')[0]);
  } catch {
    return null;
  }
  if (rel.includes('\0')) return null;
  if (rel.endsWith('/')) rel += 'index.html';
  const absRoot = path.resolve(root);
  const abs = path.resolve(absRoot, '.' + path.posix.normalize('/' + rel.replace(/\\/g, '/')));
  if (abs !== absRoot && !abs.startsWith(absRoot + path.sep)) return null;
  return abs;
}

// Starts the server; resolves to { server, port, url, close() }.
export function startServer(root, port = 0) {
  const absRoot = path.resolve(root);
  const server = http.createServer((req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { Allow: 'GET, HEAD' });
      res.end();
      return;
    }
    const file = resolveInside(absRoot, req.url || '/');
    if (file === null) {
      res.writeHead(403);
      res.end('forbidden');
      return;
    }
    fs.stat(file, (err, st) => {
      if (err || !st.isFile()) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('not found');
        return;
      }
      const type = MIME[path.extname(file).toLowerCase()] || 'application/octet-stream';
      res.writeHead(200, {
        'Content-Type': type,
        'Content-Length': st.size,
        'Cache-Control': 'no-store',
      });
      if (req.method === 'HEAD') {
        res.end();
        return;
      }
      const stream = fs.createReadStream(file);
      stream.on('error', () => res.destroy());
      stream.pipe(res);
    });
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => {
      const actual = server.address().port;
      resolve({
        server,
        port: actual,
        url: `http://127.0.0.1:${actual}/`,
        close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => r()); }),
      });
    });
  });
}

const isMain = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  const root = process.argv[2] || 'build/web';
  const port = Number(process.argv[3] ?? 8060);
  if (!fs.existsSync(root)) {
    console.error(`serve.mjs: root ${root} does not exist (export first, docs/WEB.md)`);
    process.exit(2);
  }
  startServer(root, port).then((s) => {
    console.log(`serving ${path.resolve(root)} at ${s.url}`);
  }, (e) => {
    console.error(`serve.mjs: ${e.message}`);
    process.exit(1);
  });
}
