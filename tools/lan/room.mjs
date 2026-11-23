// W2: the relay's one room. Works on abstract "socket" objects { send(text), close() } so it needs no network.
// Never logs and never stores message contents; it only counts.
import {
  ERR, parseClientMessage, buildId, buildPeerJoined, buildPeerLeft, buildRoomFull, buildHostGone, buildError,
  buildOffer, buildAnswer, buildCandidate,
} from './lan_protocol.mjs';

export class Room {
  constructor({ maxPeers = 8, maxMessageBytes = 16384, urls = [], onChange = null } = {}) {
    this.maxPeers = maxPeers;
    this.maxMessageBytes = maxMessageBytes;
    this.urls = urls;
    this.onChange = onChange; // optional () => void, called after counters or the room change
    this.counters = { connections: 0, disconnections: 0, dropped: 0, forwarded: 0, rooms: 0 };
    this.open = new Set(); // every connected socket
    this._resetRoom();
  }

  _resetRoom() {
    this.peers = new Map(); // socket -> id (sockets that are in the room)
    this.byId = new Map(); // id -> socket
    this.host = null;
    this.nextId = 2;
  }

  get size() { return this.peers.size; }
  get hasHost() { return this.host !== null; }

  _changed() { if (this.onChange) this.onChange(); }

  _safeSend(sock, text) {
    try { sock.send(text); } catch { /* a dead socket is cleaned up by its close event */ }
  }

  _safeClose(sock) {
    try { sock.close(); } catch { /* already closed */ }
  }

  _refuse(sock, code) {
    this.counters.dropped++;
    this._safeSend(sock, buildError(code));
    this._changed();
  }

  // For a frame the transport layer dropped without parsing (binary frame, over the transport size cap).
  noteDropped(sock, code = ERR.BAD_MESSAGE) {
    if (sock && this.open.has(sock)) this._refuse(sock, code);
    else { this.counters.dropped++; this._changed(); }
  }

  onOpen(sock) {
    this.open.add(sock);
    this.counters.connections++;
    this._changed();
  }

  onMessage(sock, text) {
    if (!this.open.has(sock)) return;
    const r = parseClientMessage(text, this.maxMessageBytes);
    if (!r.ok) { this._refuse(sock, r.code); return; }
    const m = r.msg;
    const id = this.peers.get(sock);
    switch (m.type) {
      case 'host': return this._onHost(sock, id);
      case 'join': return this._onJoin(sock, id);
      default: return this._onForward(sock, id, m);
    }
  }

  _onHost(sock, id) {
    if (id !== undefined) { this._refuse(sock, ERR.NOT_IN_ROOM); return; }
    if (this.host !== null) { this._refuse(sock, ERR.HOST_EXISTS); return; }
    this.host = sock;
    this.peers.set(sock, 1);
    this.byId.set(1, sock);
    this.counters.rooms++;
    this._safeSend(sock, buildId(1, this.urls));
    this._changed();
  }

  _onJoin(sock, id) {
    if (id !== undefined) { this._refuse(sock, ERR.NOT_IN_ROOM); return; }
    if (this.host === null) { this._refuse(sock, ERR.NO_HOST); return; }
    if (this.peers.size >= this.maxPeers) {
      this.counters.dropped++;
      this._safeSend(sock, buildRoomFull());
      this._safeClose(sock);
      this._changed();
      return;
    }
    const gid = this.nextId++;
    this.peers.set(sock, gid);
    this.byId.set(gid, sock);
    this._safeSend(sock, buildId(gid, this.urls));
    this._safeSend(this.host, buildPeerJoined(gid));
    this._changed();
  }

  _onForward(sock, id, m) {
    if (id === undefined) { this._refuse(sock, ERR.NOT_IN_ROOM); return; }
    const fromHost = id === 1;
    let target;
    if (m.type === 'offer') {
      target = !fromHost && m.to === 1 ? this.host : undefined; // guest -> host only
    } else if (m.type === 'answer') {
      target = fromHost && m.to !== 1 ? this.byId.get(m.to) : undefined; // host -> a current guest only
    } else {
      target = fromHost ? (m.to !== 1 ? this.byId.get(m.to) : undefined) : (m.to === 1 ? this.host : undefined);
    }
    if (target === undefined || target === sock) { this._refuse(sock, ERR.BAD_TARGET); return; }
    let out;
    if (m.type === 'offer') out = buildOffer(id, m.sdp);
    else if (m.type === 'answer') out = buildAnswer(id, m.sdp);
    else out = buildCandidate(id, m.mid, m.index, m.name);
    this.counters.forwarded++;
    this._safeSend(target, out);
  }

  onClose(sock) {
    if (!this.open.delete(sock)) return;
    this.counters.disconnections++;
    const id = this.peers.get(sock);
    if (id === undefined) { this._changed(); return; }
    if (sock === this.host) {
      const guests = [...this.peers.keys()].filter((s) => s !== sock);
      this._resetRoom();
      for (const g of guests) {
        this._safeSend(g, buildHostGone());
        this._safeClose(g);
      }
    } else {
      this.peers.delete(sock);
      this.byId.delete(id);
      if (this.host !== null) this._safeSend(this.host, buildPeerLeft(id));
    }
    this._changed();
  }

  // Stops the room: the host's relay is going away, so tell guests and close every socket.
  shutdown() {
    const all = [...this.open];
    const guests = all.filter((s) => this.peers.has(s) && s !== this.host);
    for (const g of guests) this._safeSend(g, buildHostGone());
    for (const s of all) this._safeClose(s);
  }
}
