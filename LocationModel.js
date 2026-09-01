// Pure location policy for QML and Node. This module performs no I/O.

var LOCATION_SCHEMA_VERSION = 1;
var AUTO_CONSENT_VERSION = 1;
var AUTO_STALE_MS = 24 * 60 * 60 * 1000;
var AUTO_JUMP_KM = 250;
var MODES = { "none": true, "weather": true, "manual": true, "auto-ip": true };
var TOKEN_KINDS = { "search": true, "save": true, "auto": true, "weather": true, "location": true };
var PAIRS = {
    "weather/selected-locality": true,
    "manual-search/selected-locality": true,
    "manual-coordinates/coordinates": true,
    "auto-ip/approximate-city": true
};
var DECIMAL = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/;
var MAX_SAFE_INTEGER = 9007199254740991;

function own(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
}

function enumValue(values, value) {
    return typeof value === "string" && own(values, value) && values[value] === true;
}

function objectValue(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function ownValue(object, key) {
    return objectValue(object) && own(object, key) ? object[key] : undefined;
}

function ownsAll(object, keys) {
    if (!objectValue(object))
        return false;
    for (var i = 0; i < keys.length; i += 1) {
        if (!own(object, keys[i]))
            return false;
    }
    return true;
}

function finiteNumber(value) {
    return typeof value === "number" && isFinite(value);
}

function nonNegativeInteger(value) {
    return finiteNumber(value) && Math.floor(value) === value && value >= 0 && value <= MAX_SAFE_INTEGER;
}

function incrementCounter(value) {
    return nonNegativeInteger(value) && value < MAX_SAFE_INTEGER ? value + 1 : null;
}

function dateEpoch(value) {
    if (!finiteNumber(value))
        return null;
    var date = new Date(value);
    return finiteNumber(date.getTime()) ? value : null;
}

function coordinatesValid(latitude, longitude) {
    return finiteNumber(latitude) && finiteNumber(longitude) &&
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180;
}

function frozen(value) {
    if (value && typeof value === "object" && typeof Object.freeze === "function") {
        var keys = Object.keys(value);
        for (var i = 0; i < keys.length; i += 1)
            frozen(value[keys[i]]);
        Object.freeze(value);
    }
    return value;
}

function codePointLength(value) {
    var length = 0;
    for (var i = 0; i < value.length; i += 1) {
        var first = value.charCodeAt(i);
        if (first >= 0xD800 && first <= 0xDBFF && i + 1 < value.length) {
            var second = value.charCodeAt(i + 1);
            if (second >= 0xDC00 && second <= 0xDFFF)
                i += 1;
        }
        length += 1;
    }
    return length;
}

function capCodePoints(value, maximum) {
    if (codePointLength(value) <= maximum)
        return value;
    var count = 0;
    var end = 0;
    while (end < value.length && count < maximum) {
        var first = value.charCodeAt(end);
        end += 1;
        if (first >= 0xD800 && first <= 0xDBFF && end < value.length) {
            var second = value.charCodeAt(end);
            if (second >= 0xDC00 && second <= 0xDFFF)
                end += 1;
        }
        count += 1;
    }
    return value.slice(0, end);
}

function canonicalText(value, maximum) {
    if (typeof value !== "string")
        return null;
    return capCodePoints(value.trim(), maximum);
}

function timestampMs(value) {
    // UTC is explicit. Date.parse's permissive, host-dependent forms are not accepted.
    var match = typeof value === "string" &&
        /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$/.exec(value);
    if (!match)
        return null;
    var milliseconds = match[7] ? Number((match[7] + "000").slice(0, 3)) : 0;
    var epoch = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]),
                         Number(match[4]), Number(match[5]), Number(match[6]), milliseconds);
    var date = new Date(epoch);
    if (!finiteNumber(epoch) || date.getUTCFullYear() !== Number(match[1]) ||
            date.getUTCMonth() !== Number(match[2]) - 1 || date.getUTCDate() !== Number(match[3]) ||
            date.getUTCHours() !== Number(match[4]) || date.getUTCMinutes() !== Number(match[5]) ||
            date.getUTCSeconds() !== Number(match[6]))
        return null;
    return epoch;
}

function canonicalTimestamp(value) {
    var epoch = timestampMs(value);
    if (epoch === null)
        return null;
    var result = new Date(epoch).toISOString();
    return result.slice(-5) === ".000Z" ? result.slice(0, -5) + "Z" : result;
}

function timestampFrom(value) {
    if (finiteNumber(value)) {
        if (dateEpoch(value) === null)
            return null;
        return canonicalTimestamp(new Date(value).toISOString());
    }
    return canonicalTimestamp(value);
}

function errorResult(outcome, code, message) {
    return frozen({ outcome: outcome, ok: false, error: { code: code, message: message } });
}

function canonicalLocation(record, expectedSource) {
    var keys = ["label", "admin1", "country", "latitude", "longitude", "timezone", "source", "precision", "observedAt"];
    if (!ownsAll(record, keys))
        return errorResult("malformed", "location-invalid", "Location data is malformed.");

    var source = ownValue(record, "source");
    var precision = ownValue(record, "precision");
    var latitude = ownValue(record, "latitude");
    var longitude = ownValue(record, "longitude");
    if (typeof source !== "string" || typeof precision !== "string" || !enumValue(PAIRS, source + "/" + precision))
        return errorResult("malformed", "source-invalid", "Location source is invalid.");
    if (typeof expectedSource !== "undefined" && (typeof expectedSource !== "string" || source !== expectedSource))
        return errorResult("malformed", "source-invalid", "Location source does not match its cache.");
    if (!coordinatesValid(latitude, longitude))
        return errorResult("malformed", "coordinates-invalid", "Location coordinates are invalid.");

    var label = canonicalText(ownValue(record, "label"), 120);
    var admin1 = canonicalText(ownValue(record, "admin1"), 80);
    var country = canonicalText(ownValue(record, "country"), 80);
    var timezone = canonicalText(ownValue(record, "timezone"), 80);
    var observedAt = canonicalTimestamp(ownValue(record, "observedAt"));
    if (label === null || admin1 === null || country === null || timezone === null || observedAt === null)
        return errorResult("malformed", "location-fields-invalid", "Location metadata is invalid.");

    return frozen({
        outcome: "valid",
        ok: true,
        location: {
            label: label,
            admin1: admin1,
            country: country,
            latitude: latitude,
            longitude: longitude,
            timezone: timezone,
            source: source,
            precision: precision,
            observedAt: observedAt
        }
    });
}

function decodeJson(payload) {
    if (typeof payload !== "string")
        return { ok: true, value: payload };
    try {
        return { ok: true, value: JSON.parse(payload) };
    } catch (exception) {
        return { ok: false };
    }
}

function parsePrivateState(payload) {
    if (payload === null || typeof payload === "undefined")
        return frozen({ outcome: "absent", ok: false, state: null, error: null });
    var decoded = decodeJson(payload);
    if (!decoded.ok || !objectValue(decoded.value))
        return errorResult("malformed", "state-malformed", "Location state is malformed.");
    var raw = decoded.value;
    var stateKeys = ["schemaVersion", "revision", "mode", "autoConsentVersion", "manual", "weatherCache", "autoIpCache"];
    if (!ownsAll(raw, stateKeys) || !nonNegativeInteger(ownValue(raw, "schemaVersion")))
        return errorResult("malformed", "state-malformed", "Location state is malformed.");
    var schemaVersion = ownValue(raw, "schemaVersion");
    var revision = ownValue(raw, "revision");
    var mode = ownValue(raw, "mode");
    var autoConsentVersion = ownValue(raw, "autoConsentVersion");
    var rawManual = ownValue(raw, "manual");
    var rawWeather = ownValue(raw, "weatherCache");
    var rawAutoIp = ownValue(raw, "autoIpCache");
    if (schemaVersion !== LOCATION_SCHEMA_VERSION)
        return errorResult("unsupported-schema", "state-unsupported-schema", "Location state uses an unsupported schema.");
    if (!nonNegativeInteger(revision) || !enumValue(MODES, mode) ||
            !nonNegativeInteger(autoConsentVersion) || autoConsentVersion > AUTO_CONSENT_VERSION)
        return errorResult("malformed", "state-malformed", "Location state is malformed.");
    if ((rawManual !== null && !objectValue(rawManual)) || (rawWeather !== null && !objectValue(rawWeather)) ||
            (rawAutoIp !== null && !objectValue(rawAutoIp)))
        return errorResult("malformed", "state-malformed", "Location state is malformed.");

    var manual = null;
    var weather = null;
    var autoIp = null;
    var parsed;
    if (rawManual !== null) {
        parsed = canonicalLocation(rawManual);
        if (!parsed.ok || (parsed.location.source !== "manual-search" && parsed.location.source !== "manual-coordinates"))
            return errorResult("malformed", "state-malformed", "Manual location state is malformed.");
        manual = parsed.location;
    }
    if (rawWeather !== null) {
        parsed = canonicalLocation(rawWeather, "weather");
        if (!parsed.ok)
            return errorResult("malformed", "state-malformed", "Weather cache is malformed.");
        weather = parsed.location;
    }
    if (rawAutoIp !== null) {
        parsed = canonicalLocation(rawAutoIp, "auto-ip");
        if (!parsed.ok)
            return errorResult("malformed", "state-malformed", "Automatic location cache is malformed.");
        autoIp = parsed.location;
    }

    return frozen({
        outcome: "valid",
        ok: true,
        state: {
            schemaVersion: LOCATION_SCHEMA_VERSION,
            revision: revision,
            mode: mode,
            autoConsentVersion: autoConsentVersion,
            manual: manual,
            weatherCache: weather,
            autoIpCache: autoIp
        },
        error: null
    });
}

function classifyPrivateStateRead(readOutcome, payload) {
    if (readOutcome === "absent")
        return frozen({ outcome: "absent", ok: false, state: null, error: null });
    if (readOutcome === "temporarily-unavailable")
        return errorResult("temporarily-unavailable", "state-temporarily-unavailable", "Location state is temporarily unavailable.");
    if (readOutcome !== "data" && readOutcome !== "valid")
        return errorResult("malformed", "state-malformed", "Location state read outcome is invalid.");
    return parsePrivateState(payload);
}

function canonicalState(raw) {
    var result = parsePrivateState(raw);
    return result.ok ? result.state : null;
}

function makeState(revision, mode, autoConsentVersion, manual, weatherCache, autoIpCache) {
    return parsePrivateState({
        schemaVersion: LOCATION_SCHEMA_VERSION,
        revision: revision,
        mode: mode,
        autoConsentVersion: autoConsentVersion,
        manual: manual === undefined ? null : manual,
        weatherCache: weatherCache === undefined ? null : weatherCache,
        autoIpCache: autoIpCache === undefined ? null : autoIpCache
    });
}

function revisionDecision(currentRevision, incoming) {
    if (!nonNegativeInteger(currentRevision))
        return errorResult("malformed", "revision-invalid", "Current location revision is invalid.");
    var parsed = parsePrivateState(incoming);
    if (!parsed.ok)
        return parsed;
    if (parsed.state.revision === currentRevision)
        return frozen({ outcome: "echo", ok: true, apply: false, state: parsed.state });
    if (parsed.state.revision < currentRevision)
        return frozen({ outcome: "stale", ok: true, apply: false, state: parsed.state });
    return frozen({ outcome: "newer", ok: true, apply: true, state: parsed.state });
}

function nextState(previous, changes) {
    var parsed = parsePrivateState(previous);
    if (!parsed.ok)
        return parsed;
    if (!objectValue(changes))
        return errorResult("malformed", "state-malformed", "State transaction is malformed.");
    var old = parsed.state;
    var candidate = {
        schemaVersion: LOCATION_SCHEMA_VERSION,
        revision: old.revision + 1,
        mode: own(changes, "mode") ? changes.mode : old.mode,
        autoConsentVersion: own(changes, "autoConsentVersion") ? changes.autoConsentVersion : old.autoConsentVersion,
        manual: own(changes, "manual") ? changes.manual : old.manual,
        weatherCache: own(changes, "weatherCache") ? changes.weatherCache : old.weatherCache,
        autoIpCache: own(changes, "autoIpCache") ? changes.autoIpCache : old.autoIpCache
    };
    return parsePrivateState(candidate);
}

function parseWeather(payload, observedAt) {
    if (payload === null || typeof payload === "undefined")
        return frozen({ outcome: "absent", ok: false, location: null, error: null });
    var decoded = decodeJson(payload);
    if (!decoded.ok || !objectValue(decoded.value))
        return errorResult("malformed", "weather-malformed", "Weather location is malformed.");
    var raw = decoded.value;
    var latitude = ownValue(raw, "latitude");
    var longitude = ownValue(raw, "longitude");
    if (!own(raw, "latitude") || !own(raw, "longitude") || !coordinatesValid(latitude, longitude))
        return errorResult("malformed", "weather-malformed", "Weather location is malformed.");
    var name = ownValue(raw, "name");
    var fallbackLabel = ownValue(raw, "label");
    var admin1 = ownValue(raw, "admin1");
    var country = ownValue(raw, "country");
    var timezone = ownValue(raw, "timezone");
    var when = timestampFrom(observedAt);
    if (when === null)
        return errorResult("malformed", "weather-observation-invalid", "Weather observation time is invalid.");
    var location = canonicalLocation({
        label: typeof name === "string" && name.trim() ? name :
            (typeof fallbackLabel === "string" && fallbackLabel.trim() ? fallbackLabel : "Weather location"),
        admin1: typeof admin1 === "string" ? admin1 : "",
        country: typeof country === "string" ? country : "",
        latitude: latitude,
        longitude: longitude,
        timezone: typeof timezone === "string" ? timezone : "",
        source: "weather",
        precision: "selected-locality",
        observedAt: when
    }, "weather");
    if (!location.ok)
        return errorResult("malformed", "weather-malformed", "Weather location is malformed.");
    return frozen({ outcome: "valid", ok: true, location: location.location, error: null });
}

function classifyWeatherRead(readOutcome, payload, observedAt) {
    if (readOutcome === "absent")
        return frozen({ outcome: "absent", ok: false, location: null, error: null });
    if (readOutcome === "temporarily-unavailable")
        return errorResult("temporarily-unavailable", "weather-temporarily-unavailable", "Weather location is temporarily unavailable.");
    if (readOutcome !== "data" && readOutcome !== "valid")
        return errorResult("malformed", "weather-malformed", "Weather read outcome is invalid.");
    return parseWeather(payload, observedAt);
}

function normalizeQuery(value) {
    return typeof value === "string" ? value.trim().replace(/\s+/g, " ") : "";
}

function parseDirectCoordinates(value) {
    if (typeof value !== "string")
        return errorResult("invalid", "coordinates-invalid", "Enter latitude and longitude as decimal numbers.");
    var text = value.trim();
    var parts = text.split(",");
    if (parts.length !== 2 || !DECIMAL.test(parts[0].trim()) || !DECIMAL.test(parts[1].trim()))
        return errorResult("invalid", "coordinates-invalid", "Enter latitude and longitude as decimal numbers.");
    var latitude = Number(parts[0].trim());
    var longitude = Number(parts[1].trim());
    if (!coordinatesValid(latitude, longitude))
        return errorResult("invalid", "coordinates-out-of-range", "Latitude or longitude is out of range.");
    return frozen({ outcome: "coordinates", ok: true, latitude: latitude, longitude: longitude, normalized: latitude + ", " + longitude });
}

function looksCoordinateLike(text) {
    if (text.indexOf(",") < 0)
        return false;
    var parts = text.split(",");
    if (parts.length !== 2)
        return parts.some(function (part) { return /[0-9]/.test(part); });
    return parts[0].trim() === "" || parts[1].trim() === "" ||
        /[0-9]/.test(parts[0]) || /[0-9]/.test(parts[1]);
}

function classifyManualInput(value) {
    var query = normalizeQuery(value);
    if (!query)
        return frozen({ outcome: "empty", ok: false, committable: false, searchable: false });
    var coordinates = parseDirectCoordinates(query);
    if (coordinates.ok) {
        var observedAt = "1970-01-01T00:00:00Z"; // Replaced by the caller when the user commits.
        var location = canonicalLocation({
            label: "Coordinates", admin1: "", country: "",
            latitude: coordinates.latitude, longitude: coordinates.longitude, timezone: "",
            source: "manual-coordinates", precision: "coordinates", observedAt: observedAt
        });
        return frozen({
            outcome: "coordinates", ok: true, committable: true, searchable: false,
            latitude: coordinates.latitude, longitude: coordinates.longitude,
            normalized: coordinates.normalized, location: location.location
        });
    }
    if (looksCoordinateLike(query))
        return frozen({ outcome: "invalid-coordinates", ok: false, committable: false, searchable: false, error: coordinates.error });
    if (query.replace(/\s/g, "").length < 3)
        return frozen({ outcome: "query-too-short", ok: false, committable: false, searchable: false });
    return frozen({ outcome: "query", ok: true, committable: false, searchable: true, query: query });
}

function manualCoordinateLocation(input, observedAt) {
    var parsed = parseDirectCoordinates(input);
    if (!parsed.ok)
        return parsed;
    var when = timestampFrom(observedAt);
    if (when === null)
        return errorResult("invalid", "location-time-invalid", "Location observation time is invalid.");
    var result = canonicalLocation({
        label: "Coordinates", admin1: "", country: "",
        latitude: parsed.latitude, longitude: parsed.longitude, timezone: "",
        source: "manual-coordinates", precision: "coordinates", observedAt: when
    });
    return result.ok ? frozen({ outcome: "valid", ok: true, location: result.location }) : result;
}

function parseProviderNumber(value) {
    if (finiteNumber(value))
        return value;
    if (typeof value === "string" && DECIMAL.test(value.trim()))
        return Number(value.trim());
    return null;
}

function parseGeocodingResponse(payload, observedAt) {
    var decoded = decodeJson(payload);
    if (!decoded.ok || !objectValue(decoded.value))
        return errorResult("malformed", "provider-malformed", "The location provider returned invalid data.");
    var hasResults = own(decoded.value, "results");
    var results = hasResults ? ownValue(decoded.value, "results") : [];
    if (!Array.isArray(results))
        return errorResult("malformed", "provider-malformed", "The location provider returned invalid data.");
    var when = timestampFrom(observedAt);
    if (when === null)
        return errorResult("malformed", "provider-malformed", "The location provider returned invalid data.");
    // Open-Meteo legitimately omits `results` when there are no matches.
    var candidates = [];
    var invalidRows = 0;
    for (var i = 0; i < results.length && candidates.length < 5; i += 1) {
        var row = own(results, String(i)) ? results[i] : null;
        var latitude = objectValue(row) && own(row, "latitude") ? parseProviderNumber(ownValue(row, "latitude")) : null;
        var longitude = objectValue(row) && own(row, "longitude") ? parseProviderNumber(ownValue(row, "longitude")) : null;
        var name = objectValue(row) && own(row, "name") ? canonicalText(ownValue(row, "name"), 120) : null;
        if (!objectValue(row) || !name || !coordinatesValid(latitude, longitude)) {
            invalidRows += 1;
            continue;
        }
        var rowAdmin1 = ownValue(row, "admin1");
        var rowCountry = ownValue(row, "country");
        var rowTimezone = ownValue(row, "timezone");
        var result = canonicalLocation({
            label: name,
            admin1: typeof rowAdmin1 === "string" ? rowAdmin1 : "",
            country: typeof rowCountry === "string" ? rowCountry : "",
            latitude: latitude,
            longitude: longitude,
            timezone: typeof rowTimezone === "string" ? rowTimezone : "",
            source: "manual-search",
            precision: "selected-locality",
            observedAt: when
        });
        if (result.ok) {
            candidates.push(frozen({
                location: result.location,
                displayLabel: [result.location.label, result.location.admin1, result.location.country].filter(function (part) { return part !== ""; }).join(" · ")
            }));
        } else {
            invalidRows += 1;
        }
    }
    if (results.length > 0 && candidates.length === 0 && invalidRows > 0)
        return errorResult("malformed", "provider-malformed", "The location provider returned invalid data.");
    if (candidates.length === 0)
        return frozen({ outcome: "no-results", ok: true, candidates: [], error: null });
    return frozen({ outcome: "results", ok: true, candidates: candidates, error: null });
}

function wttrValue(value) {
    if (typeof value === "string")
        return value;
    if (Array.isArray(value) && value.length > 0 && own(value, "0") && objectValue(value[0]) &&
            own(value[0], "value") && typeof ownValue(value[0], "value") === "string")
        return ownValue(value[0], "value");
    return "";
}

function parseAutoIpResponse(payload, observedAt) {
    var decoded = decodeJson(payload);
    var root = decoded.ok ? decoded.value : null;
    var nearest = objectValue(root) && own(root, "nearest_area") ? ownValue(root, "nearest_area") : null;
    var area = Array.isArray(nearest) && nearest.length > 0 && own(nearest, "0") ? nearest[0] : null;
    if (!objectValue(area) || !ownsAll(area, ["latitude", "longitude", "areaName"]))
        return errorResult("malformed", "provider-malformed", "The location provider returned invalid data.");
    var latitude = parseProviderNumber(ownValue(area, "latitude"));
    var longitude = parseProviderNumber(ownValue(area, "longitude"));
    var label = canonicalText(wttrValue(ownValue(area, "areaName")), 120);
    var when = timestampFrom(observedAt);
    if (!label || !coordinatesValid(latitude, longitude) || when === null)
        return errorResult("malformed", "provider-malformed", "The location provider returned invalid data.");
    var result = canonicalLocation({
        label: label,
        admin1: wttrValue(ownValue(area, "region")),
        country: wttrValue(ownValue(area, "country")),
        latitude: latitude,
        longitude: longitude,
        timezone: "",
        source: "auto-ip",
        precision: "approximate-city",
        observedAt: when
    }, "auto-ip");
    if (!result.ok)
        return errorResult("malformed", "provider-malformed", "The location provider returned invalid data.");
    return frozen({ outcome: "candidate", ok: true, candidate: result.location, requiresAcceptance: true, error: null });
}

function classifyProviderResult(kind, transport, observedAt) {
    if (!objectValue(transport) || !own(transport, "outcome") || typeof ownValue(transport, "outcome") !== "string")
        return errorResult("provider-error", "provider-error", "The location provider did not respond.");
    var outcome = ownValue(transport, "outcome");
    var hasStatus = own(transport, "status");
    var status = ownValue(transport, "status");
    if (hasStatus && (!nonNegativeInteger(status) || status > 599))
        return errorResult("provider-error", "provider-error", "The location provider request failed.");
    if (outcome === "canceled")
        return frozen({ outcome: "canceled", ok: false, error: null });
    if (outcome === "timeout" || outcome === "offline")
        return errorResult("offline", "offline", "The location provider is unavailable.");
    if (outcome === "rate-limited" || status === 429)
        return errorResult("rate-limited", "rate-limited", "The location provider is temporarily rate limited.");
    if (outcome !== "data" && outcome !== "valid")
        return errorResult("provider-error", "provider-error", "The location provider request failed.");
    if (!own(transport, "body"))
        return errorResult("provider-error", "provider-error", "The location provider request failed.");
    if (kind === "geocode")
        return parseGeocodingResponse(ownValue(transport, "body"), observedAt);
    if (kind === "auto-ip")
        return parseAutoIpResponse(ownValue(transport, "body"), observedAt);
    return errorResult("provider-error", "provider-error", "The location provider is not allowed.");
}

function locationAge(location, nowMs) {
    var parsed = canonicalLocation(location);
    if (!parsed.ok || dateEpoch(nowMs) === null)
        return null;
    var observed = timestampMs(parsed.location.observedAt);
    return observed === null ? null : Math.max(0, nowMs - observed);
}

function formatAge(ageMs) {
    if (!finiteNumber(ageMs) || ageMs < 0)
        return "unknown age";
    if (ageMs < 60000)
        return "just now";
    if (ageMs < 60 * 60000)
        return Math.floor(ageMs / 60000) + " min ago";
    if (ageMs < 48 * 60 * 60000)
        return Math.floor(ageMs / (60 * 60000)) + " hr ago";
    return Math.floor(ageMs / (24 * 60 * 60000)) + " days ago";
}

function freshness(location, nowMs, options) {
    var parsed = canonicalLocation(location);
    if (!parsed.ok || dateEpoch(nowMs) === null)
        return errorResult("invalid", "location-invalid", "Location data is invalid.");
    if (typeof options !== "undefined" && !objectValue(options))
        return errorResult("invalid", "options-invalid", "Freshness options are invalid.");
    if (objectValue(options) && own(options, "lastKnown") && typeof ownValue(options, "lastKnown") !== "boolean")
        return errorResult("invalid", "options-invalid", "Freshness options are invalid.");
    var item = parsed.location;
    var ageMs = locationAge(item, nowMs);
    var fallback = objectValue(options) && ownValue(options, "lastKnown") === true;
    var stale = item.source === "auto-ip" && ageMs > AUTO_STALE_MS;
    if (item.source === "weather" && fallback)
        stale = true;
    var sourceLabel;
    if (fallback || stale)
        sourceLabel = "Last known · " + formatAge(ageMs);
    else if (item.source === "weather")
        sourceLabel = "Weather";
    else if (item.source === "manual-search")
        sourceLabel = "Manual";
    else if (item.source === "manual-coordinates")
        sourceLabel = "Coordinates";
    else
        sourceLabel = "Approximate";
    return frozen({ outcome: "valid", ok: true, stale: stale, ageMs: ageMs, sourceLabel: sourceLabel });
}

function coordinatePair(value) {
    if (!ownsAll(value, ["latitude", "longitude"]))
        return null;
    var latitude = ownValue(value, "latitude");
    var longitude = ownValue(value, "longitude");
    if (!coordinatesValid(latitude, longitude))
        return null;
    return { latitude: latitude, longitude: longitude };
}

function distanceKm(first, second) {
    first = coordinatePair(first);
    second = coordinatePair(second);
    if (!first || !second)
        return null;
    var radians = Math.PI / 180;
    var lat1 = first.latitude * radians;
    var lat2 = second.latitude * radians;
    var dLat = (second.latitude - first.latitude) * radians;
    var dLon = (second.longitude - first.longitude) * radians;
    var sinLat = Math.sin(dLat / 2);
    var sinLon = Math.sin(dLon / 2);
    var a = sinLat * sinLat + Math.cos(lat1) * Math.cos(lat2) * sinLon * sinLon;
    a = Math.max(0, Math.min(1, a));
    return 6371.0088 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function assessAutoCandidate(acceptedCache, candidate) {
    var candidateParsed = canonicalLocation(candidate, "auto-ip");
    if (!candidateParsed.ok)
        return errorResult("invalid", "candidate-invalid", "Approximate location candidate is invalid.");
    if (acceptedCache === null || typeof acceptedCache === "undefined")
        return frozen({ outcome: "first-use", ok: true, distanceKm: null, changed: false, requiresAcceptance: true, mayInstallAutomatically: false });
    var acceptedParsed = canonicalLocation(acceptedCache, "auto-ip");
    if (!acceptedParsed.ok)
        return errorResult("invalid", "cache-invalid", "Approximate location cache is invalid.");
    var km = distanceKm(acceptedParsed.location, candidateParsed.location);
    var changed = km > AUTO_JUMP_KM;
    return frozen({
        outcome: changed ? "large-jump" : "refresh",
        ok: true,
        distanceKm: km,
        changed: changed,
        requiresAcceptance: changed,
        mayInstallAutomatically: !changed
    });
}

function weatherLocationFromRead(weatherRead) {
    if (!objectValue(weatherRead) || !own(weatherRead, "outcome") || !own(weatherRead, "ok") ||
            !own(weatherRead, "location") || ownValue(weatherRead, "outcome") !== "valid" || ownValue(weatherRead, "ok") !== true)
        return null;
    var parsed = canonicalLocation(ownValue(weatherRead, "location"), "weather");
    return parsed.ok ? parsed.location : null;
}

function weatherCacheEqual(first, second) {
    var left = canonicalLocation(first, "weather");
    var right = canonicalLocation(second, "weather");
    if (!left.ok || !right.ok)
        return false;
    // observedAt describes this particular read, not a change in Weather's
    // selected locality. Rewriting private state for that value alone would
    // make every shell start depend on writable storage.
    var keys = ["label", "admin1", "country", "latitude", "longitude", "timezone", "source", "precision"];
    for (var i = 0; i < keys.length; i += 1) {
        if (left.location[keys[i]] !== right.location[keys[i]])
            return false;
    }
    return true;
}

function selectedLocation(state, weatherRead, nowMs) {
    var parsed = parsePrivateState(state);
    if (!parsed.ok)
        return parsed;
    var item = parsed.state;
    if (item.mode === "none")
        return errorResult("unavailable", "location-unavailable", "Choose a location.");
    if (item.mode === "weather") {
        var currentWeather = weatherLocationFromRead(weatherRead);
        if (currentWeather)
            return frozen({ outcome: "current", ok: true, location: currentWeather, lastKnown: false,
                shouldRefreshCache: !item.weatherCache || !weatherCacheEqual(item.weatherCache, currentWeather), networkAllowed: false });
        if (item.weatherCache)
            return frozen({ outcome: "last-known", ok: true, location: item.weatherCache, lastKnown: true, shouldRefreshCache: false, networkAllowed: false,
                freshness: freshness(item.weatherCache, nowMs, { lastKnown: true }) });
        return errorResult("unavailable", "location-unavailable", "Weather location is unavailable.");
    }
    if (item.mode === "manual") {
        if (item.manual)
            return frozen({ outcome: "current", ok: true, location: item.manual, lastKnown: false, shouldRefreshCache: false, networkAllowed: false });
        return errorResult("unavailable", "location-unavailable", "Manual location is unavailable.");
    }
    if (item.mode === "auto-ip") {
        if (item.autoIpCache)
            return frozen({ outcome: "current", ok: true, location: item.autoIpCache, lastKnown: false, shouldRefreshCache: false, networkAllowed: item.autoConsentVersion === AUTO_CONSENT_VERSION,
                freshness: freshness(item.autoIpCache, nowMs, {}) });
        return errorResult("unavailable", "location-unavailable", "Approximate location is unavailable.");
    }
    return errorResult("malformed", "state-malformed", "Location state is malformed.");
}

function bootstrapFailure(result) {
    var failure = objectValue(result) ? result : null;
    var outcome = ownValue(failure, "outcome");
    var error = ownValue(failure, "error");
    if (typeof outcome !== "string" || outcome === "absent") {
        failure = errorResult("malformed", "state-malformed", "Location state is malformed.");
        outcome = failure.outcome;
        error = failure.error;
    }
    return frozen({ outcome: outcome, ok: false, state: null, location: null,
        shouldPersist: false, networkAllowed: false, error: objectValue(error) ? error : null });
}

function bootstrap(privateRead, weatherRead, nowMs) {
    if (privateRead === null || typeof privateRead === "undefined" ||
            (objectValue(privateRead) && own(privateRead, "outcome") && ownValue(privateRead, "outcome") === "absent")) {
        var initialWeather = weatherLocationFromRead(weatherRead);
        if (initialWeather) {
            var made = makeState(0, "weather", 0, null, initialWeather, null);
            if (!made.ok)
                return bootstrapFailure(made);
            return frozen({ outcome: "bootstrap-weather", ok: true, state: made.state,
                location: made.state.weatherCache, shouldPersist: true, networkAllowed: false });
        }
        return frozen({ outcome: "setup", ok: true, state: null, location: null, shouldPersist: false, networkAllowed: false });
    }
    if (!objectValue(privateRead))
        return bootstrapFailure(errorResult("malformed", "state-malformed", "Location state is malformed."));
    if (!own(privateRead, "outcome") || !own(privateRead, "ok") ||
            ownValue(privateRead, "outcome") !== "valid" || ownValue(privateRead, "ok") !== true) {
        if (ownValue(privateRead, "outcome") === "temporarily-unavailable")
            return bootstrapFailure(errorResult("temporarily-unavailable", "state-temporarily-unavailable", "Location state is temporarily unavailable."));
        if (ownValue(privateRead, "outcome") === "unsupported-schema")
            return bootstrapFailure(errorResult("unsupported-schema", "state-unsupported-schema", "Location state uses an unsupported schema."));
        return bootstrapFailure(errorResult("malformed", "state-malformed", "Location state is malformed."));
    }
    if (!own(privateRead, "state"))
        return bootstrapFailure(errorResult("malformed", "state-malformed", "Location state is malformed."));
    var parsed = parsePrivateState(ownValue(privateRead, "state"));
    if (!parsed.ok)
        return bootstrapFailure(parsed);
    var selected = selectedLocation(parsed.state, weatherRead, nowMs);
    return frozen({ outcome: selected.outcome, ok: selected.ok, state: parsed.state,
        location: selected.ok ? selected.location : null, shouldPersist: selected.ok && selected.shouldRefreshCache,
        networkAllowed: selected.ok ? selected.networkAllowed : false, error: selected.error || null });
}

function networkDecision(kind, context) {
    if (kind === "geocode") {
        var typedSearch = objectValue(context) && ownsAll(context, ["query", "editorOpen", "userChanged"]) &&
            typeof ownValue(context, "query") === "string" && typeof ownValue(context, "editorOpen") === "boolean" &&
            typeof ownValue(context, "userChanged") === "boolean";
        var input = classifyManualInput(typedSearch ? ownValue(context, "query") : "");
        var legal = typedSearch && ownValue(context, "editorOpen") === true && ownValue(context, "userChanged") === true &&
            input.outcome === "query";
        return frozen({ legal: legal, reason: legal ? null : "manual-search-not-authorized", normalizedQuery: input.query || "" });
    }
    if (kind === "auto-ip") {
        var typedBase = objectValue(context) && ownsAll(context, ["autoConsentVersion", "mode", "hasCache"]) &&
            nonNegativeInteger(ownValue(context, "autoConsentVersion")) &&
            typeof ownValue(context, "mode") === "string" && enumValue(MODES, ownValue(context, "mode")) &&
            typeof ownValue(context, "hasCache") === "boolean";
        var optionalKeys = ["userRequestedRetry", "cacheStale", "sessionRefreshUsed"];
        var typedOptional = true;
        for (var i = 0; objectValue(context) && i < optionalKeys.length; i += 1) {
            if (own(context, optionalKeys[i]) && typeof ownValue(context, optionalKeys[i]) !== "boolean")
                typedOptional = false;
        }
        var consented = typedBase && ownValue(context, "autoConsentVersion") === AUTO_CONSENT_VERSION;
        var correctMode = typedBase && ownValue(context, "mode") === "auto-ip";
        var retry = typedOptional && ownValue(context, "userRequestedRetry") === true;
        var first = typedBase && ownValue(context, "hasCache") === false;
        var staleRefresh = typedBase && ownValue(context, "hasCache") === true &&
            ownValue(context, "cacheStale") === true && own(context, "sessionRefreshUsed") &&
            ownValue(context, "sessionRefreshUsed") === false;
        var legalAuto = typedOptional && consented && correctMode && (first || retry || staleRefresh);
        return frozen({ legal: legalAuto, reason: legalAuto ? null : (consented ? "automatic-request-not-due" : "consent-required") });
    }
    return frozen({ legal: false, reason: "provider-not-allowed" });
}

function generationState(locationEpoch, searchEpoch, saveEpoch, mode, query, editorOpen, revision) {
    if (!nonNegativeInteger(locationEpoch) || !nonNegativeInteger(searchEpoch) ||
            !nonNegativeInteger(saveEpoch) || !nonNegativeInteger(revision) || !enumValue(MODES, mode) ||
            typeof query !== "string" || typeof editorOpen !== "boolean")
        return null;
    return frozen({
        locationEpoch: locationEpoch,
        searchEpoch: searchEpoch,
        saveEpoch: saveEpoch,
        mode: mode,
        query: normalizeQuery(query),
        editorOpen: editorOpen,
        revision: revision
    });
}

function generationContext(state) {
    var keys = ["locationEpoch", "searchEpoch", "saveEpoch", "mode", "query", "editorOpen", "revision"];
    if (!ownsAll(state, keys))
        return null;
    return generationState(ownValue(state, "locationEpoch"), ownValue(state, "searchEpoch"),
                           ownValue(state, "saveEpoch"), ownValue(state, "mode"), ownValue(state, "query"),
                           ownValue(state, "editorOpen"), ownValue(state, "revision"));
}

function canonicalToken(token) {
    if (!objectValue(token) || !own(token, "kind") || !enumValue(TOKEN_KINDS, ownValue(token, "kind")))
        return null;
    var base = generationContext(token);
    if (!base || ownValue(token, "query") !== base.query)
        return null;
    return {
        kind: ownValue(token, "kind"),
        locationEpoch: base.locationEpoch,
        searchEpoch: base.searchEpoch,
        saveEpoch: base.saveEpoch,
        mode: base.mode,
        query: base.query,
        editorOpen: base.editorOpen,
        revision: base.revision
    };
}

function captureGeneration(kind, state) {
    if (!enumValue(TOKEN_KINDS, kind))
        return null;
    var base = generationContext(state);
    if (!base)
        return null;
    return frozen({
        kind: kind,
        locationEpoch: base.locationEpoch,
        searchEpoch: base.searchEpoch,
        saveEpoch: base.saveEpoch,
        mode: base.mode,
        query: base.query,
        editorOpen: base.editorOpen,
        revision: base.revision
    });
}

function generationMatches(token, current) {
    var checkedToken = canonicalToken(token);
    var normalized = generationContext(current);
    if (!checkedToken || !normalized || checkedToken.locationEpoch !== normalized.locationEpoch ||
            checkedToken.mode !== normalized.mode)
        return false;
    if (checkedToken.kind === "search")
        return checkedToken.searchEpoch === normalized.searchEpoch && checkedToken.query === normalized.query && normalized.editorOpen;
    if (checkedToken.kind === "save")
        return checkedToken.saveEpoch === normalized.saveEpoch && checkedToken.revision === normalized.revision;
    if (checkedToken.kind === "auto")
        return checkedToken.mode === "auto-ip";
    if (checkedToken.kind === "weather")
        return checkedToken.mode === "weather" && checkedToken.revision === normalized.revision;
    if (checkedToken.kind === "location")
        return true;
    return false;
}

function guardedProviderResult(kind, token, current, transport, observedAt) {
    var expectedKind = kind === "geocode" ? "search" : (kind === "auto-ip" ? "auto" : "");
    if (!expectedKind || ownValue(token, "kind") !== expectedKind || !generationMatches(token, current))
        return frozen({ outcome: "stale", ok: false, publish: false, error: null });
    var result = classifyProviderResult(kind, transport, observedAt);
    return frozen({ outcome: result.outcome, ok: result.ok, publish: result.outcome !== "canceled", result: result, error: result.error || null });
}

function advanceGeneration(state, change) {
    if (!objectValue(change))
        return null;
    var base = generationContext(state);
    if (!base)
        return null;
    var booleanChanges = ["locationChanged", "queryChanged", "saveStarted"];
    for (var i = 0; i < booleanChanges.length; i += 1) {
        if (own(change, booleanChanges[i]) && typeof ownValue(change, booleanChanges[i]) !== "boolean")
            return null;
    }
    var locationEpoch = base.locationEpoch;
    var searchEpoch = base.searchEpoch;
    var saveEpoch = base.saveEpoch;
    var mode = own(change, "mode") ? ownValue(change, "mode") : base.mode;
    var query = own(change, "query") ? ownValue(change, "query") : base.query;
    var editorOpen = own(change, "editorOpen") ? ownValue(change, "editorOpen") : base.editorOpen;
    var revision = own(change, "revision") ? ownValue(change, "revision") : base.revision;
    if (!enumValue(MODES, mode) || typeof query !== "string" || typeof editorOpen !== "boolean" ||
            !nonNegativeInteger(revision))
        return null;
    if (ownValue(change, "locationChanged") === true || mode !== base.mode) {
        locationEpoch = incrementCounter(locationEpoch);
        searchEpoch = incrementCounter(searchEpoch);
        saveEpoch = incrementCounter(saveEpoch);
        if (locationEpoch === null || searchEpoch === null || saveEpoch === null)
            return null;
    } else {
        if (ownValue(change, "queryChanged") === true || normalizeQuery(query) !== base.query || editorOpen !== base.editorOpen) {
            searchEpoch = incrementCounter(searchEpoch);
            if (searchEpoch === null)
                return null;
        }
        if (ownValue(change, "saveStarted") === true) {
            saveEpoch = incrementCounter(saveEpoch);
            if (saveEpoch === null)
                return null;
        }
    }
    return generationState(locationEpoch, searchEpoch, saveEpoch, mode, query, editorOpen, revision);
}

var api = {
    LOCATION_SCHEMA_VERSION: LOCATION_SCHEMA_VERSION,
    AUTO_CONSENT_VERSION: AUTO_CONSENT_VERSION,
    AUTO_STALE_MS: AUTO_STALE_MS,
    AUTO_JUMP_KM: AUTO_JUMP_KM,
    coordinatesValid: coordinatesValid,
    canonicalLocation: canonicalLocation,
    parsePrivateState: parsePrivateState,
    classifyPrivateStateRead: classifyPrivateStateRead,
    canonicalState: canonicalState,
    makeState: makeState,
    revisionDecision: revisionDecision,
    nextState: nextState,
    parseWeather: parseWeather,
    classifyWeatherRead: classifyWeatherRead,
    normalizeQuery: normalizeQuery,
    parseDirectCoordinates: parseDirectCoordinates,
    classifyManualInput: classifyManualInput,
    manualCoordinateLocation: manualCoordinateLocation,
    parseGeocodingResponse: parseGeocodingResponse,
    parseAutoIpResponse: parseAutoIpResponse,
    classifyProviderResult: classifyProviderResult,
    locationAge: locationAge,
    formatAge: formatAge,
    freshness: freshness,
    distanceKm: distanceKm,
    assessAutoCandidate: assessAutoCandidate,
    weatherCacheEqual: weatherCacheEqual,
    selectedLocation: selectedLocation,
    bootstrap: bootstrap,
    networkDecision: networkDecision,
    generationState: generationState,
    captureGeneration: captureGeneration,
    generationMatches: generationMatches,
    guardedProviderResult: guardedProviderResult,
    advanceGeneration: advanceGeneration
};

if (typeof module !== "undefined" && module.exports)
    module.exports = api;
