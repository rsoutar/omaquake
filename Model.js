var EARTH_RADIUS_KM = 6371.0
var KM_PER_MILE = 1.609344
var ALERT_WINDOW_MS = 30 * 60 * 1000
var ALERT_SOUND = "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga"
var DAY_MS = 24 * 60 * 60 * 1000
var QUAKE_GLYPH = String.fromCodePoint(0xE3BE)
var USGS_FEED = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/"
var USGS_FDSN = "https://earthquake.usgs.gov/fdsnws/event/1/query"

function clampNumber(value, min, max, fallback) {
  var parsed = parseFloat(value)
  if (!isFinite(parsed)) return fallback
  if (parsed < min) return min
  if (parsed > max) return max
  return parsed
}

function parseNumber(value) {
  if (value === undefined || value === null || value === "") return null
  var parsed = parseFloat(value)
  return isFinite(parsed) ? parsed : null
}

function hasCoordinates(lat, lon) {
  var latitude = parseNumber(lat)
  var longitude = parseNumber(lon)
  return latitude !== null && longitude !== null
    && latitude >= -90 && latitude <= 90
    && longitude >= -180 && longitude <= 180
}

function normalizeScope(value) {
  return String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase() === "global"
    ? "global" : "local"
}

function normalizeUnits(value) {
  var unit = String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (unit === "km" || unit === "metric") return "km"
  if (unit === "mi" || unit === "imperial") return "mi"
  return "auto"
}

function booleanValue(value, fallback) {
  if (value === undefined || value === null) return fallback === true
  if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
  return value !== false
}

function localeUsesImperial(localeName) {
  var name = String(localeName || "").replace(".", "_")
  return /^en[_-]US($|[_.-])/.test(name) || /^en[_-]LR($|[_.-])/.test(name) || /^my($|[_.-])/.test(name)
}

function shouldUseImperial(unitOverride, localeName) {
  var unit = normalizeUnits(unitOverride)
  if (unit === "mi") return true
  if (unit === "km") return false
  return localeUsesImperial(localeName)
}

function toRad(deg) {
  return deg * Math.PI / 180
}

function haversineKm(lat1, lon1, lat2, lon2) {
  var dLat = toRad(lat2 - lat1)
  var dLon = toRad(lon2 - lon1)
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
    + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2))
    * Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return 2 * EARTH_RADIUS_KM * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

function startTimeIso(nowMs) {
  var d = new Date((nowMs || Date.now()) - DAY_MS)
  return d.toISOString().replace(/\.\d{3}Z$/, "Z")
}

// Null when there is no meaningful timestamp. `Number(null)` is 0 and 0 is
// finite, so a bare isFinite check turned "no previous poll" into the epoch
// and sent `updatedafter=1970-01-01T00:00:00Z` — asking USGS for every event
// on record instead of the intended day window. 0 is treated the same way:
// callers use it to mean "never polled".
function isoFromMs(ms) {
  if (ms === undefined || ms === null || ms === "") return null
  var parsed = Number(ms)
  if (!isFinite(parsed) || parsed <= 0) return null
  return new Date(parsed).toISOString().replace(/\.\d{3}Z$/, "Z")
}

// Split a `curl -i` response (headers then body) into status, headers, body.
function parseHttpResponse(raw) {
  var text = String(raw || "")
  var split = text.indexOf("\r\n\r\n")
  var sep = "\r\n\r\n"
  if (split === -1) {
    split = text.indexOf("\n\n")
    sep = "\n\n"
  }
  if (split === -1) return { status: 0, headers: {}, body: text }
  var headText = text.slice(0, split)
  var body = text.slice(split + sep.length)
  var status = 0
  var headers = {}
  var lines = headText.split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (i === 0 && /^HTTP\//.test(line)) {
      var m = /^\S+\s+(\d+)/.exec(line)
      status = m ? parseInt(m[1], 10) : 0
      continue
    }
    var idx = line.indexOf(":")
    if (idx === -1) continue
    var key = line.slice(0, idx).trim().toLowerCase()
    var val = line.slice(idx + 1).trim()
    headers[key] = headers[key] !== undefined ? headers[key] + ", " + val : val
  }
  return { status: status, headers: headers, body: body }
}

// Earliest moment a follow-up request could include new data (USGS caches
// feed/API responses for 60s), from Expires or Cache-Control: max-age.
function expiresAtMs(headers, nowMs) {
  var now = Number(nowMs) || Date.now()
  headers = headers || {}
  if (headers["expires"]) {
    var t = Date.parse(headers["expires"])
    if (isFinite(t)) return t
  }
  var cc = headers["cache-control"] || ""
  var m = /\bmax-age=(\d+)/.exec(cc)
  if (m) return now + parseInt(m[1], 10) * 1000
  return 0
}

// Backoff suggested by a Retry-After header, in milliseconds (0 = none).
function retryAfterMs(headers, nowMs) {
  var now = Number(nowMs) || Date.now()
  headers = headers || {}
  var ra = headers["retry-after"]
  if (!ra) return 0
  var secs = parseInt(ra, 10)
  if (isFinite(secs) && secs > 0) return secs * 1000
  var t = Date.parse(ra)
  if (isFinite(t) && t > now) return t - now
  return 0
}

function fdsnUrl(options) {
  options = options || {}
  var url = USGS_FDSN
    + "?format=geojson"
    + "&orderby=time"
    + "&limit=50"
    + "&minmagnitude=" + encodeURIComponent(String(clampNumber(options.minMagnitude, 0, 10, 2.5)))
  // Incremental polling: ask only for events updated since the last
  // successful fetch. The first poll has no timestamp, so it uses the
  // past-day window instead.
  var updatedIso = isoFromMs(options.updatedAfter)
  if (updatedIso) url += "&updatedafter=" + encodeURIComponent(updatedIso)
  else url += "&starttime=" + encodeURIComponent(startTimeIso(options.nowMs))
  if (hasCoordinates(options.latitude, options.longitude)) {
    url += "&latitude=" + encodeURIComponent(String(options.latitude))
      + "&longitude=" + encodeURIComponent(String(options.longitude))
      + "&maxradiuskm=" + encodeURIComponent(String(clampNumber(options.rangeKm, 10, 20000, 1000)))
  }
  return url
}

function globalFeedUrl(minMagnitude) {
  return USGS_FEED + (clampNumber(minMagnitude, 0, 10, 2.5) >= 4.5 ? "4.5_day.geojson" : "2.5_day.geojson")
}

function feedUrls(options) {
  options = options || {}
  var minMag = clampNumber(options.minMagnitude, 0, 10, 2.5)
  var scope = normalizeScope(options.scope)
  if (scope === "local" && hasCoordinates(options.latitude, options.longitude)) {
    return [fdsnUrl({
      minMagnitude: minMag,
      latitude: options.latitude,
      longitude: options.longitude,
      rangeKm: options.rangeKm,
      nowMs: options.nowMs,
      updatedAfter: options.updatedAfter
    })]
  }
  if (minMag < 2.5) {
    return [fdsnUrl({ minMagnitude: minMag, nowMs: options.nowMs, updatedAfter: options.updatedAfter })]
  }
  return [globalFeedUrl(minMag)]
}

function parseFeature(feature) {
  if (!feature || typeof feature !== "object") return null
  var props = feature.properties || {}
  var geom = feature.geometry || {}
  var coords = geom.coordinates
  if (!coords || typeof coords.length !== "number" || coords.length < 2) return null

  var lon = parseNumber(coords[0])
  var lat = parseNumber(coords[1])
  var depth = coords.length > 2 ? parseNumber(coords[2]) : null
  var mag = parseNumber(props.mag)
  if (lat === null || lon === null || mag === null) return null
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null

  var time = Number(props.time)
  if (!isFinite(time)) return null

  var id = String(feature.id || props.code || "").replace(/^\s+|\s+$/g, "")
  if (!id) return null

  return {
    id: id,
    mag: mag,
    magType: String(props.magType || "m"),
    place: String(props.place || "Unknown location"),
    timeMs: time,
    lon: lon,
    lat: lat,
    depthKm: depth,
    url: String(props.url || ""),
    tsunami: props.tsunami === 1 || props.tsunami === true,
    felt: props.felt == null ? null : parseNumber(props.felt)
  }
}

function parseFeed(raw) {
  var empty = { ok: false, error: "Unreadable earthquake feed", generated: 0, events: [] }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return empty

    var features = data.features
    if (!features || typeof features.length !== "number") features = []

    var events = []
    for (var i = 0; i < features.length; i++) {
      var parsed = parseFeature(features[i])
      if (parsed) events.push(parsed)
    }

    return {
      ok: true,
      error: "",
      generated: Number(data.metadata && data.metadata.generated) || 0,
      events: events
    }
  } catch (e) {
    return empty
  }
}

function sortEvents(events) {
  var copy = (events || []).slice()
  copy.sort(function(a, b) {
    if (b.timeMs !== a.timeMs) return b.timeMs - a.timeMs
    return b.mag - a.mag
  })
  return copy
}

function mergeEvents(a, b) {
  var byId = {}
  var lists = [a || [], b || []]
  for (var i = 0; i < lists.length; i++) {
    for (var j = 0; j < lists[i].length; j++) {
      var event = lists[i][j]
      if (!event || !event.id) continue
      if (!byId[event.id] || event.timeMs > byId[event.id].timeMs) byId[event.id] = event
    }
  }
  var out = []
  for (var id in byId) out.push(byId[id])
  return sortEvents(out)
}

// Combine the previous event list with an incremental poll result and prune
// to the day window the initial query covers. `incoming` wins for a matching
// id so magnitude/location revisions propagate.
function mergeFeed(prev, incoming, nowMs) {
  var byId = {}
  var i
  for (i = 0; i < (prev || []).length; i++) {
    if (prev[i] && prev[i].id) byId[prev[i].id] = prev[i]
  }
  for (i = 0; i < (incoming || []).length; i++) {
    if (incoming[i] && incoming[i].id) byId[incoming[i].id] = incoming[i]
  }
  var cutoff = (Number(nowMs) || Date.now()) - DAY_MS
  var out = []
  for (var id in byId) {
    if (byId[id].timeMs >= cutoff) out.push(byId[id])
  }
  return sortEvents(out)
}

function decorateEvent(event, latitude, longitude, rangeKm) {
  var copy = {}
  for (var key in event) copy[key] = event[key]
  if (hasCoordinates(latitude, longitude)) {
    copy.distanceKm = haversineKm(latitude, longitude, event.lat, event.lon)
    copy.inRange = copy.distanceKm <= clampNumber(rangeKm, 10, 20000, 1000)
  } else {
    copy.distanceKm = null
    copy.inRange = false
  }
  return copy
}

function filterEvents(events, options) {
  options = options || {}
  var minMag = clampNumber(options.minMagnitude, 0, 10, 2.5)
  var scope = normalizeScope(options.scope)
  var origin = hasCoordinates(options.latitude, options.longitude)
  var rangeKm = clampNumber(options.rangeKm, 10, 20000, 1000)
  var out = []
  var list = events || []
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (!event || event.mag < minMag) continue
    var decorated = decorateEvent(event, options.latitude, options.longitude, rangeKm)
    if (scope === "local" && origin && !decorated.inRange) continue
    out.push(decorated)
  }
  return sortEvents(out)
}

function latestEvent(events) {
  var list = events || []
  return list.length ? list[0] : null
}

function heroEvent(events) {
  var list = events || []
  if (!list.length) return null
  var best = list[0]
  for (var i = 1; i < list.length; i++) {
    if (list[i].mag > best.mag) best = list[i]
    else if (list[i].mag === best.mag && list[i].timeMs > best.timeMs) best = list[i]
  }
  return best
}

function listEvents(events, hero) {
  var list = events || []
  if (!hero) return list
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].id !== hero.id) out.push(list[i])
  }
  return out
}

function formatMagnitude(mag) {
  var n = parseNumber(mag)
  if (n === null) return "—"
  return n.toFixed(1)
}

function formatTimeAgo(timeMs, nowMs) {
  var then = Number(timeMs)
  var now = Number(nowMs)
  if (!isFinite(then) || !isFinite(now)) return ""
  var delta = Math.max(0, now - then)
  if (delta < 60 * 1000) return "just now"
  var minutes = Math.floor(delta / 60000)
  if (minutes < 60) return minutes === 1 ? "1 minute ago" : minutes + " minutes ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours === 1 ? "1 hour ago" : hours + " hours ago"
  var days = Math.floor(hours / 24)
  return days === 1 ? "1 day ago" : days + " days ago"
}

function formatDistance(km, useImperial) {
  var n = parseNumber(km)
  if (n === null) return ""
  if (useImperial) {
    var miles = n / KM_PER_MILE
    if (miles < 10) return miles.toFixed(1) + " mi"
    return Math.round(miles) + " mi"
  }
  if (n < 10) return n.toFixed(1) + " km"
  return Math.round(n) + " km"
}

function formatDepth(km, useImperial) {
  var n = parseNumber(km)
  if (n === null) return ""
  if (useImperial) {
    var miles = n / KM_PER_MILE
    if (miles < 10) return miles.toFixed(1) + " mi deep"
    return Math.round(miles) + " mi deep"
  }
  if (n < 10) return n.toFixed(1) + " km deep"
  return Math.round(n) + " km deep"
}

function cardMeta(event, useImperial, nowMs) {
  if (!event) return ""
  var parts = [formatTimeAgo(event.timeMs, nowMs)]
  var depth = formatDepth(event.depthKm, useImperial)
  if (depth) parts.push(depth)
  var distance = formatDistance(event.distanceKm, useImperial)
  if (distance) parts.push(distance + " away")
  if (event.tsunami) parts.push("tsunami")
  return parts.join(" · ")
}

function magnitudeRole(mag) {
  var n = parseNumber(mag)
  if (n === null || n < 4.5) return "muted"
  if (n < 6) return "accent"
  return "urgent"
}

function isRecentAlert(event, nowMs) {
  if (!event) return false
  return (Number(nowMs) - event.timeMs) <= ALERT_WINDOW_MS
}

function activeAlert(events, alertMagnitude, nowMs) {
  var floor = clampNumber(alertMagnitude, 0, 10, 6)
  var list = events || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].mag >= floor && isRecentAlert(list[i], nowMs)) return list[i]
  }
  return null
}

function seedSeenIds(events) {
  var seen = {}
  var list = events || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id) seen[list[i].id] = true
  }
  return seen
}

function mergeSeen(seenIds, events) {
  var seen = {}
  var key
  for (key in (seenIds || {})) seen[key] = true
  var list = events || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id) seen[list[i].id] = true
  }
  return seen
}

function alertCandidates(events, seenIds, options) {
  options = options || {}
  var floor = clampNumber(options.alertMagnitude, 0, 10, 6)
  var nowMs = options.nowMs || Date.now()
  var seen = seenIds || {}
  var requireInRange = options.requireInRange === true
  var out = []
  var list = events || []
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (!event || seen[event.id]) continue
    if (event.mag < floor) continue
    if (requireInRange && !event.inRange) continue
    if (!isRecentAlert(event, nowMs)) continue
    out.push(event)
  }
  return out
}

function notificationText(event, useImperial, nowMs) {
  if (!event) return { headline: "", body: "" }
  return {
    headline: "M" + formatMagnitude(event.mag) + " — " + event.place,
    body: cardMeta(event, useImperial, nowMs)
  }
}

function statusNotificationText(event, count, useImperial, nowMs) {
  if (!event) return { headline: "No recent earthquakes", body: "" }
  var extra = count > 1 ? count + " events in range" : cardMeta(event, useImperial, nowMs)
  return {
    headline: "M" + formatMagnitude(event.mag) + " — " + event.place,
    body: extra
  }
}

function barLabel(event, vertical) {
  if (vertical) return QUAKE_GLYPH
  if (!event) return QUAKE_GLYPH + " —"
  return QUAKE_GLYPH + " " + formatMagnitude(event.mag)
}

function tooltipText(event, offline) {
  if (offline) return "Earthquake feed offline"
  if (!event) return "No recent earthquakes"
  return "M" + formatMagnitude(event.mag) + " · " + event.place
}

// The notification --exec string runs through bash -lc when clicked, so event
// URLs are restricted to the exact HTTPS USGS origin and callers shell-quote
// them before embedding. Anything else (http, foreign hosts, lookalikes) is
// refused outright.
function eventPageUrl(event) {
  var url = event && event.url ? String(event.url) : ""
  if (!/^https:\/\/earthquake\.usgs\.gov\//.test(url)) return ""
  return url
}

// Wrap a value in single quotes for insertion into a shell command string,
// escaping embedded quotes, so bash treats it as one literal argument.
function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

function mapsUrl(lat, lon) {
  if (!hasCoordinates(lat, lon)) return ""
  return "https://www.openstreetmap.org/?mlat=" + encodeURIComponent(String(lat))
    + "&mlon=" + encodeURIComponent(String(lon))
    + "#map=7/" + encodeURIComponent(String(lat)) + "/" + encodeURIComponent(String(lon))
}

function parseLatLonText(text) {
  var raw = String(text || "").replace(/^\s+|\s+$/g, "")
  var match = raw.match(/^(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)$/)
  if (!match) return null
  var lat = parseFloat(match[1])
  var lon = parseFloat(match[2])
  if (!hasCoordinates(lat, lon)) return null
  return {
    name: lat.toFixed(2) + ", " + lon.toFixed(2),
    latitude: lat,
    longitude: lon
  }
}

function parseGeoJs(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return { error: "Unreadable location response" }
    var lat = parseNumber(data.latitude)
    var lon = parseNumber(data.longitude)
    if (!hasCoordinates(lat, lon)) return { error: "Location response had no coordinates" }
    var city = String(data.city || "").replace(/^\s+|\s+$/g, "")
    var region = String(data.region || data.country || "").replace(/^\s+|\s+$/g, "")
    var name = city || region || (lat.toFixed(2) + ", " + lon.toFixed(2))
    if (city && region && region !== city) name = city + ", " + region
    return { latitude: lat, longitude: lon, name: name, source: "geojs" }
  } catch (e) {
    return { error: "Unreadable location response" }
  }
}

function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []
    var out = []
    for (var i = 0; i < results.length; i++) {
      var row = results[i]
      if (!row || !row.name || row.latitude === undefined || row.longitude === undefined) continue
      var region = [row.admin1, row.country].filter(function(part) { return !!part }).join(", ")
      out.push({
        name: String(row.name),
        description: region,
        latitude: row.latitude,
        longitude: row.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

function locationCommit(text, suggestions, selectedIndex) {
  var coords = parseLatLonText(text)
  if (coords) return coords
  var choices = suggestions || []
  var index = Math.max(0, Math.min(parseInt(selectedIndex, 10) || 0, choices.length - 1))
  return choices[index] || null
}

function locationLabel(name, latitude, longitude, autoName) {
  var label = String(name || "").replace(/^\s+|\s+$/g, "")
  if (label) return label
  if (autoName) return autoName
  if (hasCoordinates(latitude, longitude)) {
    return Number(latitude).toFixed(2) + ", " + Number(longitude).toFixed(2)
  }
  return "Set location"
}

if (typeof module !== "undefined") {
  module.exports = {
    EARTH_RADIUS_KM: EARTH_RADIUS_KM,
    ALERT_WINDOW_MS: ALERT_WINDOW_MS,
    ALERT_SOUND: ALERT_SOUND,
    QUAKE_GLYPH: QUAKE_GLYPH,
    clampNumber: clampNumber,
    parseNumber: parseNumber,
    hasCoordinates: hasCoordinates,
    normalizeScope: normalizeScope,
    normalizeUnits: normalizeUnits,
    booleanValue: booleanValue,
    localeUsesImperial: localeUsesImperial,
    shouldUseImperial: shouldUseImperial,
    haversineKm: haversineKm,
    startTimeIso: startTimeIso,
    fdsnUrl: fdsnUrl,
    globalFeedUrl: globalFeedUrl,
    feedUrls: feedUrls,
    isoFromMs: isoFromMs,
    parseHttpResponse: parseHttpResponse,
    expiresAtMs: expiresAtMs,
    retryAfterMs: retryAfterMs,
    parseFeature: parseFeature,
    parseFeed: parseFeed,
    sortEvents: sortEvents,
    mergeEvents: mergeEvents,
    mergeFeed: mergeFeed,
    decorateEvent: decorateEvent,
    filterEvents: filterEvents,
    latestEvent: latestEvent,
    heroEvent: heroEvent,
    listEvents: listEvents,
    formatMagnitude: formatMagnitude,
    formatTimeAgo: formatTimeAgo,
    formatDistance: formatDistance,
    formatDepth: formatDepth,
    cardMeta: cardMeta,
    magnitudeRole: magnitudeRole,
    isRecentAlert: isRecentAlert,
    activeAlert: activeAlert,
    seedSeenIds: seedSeenIds,
    mergeSeen: mergeSeen,
    alertCandidates: alertCandidates,
    notificationText: notificationText,
    statusNotificationText: statusNotificationText,
    barLabel: barLabel,
    tooltipText: tooltipText,
    eventPageUrl: eventPageUrl,
    shellQuote: shellQuote,
    mapsUrl: mapsUrl,
    parseLatLonText: parseLatLonText,
    parseGeoJs: parseGeoJs,
    parseGeocodingResults: parseGeocodingResults,
    locationCommit: locationCommit,
    locationLabel: locationLabel
  }
}
