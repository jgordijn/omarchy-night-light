'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const L = require('../LocationModel.js');

const NOW = Date.parse('2026-09-01T12:00:00Z');

function location(overrides = {}) {
  return {
    label: 'Hilversumse Meent', admin1: '', country: 'Netherlands',
    latitude: 52.27115, longitude: 5.13729, timezone: 'Europe/Amsterdam',
    source: 'weather', precision: 'selected-locality', observedAt: '2026-09-01T10:00:00Z',
    ...overrides
  };
}

function state(overrides = {}) {
  return {
    schemaVersion: 1, revision: 4, mode: 'weather', autoConsentVersion: 0,
    manual: null, weatherCache: location(), autoIpCache: null,
    ...overrides
  };
}

function weatherRead(overrides = {}) {
  return L.parseWeather({ name: 'Hilversumse Meent', latitude: 52.27115, longitude: 5.13729, ...overrides }, NOW);
}

function autoLocation(overrides = {}) {
  return location({
    label: 'Amsterdam', admin1: 'North Holland', source: 'auto-ip',
    precision: 'approximate-city', observedAt: '2026-09-01T10:00:00Z', ...overrides
  });
}

function generation(overrides = {}) {
  return L.generationState(3, 7, 2, 'manual', 'Utrecht', true, 4) && {
    locationEpoch: 3, searchEpoch: 7, saveEpoch: 2, mode: 'manual',
    query: 'Utrecht', editorOpen: true, revision: 4, ...overrides
  };
}

// Read outcomes and private schema

test('private read outcomes remain distinct', () => {
  assert.equal(L.classifyPrivateStateRead('absent').outcome, 'absent');
  assert.equal(L.classifyPrivateStateRead('temporarily-unavailable').outcome, 'temporarily-unavailable');
  assert.equal(L.classifyPrivateStateRead('data', '{').outcome, 'malformed');
  assert.equal(L.classifyPrivateStateRead('data', JSON.stringify(state({ schemaVersion: 2 }))).outcome, 'unsupported-schema');
  assert.equal(L.classifyPrivateStateRead('data', JSON.stringify(state())).outcome, 'valid');
});

test('unsupported schema is not confused with malformed schema metadata', () => {
  assert.equal(L.parsePrivateState(state({ schemaVersion: 0 })).outcome, 'unsupported-schema');
  assert.equal(L.parsePrivateState(state({ schemaVersion: 1.5 })).outcome, 'malformed');
  assert.equal(L.parsePrivateState(state({ schemaVersion: '1' })).outcome, 'malformed');
  assert.equal(L.parsePrivateState({}).outcome, 'malformed');
});

test('canonical private state has exact keys, strips unknown keys, trims and caps Unicode', () => {
  const long = `  ${'😀'.repeat(121)}  `;
  const raw = state({ junk: 'discard', weatherCache: location({ label: long, extra: 'discard', observedAt: '2026-09-01T10:00:00.000Z' }) });
  const parsed = L.parsePrivateState(raw);
  assert.equal(parsed.ok, true);
  assert.deepEqual(Object.keys(parsed.state), ['schemaVersion', 'revision', 'mode', 'autoConsentVersion', 'manual', 'weatherCache', 'autoIpCache']);
  assert.deepEqual(Object.keys(parsed.state.weatherCache), ['label', 'admin1', 'country', 'latitude', 'longitude', 'timezone', 'source', 'precision', 'observedAt']);
  assert.equal([...parsed.state.weatherCache.label].length, 120);
  assert.equal(parsed.state.weatherCache.observedAt, '2026-09-01T10:00:00Z');
  assert.equal(Object.isFrozen(parsed.state), true);
  assert.equal(Object.isFrozen(parsed.state.weatherCache), true);
});

test('all required state keys and field types are enforced', () => {
  for (const key of ['schemaVersion', 'revision', 'mode', 'autoConsentVersion', 'manual', 'weatherCache', 'autoIpCache']) {
    const raw = state();
    delete raw[key];
    assert.equal(L.parsePrivateState(raw).outcome, 'malformed', key);
  }
  for (const revision of [-1, 1.2, NaN, Infinity, '4'])
    assert.equal(L.parsePrivateState(state({ revision })).outcome, 'malformed');
  for (const mode of ['', 'automatic', 'MANUAL', null])
    assert.equal(L.parsePrivateState(state({ mode })).outcome, 'malformed');
  for (const consent of [-1, 1.5, 2, '1'])
    assert.equal(L.parsePrivateState(state({ autoConsentVersion: consent })).outcome, 'malformed');
});

test('location and private-state schemas never inherit required fields', () => {
  assert.equal(L.canonicalLocation(Object.create(location())).outcome, 'malformed');
  assert.equal(L.parsePrivateState(Object.create(state())).outcome, 'malformed');

  const partialState = { schemaVersion: 1 };
  Object.setPrototypeOf(partialState, state());
  assert.equal(L.parsePrivateState(partialState).outcome, 'malformed');

  const partialLocation = { label: 'own' };
  Object.setPrototypeOf(partialLocation, location());
  assert.equal(L.canonicalLocation(partialLocation).outcome, 'malformed');
});

test('prototype-named modes are malformed from objects and JSON and never authorize auto-IP', () => {
  const inheritedNames = ['toString', 'constructor', '__proto__', 'hasOwnProperty', 'valueOf'];
  for (const mode of inheritedNames) {
    const raw = state({ mode, autoConsentVersion: 1, autoIpCache: autoLocation() });
    for (const payload of [raw, JSON.stringify(raw)]) {
      assert.equal(L.parsePrivateState(payload).outcome, 'malformed', `${mode} parse`);
      const selected = L.selectedLocation(payload, weatherRead(), NOW);
      assert.equal(selected.ok, false, `${mode} selected`);
      assert.notEqual(selected.networkAllowed, true, `${mode} selected authorization`);
      const bootstrapped = L.bootstrap(L.classifyPrivateStateRead('data', payload), weatherRead(), NOW);
      assert.equal(bootstrapped.networkAllowed, false, `${mode} bootstrap authorization`);
    }
    assert.equal(L.networkDecision('auto-ip', {
      mode, autoConsentVersion: 1, hasCache: false
    }).legal, false, `${mode} request authorization`);
    assert.equal(L.generationState(0, 0, 0, mode, '', false, 0), null, `${mode} generation`);
  }
});

test('state counters reject unsafe and JSON-rounded integers and fail closed at saturation', () => {
  const maximum = Number.MAX_SAFE_INTEGER;
  assert.equal(L.parsePrivateState(state({ revision: maximum })).ok, true);
  assert.equal(L.nextState(state({ revision: maximum }), {}).outcome, 'malformed');
  assert.equal(L.parsePrivateState(state({ revision: maximum + 1 })).outcome, 'malformed');
  assert.equal(L.revisionDecision(maximum + 1, state()).outcome, 'malformed');

  const roundedJson = JSON.stringify(state()).replace('"revision":4', '"revision":9007199254740993');
  assert.equal(JSON.parse(roundedJson).revision, 9007199254740992);
  assert.equal(L.parsePrivateState(roundedJson).outcome, 'malformed');
});

test('location schema validates finite numeric ranges and source/precision pairs', () => {
  for (const latitude of [-90, 0, 90]) assert.equal(L.canonicalLocation(location({ latitude })).ok, true);
  for (const longitude of [-180, 0, 180]) assert.equal(L.canonicalLocation(location({ longitude })).ok, true);
  for (const latitude of [-90.001, 90.001, NaN, Infinity, '52'])
    assert.equal(L.canonicalLocation(location({ latitude })).ok, false);
  for (const longitude of [-180.001, 180.001, -Infinity, '5'])
    assert.equal(L.canonicalLocation(location({ longitude })).ok, false);
  const pairs = [
    ['weather', 'selected-locality'], ['manual-search', 'selected-locality'],
    ['manual-coordinates', 'coordinates'], ['auto-ip', 'approximate-city']
  ];
  for (const [source, precision] of pairs)
    assert.equal(L.canonicalLocation(location({ source, precision })).ok, true);
  assert.equal(L.canonicalLocation(location({ source: 'auto-ip', precision: 'coordinates' })).ok, false);
  assert.equal(L.canonicalLocation(location({ source: 'mystery' })).ok, false);
});

test('source/precision enum rejects inherited map entries', () => {
  Object.defineProperty(Object.prototype, 'injected/inherited', {
    value: true, configurable: true
  });
  try {
    assert.equal(L.canonicalLocation(location({
      source: 'injected', precision: 'inherited'
    })).outcome, 'malformed');
  } finally {
    delete Object.prototype['injected/inherited'];
  }
});

test('cache slots reject a valid location with the wrong source', () => {
  assert.equal(L.parsePrivateState(state({ weatherCache: location({ source: 'manual-search' }) })).outcome, 'malformed');
  assert.equal(L.parsePrivateState(state({ manual: location() })).outcome, 'malformed');
  assert.equal(L.parsePrivateState(state({ autoIpCache: location() })).outcome, 'malformed');
  assert.equal(L.parsePrivateState(state({ manual: location({ source: 'manual-coordinates', precision: 'coordinates' }) })).ok, true);
});

test('timestamps must be real UTC ISO-8601 timestamps', () => {
  for (const observedAt of [
    '2026-09-01T10:00:00Z', '2024-02-29T23:59:59.123Z'
  ]) assert.equal(L.canonicalLocation(location({ observedAt })).ok, true, observedAt);
  for (const observedAt of [
    '2026-09-01 10:00:00Z', '2026-09-01T10:00:00+00:00',
    '2026-02-29T10:00:00Z', '2026-13-01T10:00:00Z', 'now', 0, null
  ]) assert.equal(L.canonicalLocation(location({ observedAt })).ok, false, String(observedAt));
});

test('numeric observation epochs reject the entire invalid Date domain without throwing', () => {
  const maximumFourDigitEpoch = Date.UTC(9999, 11, 31, 23, 59, 59, 999);
  assert.equal(L.parseWeather({ name: 'x', latitude: 1, longitude: 2 }, maximumFourDigitEpoch).ok, true);

  for (const epoch of [8640000000000000, 8640000000000001, -8640000000000000,
    -8640000000000001, Number.MAX_VALUE, -Number.MAX_VALUE]) {
    assert.doesNotThrow(() => L.parseWeather({ name: 'x', latitude: 1, longitude: 2 }, epoch), String(epoch));
    assert.equal(L.parseWeather({ name: 'x', latitude: 1, longitude: 2 }, epoch).outcome, 'malformed', String(epoch));
    assert.equal(L.manualCoordinateLocation('1, 2', epoch).ok, false, String(epoch));
    assert.equal(L.parseGeocodingResponse({ results: [] }, epoch).outcome, 'malformed', String(epoch));
  }
  assert.equal(L.locationAge(location(), Number.MAX_VALUE), null);
  assert.equal(L.freshness(location(), Number.MAX_VALUE, {}).ok, false);
});

test('successful transaction increments revision once and never mutates prior state', () => {
  const before = state();
  const result = L.nextState(before, { mode: 'manual', manual: location({ source: 'manual-coordinates', precision: 'coordinates' }) });
  assert.equal(result.ok, true);
  assert.equal(result.state.revision, 5);
  assert.equal(result.state.mode, 'manual');
  assert.equal(before.revision, 4);
  assert.equal(before.mode, 'weather');
});

test('invalid transaction is all-or-nothing and does not synthesize defaults', () => {
  const before = state();
  const result = L.nextState(before, { mode: 'manual', manual: location({ latitude: 100 }) });
  assert.equal(result.ok, false);
  assert.equal(before.mode, 'weather');
  assert.equal(before.revision, 4);
  assert.equal(L.nextState({ bad: true }, {}).ok, false);
});

test('revision policy deduplicates own watcher echoes and rejects stale publication', () => {
  assert.deepEqual({ outcome: L.revisionDecision(4, state({ revision: 4 })).outcome, apply: L.revisionDecision(4, state({ revision: 4 })).apply },
    { outcome: 'echo', apply: false });
  assert.equal(L.revisionDecision(4, state({ revision: 3 })).outcome, 'stale');
  assert.equal(L.revisionDecision(4, state({ revision: 3 })).apply, false);
  assert.equal(L.revisionDecision(4, state({ revision: 5 })).outcome, 'newer');
  assert.equal(L.revisionDecision(4, state({ revision: 5 })).apply, true);
  assert.equal(L.revisionDecision(4, '{').outcome, 'malformed');
  assert.equal(L.revisionDecision(-1, state()).outcome, 'malformed');
});

// Weather is read-only input and cannot cause a provider policy change.

test('Weather parser accepts exact numeric coordinates and canonicalizes metadata', () => {
  const parsed = L.parseWeather({ name: '  Hilversumse Meent  ', latitude: 52.27115, longitude: 5.13729, ignored: true }, NOW);
  assert.equal(parsed.ok, true);
  assert.equal(parsed.location.label, 'Hilversumse Meent');
  assert.equal(parsed.location.latitude, 52.27115);
  assert.equal(parsed.location.source, 'weather');
  assert.equal(parsed.location.precision, 'selected-locality');
  assert.equal(parsed.location.observedAt, '2026-09-01T12:00:00Z');
});

test('Weather parsing distinguishes absent, temporary, malformed and valid', () => {
  assert.equal(L.classifyWeatherRead('absent', null, NOW).outcome, 'absent');
  assert.equal(L.classifyWeatherRead('temporarily-unavailable', null, NOW).outcome, 'temporarily-unavailable');
  assert.equal(L.classifyWeatherRead('data', '{', NOW).outcome, 'malformed');
  assert.equal(L.classifyWeatherRead('data', { name: 'x', latitude: 1 }, NOW).outcome, 'malformed');
  assert.equal(L.classifyWeatherRead('data', { name: 'x', latitude: '1', longitude: 2 }, NOW).outcome, 'malformed');
  assert.equal(L.classifyWeatherRead('data', { name: 'x', latitude: 1, longitude: 2 }, NOW).outcome, 'valid');
});

test('missing Weather name gets a truthful local fallback without changing coordinates', () => {
  const parsed = L.parseWeather({ latitude: 0, longitude: 0 }, NOW);
  assert.equal(parsed.location.label, 'Weather location');
  assert.equal(parsed.location.latitude, 0);
  assert.equal(parsed.location.longitude, 0);
});

test('valid Weather mode selects current Weather with no network permission', () => {
  const selected = L.selectedLocation(state(), weatherRead(), NOW);
  assert.equal(selected.ok, true);
  assert.equal(selected.outcome, 'current');
  assert.equal(selected.shouldRefreshCache, true);
  assert.equal(selected.networkAllowed, false);
});

test('canonical Weather cache equality suppresses observation-only persistence', () => {
  const current = location({ observedAt: '2026-09-01T12:00:00Z', extra: 'discard' });
  const cached = location({ observedAt: '2020-01-01T00:00:00Z' });
  assert.equal(L.weatherCacheEqual(cached, current), true);

  const selected = L.selectedLocation(state({ weatherCache: cached }), {
    outcome: 'valid', ok: true, location: current
  }, NOW);
  assert.equal(selected.ok, true);
  assert.equal(selected.location.observedAt, '2026-09-01T12:00:00Z');
  assert.equal(selected.shouldRefreshCache, false);

  assert.equal(L.weatherCacheEqual(cached, location({ latitude: 52.3 })), false);
  assert.equal(L.weatherCacheEqual(cached, location({ label: 'Hilversum' })), false);
  assert.equal(L.weatherCacheEqual(cached, location({ source: 'manual-search' })), false);
});

test('bootstrap does not persist an unchanged canonical Weather cache', () => {
  const cached = location({ observedAt: '2020-01-01T00:00:00Z' });
  const current = location({ observedAt: '2026-09-01T12:00:00Z' });
  const result = L.bootstrap({ outcome: 'valid', ok: true, state: state({ weatherCache: cached }) }, {
    outcome: 'valid', ok: true, location: current
  }, NOW);
  assert.equal(result.ok, true);
  assert.equal(result.outcome, 'current');
  assert.equal(result.shouldPersist, false);
  assert.equal(result.location.observedAt, current.observedAt);
  assert.equal(result.state.weatherCache.observedAt, cached.observedAt);
});

test('selected location revalidates forged valid Weather envelopes', () => {
  const noCache = state({ weatherCache: null });
  const forgedLocations = [
    location({ latitude: 999 }),
    location({ source: 'manual-search' }),
    { observedAt: '2026-09-01T10:00:00Z' }
  ];
  for (const forged of forgedLocations) {
    const selected = L.selectedLocation(noCache, { outcome: 'valid', ok: true, location: forged }, NOW);
    assert.equal(selected.ok, false);
    assert.equal(selected.outcome, 'unavailable');
    assert.equal(selected.location, undefined);
  }
  assert.equal(L.selectedLocation(noCache,
    { outcome: 'valid', ok: 'true', location: location() }, NOW).ok, false);

  const canonicalized = L.selectedLocation(noCache, {
    outcome: 'valid', ok: true, location: location({ label: '  Current  ', extra: 'discard' })
  }, NOW);
  assert.equal(canonicalized.ok, true);
  assert.equal(canonicalized.location.label, 'Current');
  assert.equal(Object.hasOwn(canonicalized.location, 'extra'), false);
});

test('selected location revalidates every nested state location', () => {
  const forged = state({ mode: 'manual', manual: location({
    source: 'manual-coordinates', precision: 'coordinates', latitude: 999
  }) });
  const selected = L.selectedLocation(forged, weatherRead(), NOW);
  assert.equal(selected.ok, false);
  assert.equal(selected.outcome, 'malformed');
  assert.equal(selected.state, undefined);
});

test('missing, temporary or corrupt Weather retains cache as Last known and never changes mode', () => {
  for (const weather of [
    L.classifyWeatherRead('absent'),
    L.classifyWeatherRead('temporarily-unavailable'),
    L.classifyWeatherRead('data', '{', NOW)
  ]) {
    const selected = L.selectedLocation(state(), weather, NOW);
    assert.equal(selected.ok, true);
    assert.equal(selected.outcome, 'last-known');
    assert.equal(selected.location.label, 'Hilversumse Meent');
    assert.equal(selected.freshness.sourceLabel.startsWith('Last known · '), true);
    assert.equal(selected.networkAllowed, false);
  }
});

test('missing Weather and missing cache is finite setup, never auto-IP', () => {
  const selected = L.selectedLocation(state({ weatherCache: null }), L.classifyWeatherRead('absent'), NOW);
  assert.equal(selected.ok, false);
  assert.equal(selected.outcome, 'unavailable');
  assert.equal(selected.error.code, 'location-unavailable');
});

test('absent private state bootstraps Weather only when Weather is valid', () => {
  const absent = L.classifyPrivateStateRead('absent');
  const adopted = L.bootstrap(absent, weatherRead(), NOW);
  assert.equal(adopted.outcome, 'bootstrap-weather');
  assert.equal(adopted.shouldPersist, true);
  assert.equal(adopted.state.mode, 'weather');
  assert.equal(adopted.networkAllowed, false);
  const setup = L.bootstrap(absent, L.classifyWeatherRead('absent'), NOW);
  assert.equal(setup.outcome, 'setup');
  assert.equal(setup.shouldPersist, false);
  assert.equal(setup.state, null);
});

test('bootstrap revalidates forged valid Weather envelopes before adoption', () => {
  const absent = L.classifyPrivateStateRead('absent');
  for (const weather of [
    { outcome: 'valid', ok: true, location: location({ latitude: 999 }) },
    { outcome: 'valid', ok: true, location: location({ source: 'auto-ip', precision: 'approximate-city' }) },
    { outcome: 'valid', ok: true },
    { outcome: 'valid', ok: 1, location: location() },
    Object.create({ outcome: 'valid', ok: true, location: location() })
  ]) {
    const result = L.bootstrap(absent, weather, NOW);
    assert.equal(result.outcome, 'setup');
    assert.equal(result.ok, true);
    assert.equal(result.state, null);
    assert.equal(result.location, null);
    assert.equal(result.shouldPersist, false);
  }
});

test('bootstrap revalidates forged valid private-state envelopes and never leaks undefined state', () => {
  const adversarial = [
    { outcome: 'valid', ok: true },
    { outcome: 'valid', ok: true, state: state({ weatherCache: location({ latitude: 999 }) }) },
    { outcome: 'valid', ok: true, state: state({ mode: 'manual', manual: location() }) },
    { outcome: 'valid', ok: 1, state: state() },
    { outcome: 'made-up', ok: false, state: state() },
    Object.create({ outcome: 'valid', ok: true, state: state() }),
    7
  ];
  for (const privateRead of adversarial) {
    const result = L.bootstrap(privateRead, weatherRead(), NOW);
    assert.equal(result.ok, false);
    assert.equal(result.outcome, 'malformed');
    assert.equal(result.state, null);
    assert.equal(result.location, null);
    assert.equal(result.shouldPersist, false);
    assert.equal(result.networkAllowed, false);
  }

  const raw = state({ junk: 'discard', weatherCache: location({ label: '  Cached  ', extra: 'discard' }) });
  const accepted = L.bootstrap({ outcome: 'valid', ok: true, state: raw }, L.classifyWeatherRead('absent'), NOW);
  assert.equal(accepted.ok, true);
  assert.equal(accepted.state.weatherCache.label, 'Cached');
  assert.equal(Object.hasOwn(accepted.state, 'junk'), false);
  assert.equal(Object.hasOwn(accepted.state.weatherCache, 'extra'), false);
});

test('malformed and unsupported private state are retained as errors, not bootstrapped', () => {
  for (const read of [L.parsePrivateState('{'), L.parsePrivateState(state({ schemaVersion: 2 }))]) {
    const result = L.bootstrap(read, weatherRead(), NOW);
    assert.equal(result.ok, false);
    assert.equal(result.shouldPersist, false);
    assert.equal(result.location, null);
  }
});

test('manual mode only uses manual and auto mode only uses accepted auto cache', () => {
  const manual = location({ source: 'manual-coordinates', precision: 'coordinates', label: 'Coordinates' });
  let selected = L.selectedLocation(state({ mode: 'manual', manual, autoConsentVersion: 1, autoIpCache: autoLocation() }), weatherRead(), NOW);
  assert.equal(selected.location.source, 'manual-coordinates');
  assert.equal(selected.networkAllowed, false);
  selected = L.selectedLocation(state({ mode: 'auto-ip', manual, autoConsentVersion: 1, autoIpCache: autoLocation() }), weatherRead(), NOW);
  assert.equal(selected.location.source, 'auto-ip');
  assert.equal(selected.networkAllowed, true);
});

// Strict direct input and provider parsing.

test('strict decimal coordinates accept signs, edge values, decimal points and zero', () => {
  const cases = [
    ['52.27115, 5.13729', 52.27115, 5.13729], ['0,0', 0, 0],
    ['+90, -180', 90, -180], ['-90,+180', -90, 180], ['.5, 5.', .5, 5]
  ];
  for (const [text, lat, lon] of cases) {
    const result = L.parseDirectCoordinates(text);
    assert.equal(result.ok, true, text);
    assert.equal(result.latitude, lat);
    assert.equal(result.longitude, lon);
  }
});

test('strict coordinates reject exponent, hex, booleans, blanks, partial and out-of-range pairs', () => {
  for (const text of [
    '1e2,2', '0x10,2', 'true,false', '', '1', '1,', ',2', '1,2,3',
    '91,0', '-91,0', '0,181', '0,-181', 'Infinity,0', 'NaN,0', '.,2', '+,2'
  ]) assert.equal(L.parseDirectCoordinates(text).ok, false, text);
  assert.equal(L.parseDirectCoordinates('91,0').error.code, 'coordinates-out-of-range');
});

test('manual input makes only coordinates and provider selections committable', () => {
  assert.equal(L.classifyManualInput('0,0').committable, true);
  assert.equal(L.classifyManualInput('Amsterdam').committable, false);
  assert.equal(L.classifyManualInput('Amsterdam').searchable, true);
  assert.equal(L.classifyManualInput(' a b ').outcome, 'query-too-short');
  assert.equal(L.classifyManualInput('91, 4').outcome, 'invalid-coordinates');
  assert.equal(L.classifyManualInput('Paris, France').outcome, 'query');
  assert.equal(L.classifyManualInput('12, nope').outcome, 'invalid-coordinates');
});

test('committed coordinate location gets source label and caller observation time', () => {
  const result = L.manualCoordinateLocation('52.27115, 5.13729', NOW);
  assert.equal(result.ok, true);
  assert.equal(result.location.label, 'Coordinates');
  assert.equal(result.location.source, 'manual-coordinates');
  assert.equal(result.location.precision, 'coordinates');
  assert.equal(result.location.observedAt, '2026-09-01T12:00:00Z');
});

test('Open-Meteo parser preserves coordinate precision, canonical labels and maximum five rows', () => {
  const results = Array.from({ length: 7 }, (_, i) => ({
    name: ` Town ${i} `, admin1: ' Region ', country: ' NL ',
    latitude: 52.123456789 + i / 100, longitude: '5.987654321', timezone: 'Europe/Amsterdam'
  }));
  const parsed = L.parseGeocodingResponse({ results }, NOW);
  assert.equal(parsed.outcome, 'results');
  assert.equal(parsed.candidates.length, 5);
  assert.equal(parsed.candidates[0].location.latitude, 52.123456789);
  assert.equal(parsed.candidates[0].location.longitude, 5.987654321);
  assert.equal(parsed.candidates[0].displayLabel, 'Town 0 · Region · NL');
  assert.equal(parsed.candidates[0].location.source, 'manual-search');
});

test('geocoder no-results and malformed provider bodies are different', () => {
  assert.equal(L.parseGeocodingResponse({ results: [] }, NOW).outcome, 'no-results');
  // Open-Meteo omits results entirely for a real zero-match response.
  assert.equal(L.parseGeocodingResponse({ generationtime_ms: 0.1 }, NOW).outcome, 'no-results');
  for (const payload of ['{', [], { results: null }, { results: [{ name: 'Bad', latitude: 999, longitude: 0 }] }])
    assert.equal(L.parseGeocodingResponse(payload, NOW).outcome, 'malformed');
});

test('geocoder ignores a bad row when usable candidates remain', () => {
  const parsed = L.parseGeocodingResponse({ results: [
    { name: 'bad', latitude: 500, longitude: 0 },
    { name: 'good', latitude: 1, longitude: 2 }
  ] }, NOW);
  assert.equal(parsed.outcome, 'results');
  assert.equal(parsed.candidates.length, 1);
  assert.equal(parsed.candidates[0].location.label, 'good');
});

test('wttr nearest_area parser accepts provider decimal strings and always marks Approximate semantics', () => {
  const body = { nearest_area: [{
    areaName: [{ value: 'Amsterdam' }], region: [{ value: 'North Holland' }],
    country: [{ value: 'Netherlands' }], latitude: '52.374', longitude: '4.900'
  }] };
  const parsed = L.parseAutoIpResponse(body, NOW);
  assert.equal(parsed.outcome, 'candidate');
  assert.equal(parsed.requiresAcceptance, true);
  assert.equal(parsed.candidate.source, 'auto-ip');
  assert.equal(parsed.candidate.precision, 'approximate-city');
  assert.equal(parsed.candidate.latitude, 52.374);
});

test('wttr rejects missing, partial, malformed and out-of-range nearest_area', () => {
  const cases = [
    {}, { nearest_area: [] }, { nearest_area: [{}] },
    { nearest_area: [{ areaName: [{ value: 'x' }], latitude: '1' }] },
    { nearest_area: [{ areaName: [{ value: 'x' }], latitude: '91', longitude: '0' }] },
    { nearest_area: [{ areaName: [], latitude: '1', longitude: '2' }] }
  ];
  for (const body of cases) assert.equal(L.parseAutoIpResponse(body, NOW).outcome, 'malformed');
});

test('provider transport errors, cancellation, rate limiting and empty results remain distinct', () => {
  assert.equal(L.classifyProviderResult('geocode', { outcome: 'timeout' }, NOW).outcome, 'offline');
  assert.equal(L.classifyProviderResult('geocode', { outcome: 'offline' }, NOW).outcome, 'offline');
  assert.equal(L.classifyProviderResult('geocode', { outcome: 'data', status: 429, body: 'private' }, NOW).outcome, 'rate-limited');
  assert.equal(L.classifyProviderResult('geocode', { outcome: 'canceled' }, NOW).outcome, 'canceled');
  assert.equal(L.classifyProviderResult('geocode', { outcome: 'http-error', body: 'private' }, NOW).outcome, 'provider-error');
  assert.equal(L.classifyProviderResult('geocode', { outcome: 'data', body: { results: [] } }, NOW).outcome, 'no-results');
  assert.equal(L.classifyProviderResult('unknown', { outcome: 'data', body: {} }, NOW).outcome, 'provider-error');
});

test('Weather, provider payloads and transport envelopes ignore prototypes', () => {
  assert.equal(L.parseWeather(Object.create({ name: 'x', latitude: 1, longitude: 2 }), NOW).outcome, 'malformed');
  assert.equal(L.parseGeocodingResponse(Object.create({
    results: [{ name: 'x', latitude: 1, longitude: 2 }]
  }), NOW).outcome, 'no-results');
  assert.equal(L.parseGeocodingResponse({ results: [Object.create({ name: 'x', latitude: 1, longitude: 2 })] }, NOW).outcome, 'malformed');
  assert.equal(L.parseAutoIpResponse(Object.create({
    nearest_area: [{ areaName: 'x', latitude: 1, longitude: 2 }]
  }), NOW).outcome, 'malformed');
  assert.equal(L.classifyProviderResult('geocode', Object.create({
    outcome: 'data', body: { results: [] }
  }), NOW).outcome, 'provider-error');
});

// Freshness, labels and candidate movement.

test('source labels are truthful for all source types', () => {
  assert.equal(L.freshness(location(), NOW, {}).sourceLabel, 'Weather');
  assert.equal(L.freshness(location({ source: 'manual-search' }), NOW, {}).sourceLabel, 'Manual');
  assert.equal(L.freshness(location({ source: 'manual-coordinates', precision: 'coordinates' }), NOW, {}).sourceLabel, 'Coordinates');
  assert.equal(L.freshness(autoLocation(), NOW, {}).sourceLabel, 'Approximate');
});

test('manual locations never stale; auto is stale only after 24 hours', () => {
  const old = '2020-01-01T00:00:00Z';
  assert.equal(L.freshness(location({ source: 'manual-search', observedAt: old }), NOW, {}).stale, false);
  const exactly = autoLocation({ observedAt: new Date(NOW - L.AUTO_STALE_MS).toISOString() });
  const over = autoLocation({ observedAt: new Date(NOW - L.AUTO_STALE_MS - 1).toISOString() });
  assert.equal(L.freshness(exactly, NOW, {}).stale, false);
  assert.equal(L.freshness(over, NOW, {}).stale, true);
  assert.equal(L.freshness(over, NOW, {}).sourceLabel.startsWith('Last known · '), true);
});

test('Weather fallback is Last known regardless of age and future clocks clamp age to zero', () => {
  const future = location({ observedAt: '2026-09-02T00:00:00Z' });
  const result = L.freshness(future, NOW, { lastKnown: true });
  assert.equal(result.stale, true);
  assert.equal(result.ageMs, 0);
  assert.equal(result.sourceLabel, 'Last known · just now');
});

test('location age validates the complete location rather than trusting its timestamp', () => {
  assert.equal(L.locationAge(location(), NOW), 2 * 60 * 60 * 1000);
  assert.equal(L.locationAge(location({ latitude: 999 }), NOW), null);
  assert.equal(L.locationAge(location({ source: 'forged' }), NOW), null);
  assert.equal(L.locationAge({ observedAt: '2026-09-01T10:00:00Z' }, NOW), null);
});

test('age formatting is finite and deterministic', () => {
  assert.equal(L.formatAge(0), 'just now');
  assert.equal(L.formatAge(61_000), '1 min ago');
  assert.equal(L.formatAge(3_600_000), '1 hr ago');
  assert.equal(L.formatAge(48 * 3_600_000), '2 days ago');
  assert.equal(L.formatAge(NaN), 'unknown age');
});

test('great-circle distance handles same point, known distance, dateline and invalid data', () => {
  assert.equal(L.distanceKm({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 0 }), 0);
  assert.ok(Math.abs(L.distanceKm(
    { latitude: 52.3676, longitude: 4.9041 },
    { latitude: 51.5074, longitude: -0.1278 }) - 357.3) < 2);
  assert.ok(L.distanceKm({ latitude: 0, longitude: 179 }, { latitude: 0, longitude: -179 }) < 225);
  assert.equal(L.distanceKm({ latitude: 100, longitude: 0 }, { latitude: 0, longitude: 0 }), null);
});

test('first approximate result always requires acceptance', () => {
  const assessment = L.assessAutoCandidate(null, autoLocation());
  assert.equal(assessment.outcome, 'first-use');
  assert.equal(assessment.requiresAcceptance, true);
  assert.equal(assessment.mayInstallAutomatically, false);
});

test('auto candidate at 250 km is allowed but more than 250 km requires explicit review', () => {
  const base = autoLocation({ latitude: 0, longitude: 0 });
  // Construct exactly 250 km on the model's spherical earth.
  const atThresholdDegrees = (250 / 6371.0088) * 180 / Math.PI;
  let assessment = L.assessAutoCandidate(base, autoLocation({ latitude: 0, longitude: atThresholdDegrees }));
  assert.ok(assessment.distanceKm <= 250.000000001);
  assert.equal(assessment.changed, false);
  assert.equal(assessment.mayInstallAutomatically, true);
  assessment = L.assessAutoCandidate(base, autoLocation({ latitude: 0, longitude: 2.3 }));
  assert.ok(assessment.distanceKm > 250);
  assert.equal(assessment.outcome, 'large-jump');
  assert.equal(assessment.requiresAcceptance, true);
  assert.equal(assessment.mayInstallAutomatically, false);
});

// Explicit privacy decisions.

test('geocoding is legal only after manual editor open, user change, and searchable query', () => {
  assert.equal(L.networkDecision('geocode', { editorOpen: true, userChanged: true, query: 'Utrecht' }).legal, true);
  assert.equal(L.networkDecision('geocode', { editorOpen: false, userChanged: true, query: 'Utrecht' }).legal, false);
  assert.equal(L.networkDecision('geocode', { editorOpen: true, userChanged: false, query: 'Utrecht' }).legal, false);
  assert.equal(L.networkDecision('geocode', { editorOpen: true, userChanged: true, query: '0,0' }).legal, false);
  assert.equal(L.networkDecision('geocode', { editorOpen: true, userChanged: true, query: 'ab' }).legal, false);
});

test('network policy requires own, exactly typed context fields and canonicalizes queries', () => {
  const inheritedAuto = Object.create({ mode: 'auto-ip', autoConsentVersion: 1, hasCache: false });
  assert.equal(L.networkDecision('auto-ip', inheritedAuto).legal, false);
  assert.equal(L.networkDecision('auto-ip', Object.assign(inheritedAuto, { hasCache: false })).legal, false);
  assert.equal(L.networkDecision('auto-ip', { mode: 'auto-ip', autoConsentVersion: 1 }).legal, false);
  assert.equal(L.networkDecision('auto-ip', { mode: 'auto-ip', autoConsentVersion: 1, hasCache: 'false' }).legal, false);
  assert.equal(L.networkDecision('auto-ip', {
    mode: 'auto-ip', autoConsentVersion: 1, hasCache: true, cacheStale: true
  }).legal, false);
  assert.equal(L.networkDecision('auto-ip', {
    mode: 'auto-ip', autoConsentVersion: 1, hasCache: true, userRequestedRetry: 1
  }).legal, false);

  const inheritedSearch = Object.create({ editorOpen: true, userChanged: true, query: 'Utrecht' });
  assert.equal(L.networkDecision('geocode', inheritedSearch).legal, false);
  assert.equal(L.networkDecision('geocode', { editorOpen: 1, userChanged: true, query: 'Utrecht' }).legal, false);
  const canonical = L.networkDecision('geocode', { editorOpen: true, userChanged: true, query: '  New   York  ' });
  assert.equal(canonical.legal, true);
  assert.equal(canonical.normalizedQuery, 'New York');
});

test('Object.prototype pollution cannot authorize network policy', () => {
  const pollution = {
    mode: 'auto-ip', autoConsentVersion: 1, hasCache: false,
    editorOpen: true, userChanged: true, query: 'Utrecht'
  };
  try {
    for (const [key, value] of Object.entries(pollution))
      Object.defineProperty(Object.prototype, key, { value, writable: true, configurable: true });
    assert.equal(L.networkDecision('auto-ip', {}).legal, false);
    assert.equal(L.networkDecision('auto-ip', { hasCache: false }).legal, false);
    assert.equal(L.networkDecision('geocode', {}).legal, false);
    assert.equal(L.networkDecision('geocode', { query: 'Utrecht' }).legal, false);
  } finally {
    for (const key of Object.keys(pollution)) delete Object.prototype[key];
  }
});

test('IP request is impossible before exact consent version 1 and auto mode', () => {
  const base = { mode: 'auto-ip', hasCache: false };
  assert.equal(L.networkDecision('auto-ip', { ...base, autoConsentVersion: 0 }).legal, false);
  assert.equal(L.networkDecision('auto-ip', { ...base, autoConsentVersion: 2 }).legal, false);
  assert.equal(L.networkDecision('auto-ip', { ...base, autoConsentVersion: 1, mode: 'weather' }).legal, false);
  assert.equal(L.networkDecision('auto-ip', { ...base, autoConsentVersion: 1 }).legal, true);
});

test('auto refresh happens at most once per stale shell session unless user retries', () => {
  const common = { mode: 'auto-ip', autoConsentVersion: 1, hasCache: true, cacheStale: true };
  assert.equal(L.networkDecision('auto-ip', { ...common, sessionRefreshUsed: false }).legal, true);
  assert.equal(L.networkDecision('auto-ip', { ...common, sessionRefreshUsed: true }).legal, false);
  assert.equal(L.networkDecision('auto-ip', { ...common, sessionRefreshUsed: true, userRequestedRetry: true }).legal, true);
  assert.equal(L.networkDecision('auto-ip', { ...common, cacheStale: false }).legal, false);
});

test('Weather/manual-coordinate policy makes zero provider request decisions', () => {
  assert.equal(L.networkDecision('auto-ip', { mode: 'weather', autoConsentVersion: 1, hasCache: false }).legal, false);
  assert.equal(L.networkDecision('geocode', { editorOpen: true, userChanged: true, query: '52.2, 5.1' }).legal, false);
  assert.equal(L.selectedLocation(state(), weatherRead(), NOW).networkAllowed, false);
});

test('errors never include raw provider body, query, or coordinates', () => {
  const secret = 'SECRET-52.27115-5.13729';
  const failures = [
    L.parseGeocodingResponse(secret, NOW),
    L.parseAutoIpResponse(secret, NOW),
    L.parsePrivateState(secret),
    L.parseDirectCoordinates(secret)
  ];
  for (const failure of failures) {
    const serialized = JSON.stringify(failure);
    assert.equal(serialized.includes(secret), false);
    assert.equal(serialized.includes('52.27115'), false);
  }
});

// Monotonic generation/race guards.

test('matching search token requires epoch, normalized query, mode and open editor', () => {
  const current = generation();
  const token = L.captureGeneration('search', current);
  assert.equal(L.generationMatches(token, current), true);
  assert.equal(L.generationMatches(token, { ...current, searchEpoch: 8 }), false);
  assert.equal(L.generationMatches(token, { ...current, query: 'Rotterdam' }), false);
  assert.equal(L.generationMatches(token, { ...current, mode: 'weather' }), false);
  assert.equal(L.generationMatches(token, { ...current, editorOpen: false }), false);
  assert.equal(L.generationMatches(token, { ...current, query: '  Utrecht  ' }), true);
});

test('delayed A search cannot publish after B query starts', () => {
  const a = generation({ query: 'Amsterdam' });
  const aToken = L.captureGeneration('search', a);
  const b = L.advanceGeneration(a, { query: 'Berlin', queryChanged: true });
  assert.equal(b.searchEpoch, a.searchEpoch + 1);
  assert.equal(L.generationMatches(aToken, b), false);
  assert.equal(L.guardedProviderResult('geocode', aToken, b,
    { outcome: 'data', body: { results: [{ name: 'A', latitude: 1, longitude: 2 }] } }, NOW).publish, false);
  const bToken = L.captureGeneration('search', b);
  assert.equal(L.generationMatches(bToken, b), true);
  const published = L.guardedProviderResult('geocode', bToken, b,
    { outcome: 'data', body: { results: [{ name: 'B', latitude: 1, longitude: 2 }] } }, NOW);
  assert.equal(published.publish, true);
  assert.equal(published.result.candidates[0].location.label, 'B');
});

test('closing editor immediately suppresses search publication', () => {
  const open = generation();
  const token = L.captureGeneration('search', open);
  const closed = L.advanceGeneration(open, { editorOpen: false });
  assert.equal(closed.searchEpoch, open.searchEpoch + 1);
  assert.equal(L.generationMatches(token, closed), false);
});

test('mode/location change invalidates delayed search, auto and save together', () => {
  const old = generation({ mode: 'auto-ip' });
  const search = L.captureGeneration('search', old);
  const auto = L.captureGeneration('auto', old);
  const save = L.captureGeneration('save', old);
  const next = L.advanceGeneration(old, { mode: 'manual', locationChanged: true });
  assert.equal(next.locationEpoch, old.locationEpoch + 1);
  assert.equal(next.searchEpoch, old.searchEpoch + 1);
  assert.equal(next.saveEpoch, old.saveEpoch + 1);
  assert.equal(L.generationMatches(search, next), false);
  assert.equal(L.generationMatches(auto, next), false);
  assert.equal(L.generationMatches(save, next), false);
});

test('save token also guards revision so watcher echoes or later commits cannot win', () => {
  const current = generation();
  const token = L.captureGeneration('save', current);
  assert.equal(L.generationMatches(token, current), true);
  assert.equal(L.generationMatches(token, { ...current, revision: 5 }), false);
  assert.equal(L.generationMatches(token, { ...current, saveEpoch: 3 }), false);
});

test('Weather token is mode, location epoch and revision scoped', () => {
  const current = generation({ mode: 'weather' });
  const token = L.captureGeneration('weather', current);
  assert.equal(L.generationMatches(token, current), true);
  assert.equal(L.generationMatches(token, { ...current, mode: 'manual' }), false);
  assert.equal(L.generationMatches(token, { ...current, locationEpoch: 4 }), false);
  assert.equal(L.generationMatches(token, { ...current, revision: 5 }), false);
});

test('delayed automatic A result cannot publish after B commit', () => {
  const a = generation({ mode: 'auto-ip', revision: 4 });
  const token = L.captureGeneration('auto', a);
  const savingB = L.advanceGeneration(a, { locationChanged: true, revision: 5 });
  assert.equal(L.generationMatches(token, savingB), false);
});

test('generation counters advance exactly at the safe boundary and fail closed at saturation', () => {
  const maximum = Number.MAX_SAFE_INTEGER;
  const near = generation({
    locationEpoch: maximum - 1, searchEpoch: maximum - 1, saveEpoch: maximum - 1,
    mode: 'auto-ip'
  });
  const nearToken = L.captureGeneration('auto', near);
  const boundary = L.advanceGeneration(near, { locationChanged: true });
  assert.equal(boundary.locationEpoch, maximum);
  assert.equal(boundary.searchEpoch, maximum);
  assert.equal(boundary.saveEpoch, maximum);
  assert.equal(L.generationMatches(nearToken, boundary), false);

  for (const [kind, saturated, change] of [
    ['auto', generation({ mode: 'auto-ip', locationEpoch: maximum }), { locationChanged: true }],
    ['search', generation({ searchEpoch: maximum }), { query: 'Rotterdam', queryChanged: true }],
    ['save', generation({ saveEpoch: maximum }), { saveStarted: true }]
  ]) {
    const token = L.captureGeneration(kind, saturated);
    const advanced = L.advanceGeneration(saturated, change);
    assert.equal(advanced, null, kind);
    assert.equal(L.generationMatches(token, advanced), false, kind);
  }
});

test('invalid generation values fail closed', () => {
  assert.equal(L.generationState(-1, 0, 0, 'manual', '', true, 0), null);
  assert.equal(L.generationState(0, NaN, 0, 'manual', '', true, 0), null);
  assert.equal(L.generationState(0, 0, 0, 'manual', '', true, NaN), null);
  assert.equal(L.generationState(0, 0, 0, 'manual', '', true, -1), null);
  assert.equal(L.generationState(Number.MAX_SAFE_INTEGER + 1, 0, 0, 'manual', '', true, 0), null);
  assert.equal(L.generationState(0, 0, 0, 'manual', '', true, Number.MAX_SAFE_INTEGER + 1), null);
  assert.equal(L.generationState(0, 0, 0, 'manual', 7, true, 0), null);
  assert.equal(L.generationState(0, 0, 0, 'manual', '', 1, 0), null);
  assert.equal(L.generationState(0, 0, 0, 'manual', '', true), null);
  assert.equal(L.captureGeneration('search', {}), null);
  assert.equal(L.captureGeneration('unknown', generation()), null);
  assert.equal(L.generationMatches(null, generation()), false);
  assert.equal(L.generationMatches({ kind: 'unknown' }, generation()), false);
});

test('generation contexts and tokens require complete own canonical fields', () => {
  const current = generation();
  const token = L.captureGeneration('search', current);
  assert.equal(L.captureGeneration('search', Object.create(current)), null);
  assert.equal(L.generationMatches(token, Object.create(current)), false);
  assert.equal(L.generationMatches(Object.create(token), current), false);

  const inheritedKind = { ...token };
  delete inheritedKind.kind;
  Object.setPrototypeOf(inheritedKind, { kind: 'search' });
  assert.equal(L.generationMatches(inheritedKind, current), false);

  const noncanonical = { ...token, query: '  Utrecht  ' };
  assert.equal(L.generationMatches(noncanonical, current), false);
  assert.equal(L.advanceGeneration(Object.create(current), {}), null);
  assert.equal(L.advanceGeneration(current, { locationChanged: 1 }), null);
  assert.equal(L.advanceGeneration(current, { editorOpen: 0 }), null);
  assert.equal(L.guardedProviderResult('geocode', Object.create(token), current,
    { outcome: 'data', body: { results: [] } }, NOW).publish, false);
});

test('Object.prototype pollution cannot forge a generation context or token', () => {
  const polluted = generation({ mode: 'auto-ip' });
  const pollution = { ...polluted, kind: 'auto' };
  try {
    for (const [key, value] of Object.entries(pollution))
      Object.defineProperty(Object.prototype, key, { value, writable: true, configurable: true });
    assert.equal(L.captureGeneration('auto', {}), null);
    assert.equal(L.generationMatches({ kind: 'auto' }, {}), false);
    assert.equal(L.advanceGeneration({}, { locationChanged: true }), null);
    assert.equal(L.guardedProviderResult('auto-ip', { kind: 'auto' }, {},
      { outcome: 'data', body: {} }, NOW).publish, false);
  } finally {
    for (const key of Object.keys(pollution)) delete Object.prototype[key];
  }
});

test('model source contains no I/O primitives or provider request side effects', () => {
  const fs = require('node:fs');
  const source = fs.readFileSync(require.resolve('../LocationModel.js'), 'utf8');
  for (const forbidden of [
    /\brequire\s*\(/, /XMLHttpRequest/, /fetch\s*\(/, /WebSocket/,
    /child_process/, /\.open\s*\(/, /\.writeFile/, /https?:\/\//
  ]) assert.equal(forbidden.test(source), false, String(forbidden));
});
