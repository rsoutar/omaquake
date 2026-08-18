const test = require("node:test")
const assert = require("node:assert/strict")

const Model = require("../Model.js")

function feature(id, mag, lon, lat, extras) {
  extras = extras || {}
  return {
    type: "Feature",
    id: id,
    properties: {
      mag: mag,
      magType: "mw",
      place: extras.place || "29 km SW of Balangonan, Philippines",
      time: extras.time == null ? 1_700_000_000_000 : extras.time,
      url: extras.url || ("https://earthquake.usgs.gov/earthquakes/eventpage/" + id),
      tsunami: extras.tsunami || 0,
      felt: extras.felt
    },
    geometry: {
      type: "Point",
      coordinates: [lon, lat, extras.depth == null ? 18 : extras.depth]
    }
  }
}

function feed(features) {
  return JSON.stringify({
    type: "FeatureCollection",
    metadata: { generated: 1_700_000_100_000, count: features.length },
    features: features
  })
}

test("parseFeed keeps valid events and drops missing mag or coordinates", () => {
  const parsed = Model.parseFeed(feed([
    feature("us1", 5.2, 121.0, 14.5),
    feature("bad-mag", null, 121.0, 14.5),
    { type: "Feature", id: "no-geom", properties: { mag: 4, time: 1 }, geometry: { coordinates: [] } },
    feature("us2", 4.1, -73, 45, { place: "Quebec" })
  ]))

  assert.equal(parsed.ok, true)
  assert.deepEqual(parsed.events.map(event => event.id), ["us1", "us2"])
  assert.equal(parsed.events[0].depthKm, 18)
  assert.equal(parsed.events[0].lat, 14.5)
  assert.equal(parsed.events[0].lon, 121.0)
})

test("parseFeed rejects unreadable payloads", () => {
  assert.equal(Model.parseFeed("not json").ok, false)
  assert.equal(Model.parseFeed("").ok, false)
})

test("haversine of one degree of latitude is about 111 km", () => {
  const km = Model.haversineKm(0, 0, 1, 0)
  assert.ok(Math.abs(km - 111.195) < 0.05)
})

test("filterEvents applies magnitude and local range", () => {
  const events = Model.parseFeed(feed([
    feature("near", 3.1, 0.2, 0.2),
    feature("far", 5.0, 20, 20),
    feature("tiny", 1.8, 0.1, 0.1)
  ])).events

  const local = Model.filterEvents(events, {
    latitude: 0,
    longitude: 0,
    rangeKm: 100,
    minMagnitude: 2.5,
    scope: "local"
  })
  assert.deepEqual(local.map(event => event.id), ["near"])
  assert.equal(local[0].inRange, true)
  assert.ok(local[0].distanceKm < 50)

  const global = Model.filterEvents(events, {
    latitude: 0,
    longitude: 0,
    rangeKm: 100,
    minMagnitude: 2.5,
    scope: "global"
  })
  assert.deepEqual(global.map(event => event.id).sort(), ["far", "near"])
})

test("mergeEvents dedupes by id and keeps the newer copy", () => {
  const first = Model.parseFeature(feature("us1", 4.0, 1, 1, { time: 100 }))
  const newer = Model.parseFeature(feature("us1", 4.4, 1, 1, { time: 200 }))
  const other = Model.parseFeature(feature("us2", 5.0, 2, 2, { time: 150 }))
  const merged = Model.mergeEvents([first], [newer, other])
  assert.deepEqual(merged.map(event => event.id), ["us1", "us2"])
  assert.equal(merged[0].mag, 4.4)
})

test("distance and time formatters cover km, miles, and relative time", () => {
  assert.equal(Model.formatDistance(142.2, false), "142 km")
  assert.equal(Model.formatDistance(1.6, true), "1.0 mi")
  assert.equal(Model.formatDepth(18, false), "18 km deep")
  assert.equal(Model.formatTimeAgo(1_000, 1_000), "just now")
  assert.equal(Model.formatTimeAgo(0, 3 * 60 * 1000), "3 minutes ago")
  assert.equal(Model.formatTimeAgo(0, 2 * 60 * 60 * 1000), "2 hours ago")
  assert.equal(Model.formatTimeAgo(0, 26 * 60 * 60 * 1000), "1 day ago")
})

test("magnitude roles and hero pick the strongest recent event", () => {
  assert.equal(Model.magnitudeRole(3.2), "muted")
  assert.equal(Model.magnitudeRole(5.1), "accent")
  assert.equal(Model.magnitudeRole(6.4), "urgent")

  const events = Model.filterEvents(Model.parseFeed(feed([
    feature("small-new", 3.0, 0, 0, { time: 300 }),
    feature("big-old", 6.2, 0, 0, { time: 100 }),
    feature("mid", 5.0, 0, 0, { time: 200 })
  ])).events, { minMagnitude: 2.5, scope: "global" })

  assert.equal(Model.heroEvent(events).id, "big-old")
  assert.equal(Model.latestEvent(events).id, "small-new")
  assert.deepEqual(Model.listEvents(events, Model.heroEvent(events)).map(event => event.id), ["small-new", "mid"])
})

test("alertCandidates skip seen, stale, and out-of-range events", () => {
  const now = 1_000_000
  const fresh = Model.decorateEvent(Model.parseFeature(feature("a", 6.4, 0.1, 0.1, { time: now - 60_000 })), 0, 0, 1000)
  const stale = Model.decorateEvent(Model.parseFeature(feature("b", 7.0, 0.1, 0.1, { time: now - Model.ALERT_WINDOW_MS - 1 })), 0, 0, 1000)
  const far = Model.decorateEvent(Model.parseFeature(feature("c", 6.8, 20, 20, { time: now - 60_000 })), 0, 0, 100)
  const seen = Model.seedSeenIds([fresh])

  assert.deepEqual(Model.alertCandidates([fresh, stale, far], {}, {
    alertMagnitude: 6,
    nowMs: now,
    requireInRange: true
  }).map(event => event.id), ["a"])

  assert.deepEqual(Model.alertCandidates([fresh], seen, {
    alertMagnitude: 6,
    nowMs: now,
    requireInRange: true
  }), [])

  assert.equal(Model.activeAlert([fresh], 6, now).id, "a")
  assert.equal(Model.activeAlert([stale], 6, now), null)
})

test("notification and bar labels share magnitude formatting", () => {
  const event = Model.parseFeature(feature("us1", 6.4, 121, 14.5, { time: 0, depth: 18 }))
  const decorated = Model.decorateEvent(event, 14.5, 121, 1000)
  const text = Model.notificationText(decorated, false, 3 * 60 * 1000)
  assert.equal(text.headline, "M6.4 — 29 km SW of Balangonan, Philippines")
  assert.match(text.body, /3 minutes ago/)
  assert.match(text.body, /18 km deep/)
  assert.equal(Model.barLabel(event, false), Model.QUAKE_GLYPH + " 6.4")
  assert.equal(Model.barLabel(null, false), Model.QUAKE_GLYPH + " —")
  assert.equal(Model.barLabel(event, true), Model.QUAKE_GLYPH)
})

test("eventPageUrl restricts URLs to the exact HTTPS USGS origin", () => {
  const event = Model.parseFeature(feature("us1", 6.4, 121, 14.5, {
    url: "https://earthquake.usgs.gov/earthquakes/eventpage/us1"
  }))
  assert.equal(Model.eventPageUrl(event), "https://earthquake.usgs.gov/earthquakes/eventpage/us1")

  const offOrigin = [
    "http://earthquake.usgs.gov/earthquakes/eventpage/us1",
    "https://evil.example.com/earthquakes/eventpage/us1",
    "https://earthquake.usgs.gov.evil.com/x",
    "https://earthquake.usgs.gov@evil.com/x",
    "javascript:alert(1)",
    "https://www.earthquake.usgs.gov/x"
  ]
  for (const url of offOrigin) {
    assert.equal(Model.eventPageUrl(Model.parseFeature(feature("us2", 4.0, 0, 0, { url }))), "")
  }
  assert.equal(Model.eventPageUrl(null), "")
  assert.equal(Model.eventPageUrl({ url: "" }), "")
})

test("shellQuote wraps values so bash treats them as one literal argument", () => {
  const { execFileSync } = require("node:child_process")

  assert.equal(Model.shellQuote("plain"), "'plain'")
  assert.equal(Model.shellQuote("https://earthquake.usgs.gov/earthquakes/eventpage/us1"),
    "'https://earthquake.usgs.gov/earthquakes/eventpage/us1'")

  const url = "https://earthquake.usgs.gov/x'; rm -rf ~; echo '"
  const quoted = Model.shellQuote(url)
  const argv = execFileSync("bash", ["-lc", "printf '%s\\n' " + quoted]).toString().trim()
  assert.equal(argv, url)

  const plain = execFileSync("bash", ["-lc", "printf '%s\\n' " + Model.shellQuote("https://earthquake.usgs.gov/earthquakes/eventpage/us1")]).toString().trim()
  assert.equal(plain, "https://earthquake.usgs.gov/earthquakes/eventpage/us1")
})

test("feedUrls use FDSN for local range and static GeoJSON for global", () => {
  const local = Model.feedUrls({
    scope: "local",
    latitude: 14.5,
    longitude: 121,
    rangeKm: 500,
    minMagnitude: 2.5,
    nowMs: Date.parse("2026-08-15T12:00:00Z")
  })
  assert.equal(local.length, 1)
  assert.match(local[0], /fdsnws\/event\/1\/query/)
  assert.match(local[0], /latitude=14.5/)
  assert.match(local[0], /maxradiuskm=500/)
  assert.match(local[0], /minmagnitude=2.5/)

  assert.deepEqual(Model.feedUrls({ scope: "global", minMagnitude: 4.5 }), [
    "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson"
  ])
  assert.deepEqual(Model.feedUrls({ scope: "global", minMagnitude: 2.5 }), [
    "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson"
  ])
  assert.match(Model.feedUrls({ scope: "global", minMagnitude: 1.0 })[0], /fdsnws/)
})

test("location parsers accept lat/lon text, geojs, and geocode rows", () => {
  assert.deepEqual(Model.parseLatLonText("14.6, 121.0"), {
    name: "14.60, 121.00",
    latitude: 14.6,
    longitude: 121
  })
  assert.equal(Model.parseLatLonText("Manila"), null)

  const geo = Model.parseGeoJs(JSON.stringify({
    latitude: "43.65",
    longitude: "-79.38",
    city: "Toronto",
    region: "Ontario"
  }))
  assert.equal(geo.latitude, 43.65)
  assert.equal(geo.name, "Toronto, Ontario")

  const suggestions = Model.parseGeocodingResults(JSON.stringify({
    results: [{ name: "Manila", latitude: 14.6, longitude: 121, country: "Philippines", admin1: "NCR" }]
  }))
  assert.equal(suggestions[0].description, "NCR, Philippines")
  assert.equal(Model.locationCommit("Manila", suggestions, 0).name, "Manila")
  assert.equal(Model.locationCommit("not a place", [], 0), null)
})

test("shouldUseImperial follows override then locale", () => {
  assert.equal(Model.shouldUseImperial("mi", "en_GB"), true)
  assert.equal(Model.shouldUseImperial("km", "en_US"), false)
  assert.equal(Model.shouldUseImperial("auto", "en_US"), true)
  assert.equal(Model.shouldUseImperial("auto", "en_GB"), false)
})

test("parseHttpResponse splits status, headers, and body", () => {
  const raw = "HTTP/1.1 200 OK\r\nExpires: Thu, 01 Jan 2030 00:00:00 GMT\r\nCache-Control: public, max-age=60\r\n\r\n{\"a\":1}"
  const http = Model.parseHttpResponse(raw)
  assert.equal(http.status, 200)
  assert.equal(http.headers["expires"], "Thu, 01 Jan 2030 00:00:00 GMT")
  assert.match(http.headers["cache-control"], /max-age=60/)
  assert.equal(http.body, "{\"a\":1}")

  const err = Model.parseHttpResponse("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 30\r\n\r\n")
  assert.equal(err.status, 429)
  assert.equal(Model.retryAfterMs(err.headers, 1_700_000_000_000), 30000)

  const blank = Model.parseHttpResponse("")
  assert.equal(blank.status, 0)
  assert.deepEqual(blank.headers, {})
})

test("expiresAtMs prefers Expires then Cache-Control max-age", () => {
  const now = Date.parse("2026-08-15T12:00:00Z")
  const headers = { expires: "Sat, 15 Aug 2026 12:01:00 GMT" }
  assert.equal(Model.expiresAtMs(headers, now), now + 60000)
  assert.equal(Model.expiresAtMs({ "cache-control": "public, max-age=30" }, now), now + 30000)
  assert.equal(Model.expiresAtMs({}, now), 0)
})

test("fdsnUrl uses updatedafter for incremental polls", () => {
  const now = Date.parse("2026-08-15T12:00:00Z")
  const first = Model.fdsnUrl({ minMagnitude: 2.5, nowMs: now })
  assert.match(first, /starttime=/)
  assert.doesNotMatch(first, /updatedafter=/)

  const later = Model.fdsnUrl({ minMagnitude: 2.5, updatedAfter: now + 120000 })
  assert.match(later, /updatedafter=2026-08-15T12%3A02%3A00Z/)
  assert.doesNotMatch(later, /starttime=/)
})

test("mergeFeed keeps prior events, prefers revisions, and prunes old ones", () => {
  const now = Date.parse("2026-08-15T12:00:00Z")
  const rev = { id: "a", mag: 6.2, timeMs: now - 3600000 }
  const prev = [
    { id: "a", mag: 5.9, timeMs: now - 3600000 },
    { id: "b", mag: 4.1, timeMs: now - 7200000 }
  ]
  const incoming = [rev, { id: "c", mag: 3.8, timeMs: now - 600000 }]
  const merged = Model.mergeFeed(prev, incoming, now)
  assert.equal(merged.length, 3)
  assert.equal(merged.find((e) => e.id === "a").mag, 6.2)

  const old = { id: "z", mag: 2.0, timeMs: now - DAY_MS - 1000 }
  assert.equal(Model.mergeFeed(prev, [old], now).find((e) => e.id === "z"), undefined)
})

test("isoFromMs treats null and 0 as no previous poll", () => {
  assert.equal(Model.isoFromMs(null), null)
  assert.equal(Model.isoFromMs(undefined), null)
  assert.equal(Model.isoFromMs(0), null)
  assert.equal(Model.isoFromMs(""), null)
  assert.equal(Model.isoFromMs("nonsense"), null)
  assert.equal(Model.isoFromMs(Date.parse("2026-08-15T12:00:00Z")), "2026-08-15T12:00:00Z")
})

test("a poll with no prior timestamp asks for the day window, not all of history", () => {
  const now = Date.parse("2026-08-15T12:00:00Z")
  for (const empty of [null, undefined, 0]) {
    const url = Model.fdsnUrl({ minMagnitude: 2.5, nowMs: now, updatedAfter: empty })
    assert.match(url, /starttime=2026-08-14T12%3A00%3A00Z/)
    assert.doesNotMatch(url, /updatedafter=/)
    assert.doesNotMatch(url, /1970/)
  }
})

const DAY_MS = 24 * 60 * 60 * 1000

