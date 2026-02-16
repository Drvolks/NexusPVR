#!/usr/bin/env node
/**
 * Mock Dispatcharr server for testing NexusPVR/DispatcherPVR with large datasets.
 *
 * Generates 1000 channels with full EPG data. Designed to stress-test the app
 * and be extended with edge cases that cause problems.
 *
 * Usage:
 *   node server.js [--channels 1000] [--port 9191]
 *
 * Then configure the app to connect to http://<your-ip>:9191
 * with any username/password.
 */

const http = require("http");
const crypto = require("crypto");
const { URL } = require("url");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const args = parseArgs();
const NUM_CHANNELS = args.channels || 1000;
const PORT = args.port || 9191;
const PAGE_SIZE = 100;

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
      id: i,
      name: name || `Channel ${i}`,
      channel_number: i,
      tvg_id: `ch${i}.mock`,
      logo_id: i,
      uuid: crypto.randomUUID(),
      epg_data_id: i,
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
  // Start at midnight yesterday, end at midnight 7 days from now
  const todayMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const windowStart = new Date(todayMidnight.getTime() - dayMs);
  const windowEnd = new Date(todayMidnight.getTime() + 7 * dayMs);
  const programs = [];
  let programId = 1;

  for (const ch of channels) {
    const genre = pick(GENRES);
    let current = new Date(windowStart);

    while (current < windowEnd) {
      const durationMin = pick(DURATIONS);
      const end = new Date(current.getTime() + durationMin * 60 * 1000);
      const showName = generateShowName(genre, ch.name);
      const episodeGenre = Math.random() > 0.5 ? genre : pick(GENRES);

      const subtitleOptions = [null, null, null];
      const s = String(Math.floor(Math.random() * 12) + 1).padStart(2, "0");
      const e = String(Math.floor(Math.random() * 24) + 1).padStart(2, "0");
      subtitleOptions.push(`S${s}E${e}`);

      const suffixes = ["New.", "Repeat.", "Live.", "Season premiere.", "Series finale.", ""];

      programs.push({
        id: programId++,
        start_time: current.toISOString(),
        end_time: end.toISOString(),
        title: showName,
        sub_title: Math.random() > 0.3 ? `S${s}E${e}` : null,
        description: `A ${episodeGenre.toLowerCase()} program on ${ch.name}. ${pick(suffixes)}`,
        tvg_id: ch.tvg_id,
        channel: ch.id,
      });

      current = end;
    }
  }
  return programs;
}

function generateEdgeCases() {
  const now = new Date();
  const baseId = 9_000_000;

  return [
    // Zero-duration program (start == end)
    {
      id: baseId + 1,
      start_time: now.toISOString(),
      end_time: now.toISOString(),
      title: "EDGE: Zero Duration",
      sub_title: null,
      description: "This program has zero duration (start == end).",
      tvg_id: "ch1.mock",
      channel: 1,
    },
    // Very long program (48 hours)
    {
      id: baseId + 2,
      start_time: new Date(now.getTime() - 24 * 3600000).toISOString(),
      end_time: new Date(now.getTime() + 24 * 3600000).toISOString(),
      title: "EDGE: 48 Hour Marathon",
      sub_title: null,
      description: "This program spans 48 hours.",
      tvg_id: "ch2.mock",
      channel: 2,
    },
    // End before start (corrupt data)
    {
      id: baseId + 3,
      start_time: new Date(now.getTime() + 3600000).toISOString(),
      end_time: new Date(now.getTime() - 3600000).toISOString(),
      title: "EDGE: End Before Start",
      sub_title: null,
      description: "This program has end < start (corrupt).",
      tvg_id: "ch3.mock",
      channel: 3,
    },
    // String ID (non-numeric)
    {
      id: "not-a-number",
      start_time: now.toISOString(),
      end_time: new Date(now.getTime() + 3600000).toISOString(),
      title: "EDGE: String ID",
      sub_title: null,
      description: "This program has a non-numeric string ID.",
      tvg_id: "ch4.mock",
      channel: 4,
    },
    // Very long title
    {
      id: baseId + 5,
      start_time: now.toISOString(),
      end_time: new Date(now.getTime() + 1800000).toISOString(),
      title: "EDGE: " + "Very Long Title ".repeat(50),
      sub_title: "Subtitle ".repeat(20),
      description: "Description ".repeat(200),
      tvg_id: "ch5.mock",
      channel: 5,
    },
    // 1-minute program
    {
      id: baseId + 6,
      start_time: now.toISOString(),
      end_time: new Date(now.getTime() + 60000).toISOString(),
      title: "EDGE: 1 Min",
      sub_title: null,
      description: "Extremely short program.",
      tvg_id: "ch6.mock",
      channel: 6,
    },
    // Unicode/emoji in title
    {
      id: baseId + 8,
      start_time: now.toISOString(),
      end_time: new Date(now.getTime() + 3600000).toISOString(),
      title: "EDGE: Unicode \u26bd\ufe0f Fussball \u00c9mission Sp\u00e9ciale \ud83c\udde8\ud83c\udde6",
      sub_title: "\u65e5\u672c\u8a9e\u30bf\u30a4\u30c8\u30eb",
      description: "\u4e2d\u6587\u63cf\u8ff0 \u2022 \ud83c\udfac Movie night \u2022 Caf\u00e9",
      tvg_id: "ch8.mock",
      channel: 8,
    },
    // Numeric string ID (common Dispatcharr quirk)
    {
      id: "99999",
      start_time: now.toISOString(),
      end_time: new Date(now.getTime() + 3600000).toISOString(),
      title: "EDGE: Numeric String ID",
      sub_title: null,
      description: "This program has id as string '99999' instead of int.",
      tvg_id: "ch9.mock",
      channel: 9,
    },
    // Channel as string
    {
      id: baseId + 10,
      start_time: now.toISOString(),
      end_time: new Date(now.getTime() + 3600000).toISOString(),
      title: "EDGE: String Channel ID",
      sub_title: null,
      description: "This program has channel as string '10' instead of int.",
      tvg_id: "ch10.mock",
      channel: "10",
    },
  ];
}

// ---------------------------------------------------------------------------
// PNG generation (no dependencies)
// ---------------------------------------------------------------------------

function generateIconPNG(channelId) {
  // Generate a 64x64 solid color PNG with channel number
  // Using a minimal valid PNG with IHDR + IDAT + IEND
  const zlib = require("zlib");
  const size = 64;

  // Deterministic color from channel ID
  const hue = (channelId * 137) % 360;
  const [r, g, b] = hslToRgb(hue / 360, 0.5, 0.35);

  // Build raw image data (filter byte + RGB pixels per row)
  const rawData = Buffer.alloc((1 + size * 3) * size);
  for (let y = 0; y < size; y++) {
    const rowOffset = y * (1 + size * 3);
    rawData[rowOffset] = 0; // filter: none
    for (let x = 0; x < size; x++) {
      const px = rowOffset + 1 + x * 3;
      rawData[px] = r;
      rawData[px + 1] = g;
      rawData[px + 2] = b;
    }
  }

  const compressed = zlib.deflateSync(rawData);

  // Assemble PNG
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
  ihdrData[8] = 8; // bit depth
  ihdrData[9] = 2; // color type: RGB
  ihdrData[10] = 0; // compression
  ihdrData[11] = 0; // filter
  ihdrData[12] = 0; // interlace

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
// Pagination
// ---------------------------------------------------------------------------

function paginate(items, page, baseUrl, pageSize = PAGE_SIZE) {
  const total = items.length;
  const start = (page - 1) * pageSize;
  const end = start + pageSize;
  const pageItems = items.slice(start, end);

  const params = pageSize !== PAGE_SIZE ? `page_size=${pageSize}&` : "";
  return {
    count: total,
    next: end < total ? `${baseUrl}?${params}page=${page + 1}` : null,
    previous: page > 1 ? `${baseUrl}?${params}page=${page - 1}` : null,
    results: pageItems,
  };
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

function handleRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;
  const page = parseInt(url.searchParams.get("page") || "1", 10);
  const pageSize = parseInt(url.searchParams.get("page_size") || String(PAGE_SIZE), 10);

  // CORS headers for testing
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type, Accept");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, PUT, PATCH");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  // Auth
  if (path === "/api/accounts/token/" && req.method === "POST") {
    return json(res, {
      access: "mock-access-" + crypto.randomUUID().slice(0, 16),
      refresh: "mock-refresh-" + crypto.randomUUID().slice(0, 16),
    });
  }

  if (path === "/api/accounts/token/refresh/" && req.method === "POST") {
    return json(res, {
      access: "mock-access-" + crypto.randomUUID().slice(0, 16),
    });
  }

  // Channels
  if (path === "/api/channels/channels/") {
    const baseUrl = `http://${req.headers.host}${path}`;
    return json(res, paginate(CHANNELS, page, baseUrl, pageSize));
  }

  // EPG data lookup
  const epgDataMatch = path.match(/^\/api\/epg\/epgdata\/(\d+)\/$/);
  if (epgDataMatch) {
    const id = parseInt(epgDataMatch[1], 10);
    const ch = CHANNELS.find((c) => c.id === id);
    if (!ch) return notFound(res);
    return json(res, { id, tvg_id: ch.tvg_id });
  }

  // EPG grid — matches real Dispatcharr: returns programs from -1h to +24h, non-paginated
  if (path === "/api/epg/grid/") {
    const now = Date.now();
    const oneHourAgo = now - 60 * 60 * 1000;
    const twentyFourHoursLater = now + 24 * 60 * 60 * 1000;
    const allPrograms = [...PROGRAMS, ...EDGE_CASES];
    const filtered = allPrograms.filter((p) => {
      const end = new Date(p.end_time).getTime();
      const start = new Date(p.start_time).getTime();
      return end > oneHourAgo && start < twentyFourHoursLater;
    });
    return json(res, { data: filtered });
  }

  // Recordings
  if (path === "/api/channels/recordings/") {
    return json(res, { count: 0, next: null, previous: null, results: [] });
  }

  // Channel icon
  const logoMatch = path.match(/^\/api\/channels\/logos\/(\d+)\/cache\/$/);
  if (logoMatch) {
    const logoId = parseInt(logoMatch[1], 10);
    const png = generateIconPNG(logoId);
    res.writeHead(200, {
      "Content-Type": "image/png",
      "Content-Length": png.length,
      "Cache-Control": "public, max-age=86400",
    });
    res.end(png);
    return;
  }

  // Stream (mock)
  if (path.startsWith("/proxy/ts/stream/")) {
    return json(res, { detail: "Mock server does not provide streams." }, 404);
  }

  // Proxy status
  if (path === "/proxy/ts/status") {
    return json(res, { count: 0, channels: [] });
  }

  notFound(res);
}

function json(res, data, status = 200) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

function notFound(res) {
  json(res, { detail: "Not found." }, 404);
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
    } else if (argv[i] === "--no-edge-cases") {
      result.noEdgeCases = true;
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
const PROGRAMS = generateEPG(CHANNELS);

const EDGE_CASES = args.noEdgeCases ? [] : generateEdgeCases();
if (EDGE_CASES.length > 0) {
  console.log(`Added ${EDGE_CASES.length} edge case programs on channels 1-10`);
}

const server = http.createServer((req, res) => {
  // Collect body for POST requests
  if (req.method === "POST") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      try { req.body = JSON.parse(body); } catch { req.body = {}; }
      handleRequest(req, res);
    });
  } else {
    handleRequest(req, res);
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`\nMock Dispatcharr server running on http://0.0.0.0:${PORT}`);
  console.log(`  Channels:  ${CHANNELS.length}`);
  console.log(`  Programs:  ${PROGRAMS.length + EDGE_CASES.length}`);
  console.log(`  Pages:     ${Math.ceil((PROGRAMS.length + EDGE_CASES.length) / PAGE_SIZE)}`);
  console.log(`  Auth:      any username/password accepted`);
  console.log();
});
