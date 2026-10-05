

const http = require("http");
const crypto = require("crypto");

// ---------------- settings (edit these, or set them as environment variables) ----------------
const CONFIG = {
  ADMIN: process.env.ADMIN || "", // password the finder sends in the x-admin header
  TOKEN: process.env.TOKEN ?? "meow", // optional: loader must send the same value (PRESENCE_TOKEN in the loader). "" = off
  PORT: Number(process.env.SERVER_PORT || process.env.PORT) || 3000,
  ONLINE_MS: 30 * 1000, // shown as online if seen in the last 30s (client beats every 10s)
  PURGE_MS: 2 * 60 * 1000, // forgotten completely after 2 min
  RATE_PER_MIN: 120, // max requests per IP per minute
  MAX_SESSIONS: 2000, // safety cap so junk requests can't fill memory
  TRUST_PROXY: process.env.TRUST_PROXY === "1", // set to 1 only if a reverse proxy sets x-forwarded-for
};

if (CONFIG.ADMIN === "CHANGE_ME") {
  console.error("Set an admin password first: edit CONFIG.ADMIN in index.js or set the ADMIN variable.");
  process.exit(1);
}

// Natural Disaster Survival only
const isNDS = (gid, pid) => gid === "65241" || pid === "189707";

// ---------------- state ----------------
const sessions = new Map(); // uid -> { user, uid, gid, pid, jid, hwid, last }
const hits = new Map(); // ip -> { count, resetAt }

// ---------------- helpers ----------------
const send = (res, status, body, type = "text/plain") => {
  const data = typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, { "content-type": type === "json" ? "application/json" : type });
  res.end(data);
};

function clientIp(req) {
  if (CONFIG.TRUST_PROXY) {
    const fwd = req.headers["x-forwarded-for"];
    if (fwd) return String(fwd).split(",")[0].trim();
  }
  return req.socket.remoteAddress || "unknown";
}

function rateLimited(ip) {
  const now = Date.now();
  let h = hits.get(ip);
  if (!h || now > h.resetAt) {
    h = { count: 0, resetAt: now + 60 * 1000 };
    hits.set(ip, h);
  }
  h.count++;
  return h.count > CONFIG.RATE_PER_MIN;
}

function safeEqual(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

// returns a clean session object, or null if the request is malformed
function parseSession(p, hwid) {
  const user = p.get("user") || "";
  const uid = p.get("uid") || "";
  const gid = p.get("gid") || "";
  const pid = p.get("pid") || "";
  const jid = p.get("jid") || "";
  if (!/^[A-Za-z0-9_]{1,40}$/.test(user)) return null;
  if (!/^\d{1,20}$/.test(uid) || !/^\d{1,20}$/.test(gid) || !/^\d{1,20}$/.test(pid)) return null;
  if (!/^[A-Za-z0-9-]{0,64}$/.test(jid)) return null;
  return { user, uid: uid === "0" ? "hw-" + hwid.slice(0, 32) : uid, gid, pid, jid, hwid };
}

// ---------------- server ----------------
const server = http.createServer((req, res) => {
  try {
    const ip = clientIp(req);
    if (rateLimited(ip)) return send(res, 429, "slow down");

    const url = new URL(req.url, "http://localhost");
    const p = url.searchParams;

    // health check
    if (url.pathname === "/") return send(res, 200, "presence server up");

    // ----- the finder reads this (needs the admin password) -----
    if (url.pathname === "/sessions") {
      if (!safeEqual(req.headers["x-admin"] || "", CONFIG.ADMIN)) {
        return send(res, 401, { error: "wrong admin password" }, "json");
      }
      const now = Date.now();
      const list = [...sessions.values()]
        .filter((s) => now - s.last <= CONFIG.ONLINE_MS)
        .sort((a, b) => b.last - a.last)
        .map((s) => ({
          user: s.user,
          userId: s.uid,
          gameId: s.gid,
          placeId: s.pid,
          jobId: s.jid,
          seenAgo: Math.round((now - s.last) / 1000), // seconds
          join: s.pid && s.jid ? `roblox://experiences/start?placeId=${s.pid}&gameInstanceId=${s.jid}` : null,
        }));
      return send(res, 200, { sessions: list }, "json");
    }

    // ----- the loader calls these -----
    if (url.pathname === "/beat" || url.pathname === "/leave") {
      if (CONFIG.TOKEN && !safeEqual(p.get("t") || "", CONFIG.TOKEN)) return send(res, 403, "forbidden");

      const hwid = p.get("hwid");
      if (!hwid || hwid.length > 128) return send(res, 400, "bad request");

      const s = parseSession(p, hwid);
      if (!s) return send(res, 400, "bad request");

      const existing = sessions.get(s.uid);
      const now = Date.now();
      // someone else's active entry can't be overwritten or removed from a different machine
      if (existing && existing.hwid !== hwid && now - existing.last < CONFIG.ONLINE_MS) {
        return send(res, 409, "conflict");
      }

      if (url.pathname === "/leave") {
        sessions.delete(s.uid);
        return send(res, 200, "ok");
      }

      // only Natural Disaster Survival players are ever listed
      if (!isNDS(s.gid, s.pid)) return send(res, 200, "ignored");

      if (!existing && sessions.size >= CONFIG.MAX_SESSIONS) return send(res, 503, "full");

      sessions.set(s.uid, { ...s, last: now });
      return send(res, 200, "ok");
    }

    send(res, 404, "not found");
  } catch (err) {
    console.error("request error:", err);
    send(res, 500, "error");
  }
});

// housekeeping: forget old sessions and rate-limit counters
setInterval(() => {
  const now = Date.now();
  for (const [uid, s] of sessions) if (now - s.last > CONFIG.PURGE_MS) sessions.delete(uid);
  for (const [ip, h] of hits) if (now > h.resetAt) hits.delete(ip);
}, 15 * 1000).unref();

server.listen(CONFIG.PORT, "0.0.0.0", () => {
  console.log(`presence server listening on port ${CONFIG.PORT}`);
});
