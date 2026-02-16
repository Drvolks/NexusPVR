#!/usr/bin/env node
/**
 * Mock NextPVR server for testing NexusPVR with large datasets.
 *
 * Generates 1000 channels with full EPG data. Matches the real NextPVR v5/v7 API
 * format so the NexusPVR client can connect without modification.
 *
 * Usage:
 *   node server.js [--channels 1000] [--port 8866]
 *
 * Then configure the app to connect to http://<your-ip>:8866
 * with any PIN (default accepts all).
 */

const http = require("http");
const crypto = require("crypto");
const zlib = require("zlib");
const { URL } = require("url");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const args = parseArgs();
const NUM_CHANNELS = args.channels || 1000;
const PORT = args.port || 8866;

// ---------------------------------------------------------------------------
// Data pools
// ---------------------------------------------------------------------------

const GENRES = [
  "News", "Sports", "Drama", "Comedy", "Documentary", "Reality",
  "Sci-Fi", "Action", "Thriller", "Horror", "Romance", "Animation",
  "Music", "Talk Show", "Game Show", "Cooking", "Travel", "Nature",
  "History", "Crime", "Kids", "Education", "Religious", "Shopping",
];

const NETWORK_PREFIXES = [
  "ABC", "NBC", "CBS", "FOX", "CNN", "ESPN", "HBO", "BBC", "CTV", "TSN",
  "CBC", "Global", "AMC", "FX", "TBS", "TNT", "USA", "Bravo", "HGTV",
  "Discovery", "History", "TLC", "Spike", "Comedy", "Cartoon", "Disney",
  "Nick", "MTV", "BET", "Lifetime", "Hallmark", "Syfy", "IFC", "Sundance",
  "A&E", "Paramount", "Showtime", "Starz", "Cinemax", "Epix",
];

const CHANNEL_SUFFIXES = [
  "", " HD", " Plus", " West", " East", " 2", " Extra", " Prime",
  " Classic", " World", " Max",
];

const SHOW_ADJECTIVES = [
  "Breaking", "Ultimate", "Prime", "Late Night", "Morning", "Weekend",
  "Special", "Live", "Daily", "Tonight's", "Championship", "World",
  "National", "Local", "Grand", "Royal", "Golden", "Silver",
];

const SHOW_NOUNS = [
  "News", "Report", "Show", "Hour", "Tonight", "Today", "Update",
  "Roundup", "Review", "Spotlight", "Edition", "Wrap", "Countdown",
  "Challenge", "Adventures", "Stories", "Files", "Chronicles",
  "Masterclass", "Showcase", "Debate", "Forum", "Magazine",
];

const DURATIONS = [15, 30, 30, 30, 60, 60, 60, 60, 90, 120, 120, 180];

// ---------------------------------------------------------------------------
// Random helpers
// ---------------------------------------------------------------------------

function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// ---------------------------------------------------------------------------
// Data generation
// ---------------------------------------------------------------------------

function generateChannels(n) {
  const channels = [];

  for (let i = 1; i <= n; i++) {
    const prefix = NETWORK_PREFIXES[i % NETWORK_PREFIXES.length];
    const suffix = CHANNEL_SUFFIXES[i % CHANNEL_SUFFIXES.length];
    const num = Math.floor(i / (NETWORK_PREFIXES.length * CHANNEL_SUFFIXES.length));
    const name = num > 0 ? `${prefix}${suffix} ${num + 1}` : `${prefix}${suffix}`;

    channels.push({
      channelId: i,
      channelName: name || `Channel ${i}`,
      channelNumber: i,
      channelIcon: true,
      channelDetails: "",
    });
  }
  return channels;
}

function generateShowName(genre, channelName) {
  const adj = pick(SHOW_ADJECTIVES);
  const noun = pick(SHOW_NOUNS);
  const templates = [
    `${adj} ${noun}`,
    `The ${adj} ${noun}`,
    `${channelName} ${noun}`,
    `${adj} ${genre} ${noun}`,
    `${genre} ${noun}`,
  ];
  return pick(templates);
}

function generateEPG(channels) {
  const now = new Date();
  const dayMs = 24 * 60 * 60 * 1000;
  const todayMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const windowStart = new Date(todayMidnight.getTime() - dayMs);
  const windowEnd = new Date(todayMidnight.getTime() + 7 * dayMs);
  const programsByChannel = {};
  let programId = 1;

  for (const ch of channels) {
    const genre = pick(GENRES);
    const programs = [];
    let current = new Date(windowStart);

    while (current < windowEnd) {
      const durationMin = pick(DURATIONS);
      const end = new Date(current.getTime() + durationMin * 60 * 1000);
      const showName = generateShowName(genre, ch.channelName);
      const episodeGenre = Math.random() > 0.5 ? genre : pick(GENRES);

      const s = String(Math.floor(Math.random() * 12) + 1).padStart(2, "0");
      const e = String(Math.floor(Math.random() * 24) + 1).padStart(2, "0");

      const suffixes = ["New.", "Repeat.", "Live.", "Season premiere.", "Series finale.", ""];

      programs.push({
        id: programId,
        name: showName,
        subtitle: Math.random() > 0.3 ? `S${s}E${e}` : undefined,
        desc: `A ${episodeGenre.toLowerCase()} program on ${ch.channelName}. ${pick(suffixes)}`,
        start: Math.floor(current.getTime() / 1000),
        end: Math.floor(end.getTime() / 1000),
        genres: [episodeGenre],
        channelId: ch.channelId,
      });

      programId++;
      current = end;
    }

    programsByChannel[ch.channelId] = programs;
  }
  return programsByChannel;
}

function generateRecordings(channels, programsByChannel) {
  const recordings = [];
  const now = Math.floor(Date.now() / 1000);

  // Pick some completed recordings (past programs)
  let recId = 1;
  for (let i = 0; i < 5 && i < channels.length; i++) {
    const ch = channels[i];
    const progs = programsByChannel[ch.channelId] || [];
    const pastProg = progs.find((p) => p.end < now && p.end > now - 86400);
    if (pastProg) {
      recordings.push({
        id: recId++,
        name: pastProg.name,
        subtitle: pastProg.subtitle || null,
        desc: pastProg.desc,
        startTime: pastProg.start,
        duration: pastProg.end - pastProg.start,
        channel: ch.channelName,
        channelId: ch.channelId,
        status: "Ready",
        file: `/recordings/rec_${recId}.ts`,
        recurring: false,
        recurringParent: null,
        epgEventId: pastProg.id,
        size: Math.floor(Math.random() * 4_000_000_000) + 500_000_000,
        quality: "HD",
        genres: pastProg.genres,
        playbackPosition: null,
      });
    }
  }

  // Pick one currently-recording program
  for (let i = 5; i < 10 && i < channels.length; i++) {
    const ch = channels[i];
    const progs = programsByChannel[ch.channelId] || [];
    const airingProg = progs.find((p) => p.start <= now && p.end > now);
    if (airingProg) {
      recordings.push({
        id: recId++,
        name: airingProg.name,
        subtitle: airingProg.subtitle || null,
        desc: airingProg.desc,
        startTime: airingProg.start,
        duration: airingProg.end - airingProg.start,
        channel: ch.channelName,
        channelId: ch.channelId,
        status: "Recording",
        file: `/recordings/rec_${recId}.ts`,
        recurring: false,
        recurringParent: null,
        epgEventId: airingProg.id,
        size: Math.floor(Math.random() * 2_000_000_000),
        quality: "HD",
        genres: airingProg.genres,
        playbackPosition: null,
      });
      break; // Just one active recording
    }
  }

  // Pick some scheduled recordings (future programs)
  for (let i = 10; i < 15 && i < channels.length; i++) {
    const ch = channels[i];
    const progs = programsByChannel[ch.channelId] || [];
    const futureProg = progs.find((p) => p.start > now && p.start < now + 86400);
    if (futureProg) {
      recordings.push({
        id: recId++,
        name: futureProg.name,
        subtitle: futureProg.subtitle || null,
        desc: futureProg.desc,
        startTime: futureProg.start,
        duration: futureProg.end - futureProg.start,
        channel: ch.channelName,
        channelId: ch.channelId,
        status: "Pending",
        file: null,
        recurring: Math.random() > 0.5,
        recurringParent: null,
        epgEventId: futureProg.id,
        size: null,
        quality: null,
        genres: futureProg.genres,
        playbackPosition: null,
      });
    }
  }

  return recordings;
}

// ---------------------------------------------------------------------------
// PNG generation (same as Dispatcharr mock)
// ---------------------------------------------------------------------------

function generateIconPNG(channelId) {
  const size = 64;
  const hue = (channelId * 137) % 360;
  const [r, g, b] = hslToRgb(hue / 360, 0.5, 0.35);

  const rawData = Buffer.alloc((1 + size * 3) * size);
  for (let y = 0; y < size; y++) {
    const rowOffset = y * (1 + size * 3);
    rawData[rowOffset] = 0;
    for (let x = 0; x < size; x++) {
      const px = rowOffset + 1 + x * 3;
      rawData[px] = r;
      rawData[px + 1] = g;
      rawData[px + 2] = b;
    }
  }

  const compressed = zlib.deflateSync(rawData);
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

  function makeChunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const typeAndData = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(typeAndData) >>> 0);
    return Buffer.concat([len, typeAndData, crc]);
  }

  const ihdrData = Buffer.alloc(13);
  ihdrData.writeUInt32BE(size, 0);
  ihdrData.writeUInt32BE(size, 4);
  ihdrData[8] = 8;
  ihdrData[9] = 2;

  return Buffer.concat([
    signature,
    makeChunk("IHDR", ihdrData),
    makeChunk("IDAT", compressed),
    makeChunk("IEND", Buffer.alloc(0)),
  ]);
}

function crc32(buf) {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    crc ^= buf[i];
    for (let j = 0; j < 8; j++) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return crc ^ 0xffffffff;
}

function hslToRgb(h, s, l) {
  let r, g, b;
  if (s === 0) {
    r = g = b = l;
  } else {
    const hue2rgb = (p, q, t) => {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    };
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const p = 2 * l - q;
    r = hue2rgb(p, q, h + 1 / 3);
    g = hue2rgb(p, q, h);
    b = hue2rgb(p, q, h - 1 / 3);
  }
  return [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)];
}

// ---------------------------------------------------------------------------
// Session management
// ---------------------------------------------------------------------------

const sessions = new Map();

function createSession() {
  const sid = crypto.randomUUID().replace(/-/g, "").substring(0, 32);
  const salt = crypto.randomBytes(8).toString("hex");
  sessions.set(sid, { salt, authenticated: false, created: Date.now() });
  return { sid, salt };
}

function authenticateSession(sid) {
  const session = sessions.get(sid);
  if (session) {
    session.authenticated = true;
    return true;
  }
  return false;
}

function isAuthenticated(sid) {
  const session = sessions.get(sid);
  return session && session.authenticated;
}

// ---------------------------------------------------------------------------
// Scheduled recordings (mutable state for record/cancel)
// ---------------------------------------------------------------------------

let scheduledRecordingId = 1000;
const extraScheduled = [];

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

function handleRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const method = url.searchParams.get("method");
  const sid = url.searchParams.get("sid");
  const format = url.searchParams.get("format");

  // -- Session initiate --
  if (method === "session.initiate") {
    const { sid: newSid, salt } = createSession();
    return json(res, {
      sid: newSid,
      salt: salt,
      stat: "ok",
    });
  }

  // -- Session login (accept any hash) --
  if (method === "session.login") {
    if (sid && authenticateSession(sid)) {
      return json(res, { stat: "ok" });
    }
    return json(res, { stat: "fail" }, 401);
  }

  // -- Require auth for everything else --
  if (!isAuthenticated(sid)) {
    return json(res, { stat: "fail", error: "Not authenticated" }, 401);
  }

  // -- Channel list --
  if (method === "channel.list") {
    return json(res, { channels: CHANNELS });
  }

  // -- Channel listings (EPG per channel) --
  if (method === "channel.listings") {
    const channelId = parseInt(url.searchParams.get("channel_id") || "0", 10);
    const programs = PROGRAMS_BY_CHANNEL[channelId] || [];
    return json(res, { listings: programs });
  }

  // -- Channel icon --
  if (method === "channel.icon") {
    const channelId = parseInt(url.searchParams.get("channel_id") || "0", 10);
    const png = generateIconPNG(channelId);
    res.writeHead(200, {
      "Content-Type": "image/png",
      "Content-Length": png.length,
      "Cache-Control": "public, max-age=86400",
    });
    res.end(png);
    return;
  }

  // -- Recording list --
  if (method === "recording.list") {
    const filter = (url.searchParams.get("filter") || "ready").toLowerCase();
    const allRecs = [...RECORDINGS, ...extraScheduled];
    const filtered = allRecs.filter((r) => {
      const status = (r.status || "").toLowerCase();
      return status === filter;
    });
    return json(res, { recordings: filtered });
  }

  // -- Schedule recording --
  if (method === "recording.save") {
    const eventId = parseInt(url.searchParams.get("event_id") || "0", 10);
    // Find the program and create a pending recording
    let program = null;
    for (const progs of Object.values(PROGRAMS_BY_CHANNEL)) {
      program = progs.find((p) => p.id === eventId);
      if (program) break;
    }
    if (program) {
      extraScheduled.push({
        id: scheduledRecordingId++,
        name: program.name,
        subtitle: program.subtitle || null,
        desc: program.desc,
        startTime: program.start,
        duration: program.end - program.start,
        channel: `Channel ${program.channelId}`,
        channelId: program.channelId,
        status: "Pending",
        file: null,
        recurring: false,
        recurringParent: null,
        epgEventId: program.id,
        size: null,
        quality: null,
        genres: program.genres,
        playbackPosition: null,
      });
    }
    return json(res, { stat: "ok" });
  }

  // -- Cancel recording --
  if (method === "recording.delete") {
    const recordingId = parseInt(url.searchParams.get("recording_id") || "0", 10);
    const idx = extraScheduled.findIndex((r) => r.id === recordingId);
    if (idx !== -1) extraScheduled.splice(idx, 1);
    return json(res, { stat: "ok" });
  }

  // -- Set recording position --
  if (method === "recording.watched.set") {
    return json(res, { stat: "ok" });
  }

  // -- Live stream (mock) --
  if (url.pathname === "/stream" || url.pathname === "/live") {
    return json(res, { error: "Mock server does not provide streams." }, 404);
  }

  // -- Channel icon via /service path (alternative URL format) --
  if (url.pathname === "/service" && method === "channel.icon") {
    const channelId = parseInt(url.searchParams.get("channel_id") || "0", 10);
    const png = generateIconPNG(channelId);
    res.writeHead(200, {
      "Content-Type": "image/png",
      "Content-Length": png.length,
      "Cache-Control": "public, max-age=86400",
    });
    res.end(png);
    return;
  }

  json(res, { stat: "fail", error: "Unknown method" }, 404);
}

function json(res, data, status = 200) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

function parseArgs() {
  const result = {};
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--channels" && argv[i + 1]) {
      result.channels = parseInt(argv[++i], 10);
    } else if (argv[i] === "--port" && argv[i + 1]) {
      result.port = parseInt(argv[++i], 10);
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Generate data and start server
// ---------------------------------------------------------------------------

console.log(`Generating ${NUM_CHANNELS} channels...`);
const CHANNELS = generateChannels(NUM_CHANNELS);

console.log(`Generating EPG data...`);
const PROGRAMS_BY_CHANNEL = generateEPG(CHANNELS);
const totalPrograms = Object.values(PROGRAMS_BY_CHANNEL).reduce((sum, p) => sum + p.length, 0);

console.log(`Generating recordings...`);
const RECORDINGS = generateRecordings(CHANNELS, PROGRAMS_BY_CHANNEL);

const server = http.createServer(handleRequest);

server.listen(PORT, "::", () => {
  console.log(`\nMock NextPVR server running on http://0.0.0.0:${PORT}`);
  console.log(`  Channels:    ${CHANNELS.length}`);
  console.log(`  Programs:    ${totalPrograms}`);
  console.log(`  Recordings:  ${RECORDINGS.length}`);
  console.log(`  Auth:        any PIN accepted`);
  console.log(`  API format:  /services/service?method=...&sid=...&format=json`);
  console.log();
});
