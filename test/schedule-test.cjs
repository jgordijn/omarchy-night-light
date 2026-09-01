'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const path = require('node:path')
const Schedule = require('../ScheduleModel.js')
const Solar = require('../SolarModel.js')

const S = Date.parse('2024-03-20T18:00:00Z')
const R = Date.parse('2024-03-21T06:00:00Z')
const HOUR = 60 * 60 * 1000
const MAX_EVALUATION_EPOCH_MS = 8640000000000000 - (370 + 2) * 86400000

function settings(overrides = {}) {
  return Object.assign({
    automationEnabled: true,
    nightTemperature: 4000,
    transitionMinutes: 60
  }, overrides)
}

function events(sunsetMs = S, sunriseMs = R) {
  return { ok: true, status: 'normal', sunsetMs, sunriseMs }
}

function evaluate(at, overrides, solarEvents) {
  const result = Schedule.evaluate(at, solarEvents || events(), settings(overrides))
  assert.equal(result.ok, true, result.error && result.error.message)
  assert.ok(Number.isFinite(result.warmth))
  assert.ok(result.warmth >= 0 && result.warmth <= 1)
  assert.ok(Number.isFinite(result.nextEvaluationMs))
  assert.ok(result.nextEvaluationMs > at)
  return result
}

function close(actual, expected, tolerance = 1e-12) {
  assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} != ${expected}`)
}

test('validateSettings applies defaults and returns one immutable transaction value', () => {
  const result = Schedule.validateSettings({})
  assert.equal(result.ok, true)
  assert.deepEqual(result.value, {
    automationEnabled: true,
    nightTemperature: 4000,
    transitionMinutes: 45
  })
  assert.strictEqual(result.settings, result.value)

  assert.deepEqual(Schedule.validateSettings({
    automationEnabled: false,
    nightTemperature: 1000,
    transitionMinutes: 180
  }).value, {
    automationEnabled: false,
    nightTemperature: 1000,
    transitionMinutes: 180
  })
})

test('validateSettings rejects every invalid field without partially defaulting it', () => {
  const invalidContainers = [null, '', 0, false, [], NaN, Infinity]
  for (const value of invalidContainers) assert.equal(Schedule.validateSettings(value).ok, false)

  const invalidBooleans = [null, 0, 1, 'true', {}, []]
  const invalidTemperatures = [null, '', '4000', true, false, [], {}, NaN, Infinity,
    -Infinity, 999, 6501, 4000.5]
  const invalidDurations = [null, '', '45', true, false, [], {}, NaN, Infinity,
    -Infinity, -1, 181, 1.5]
  for (const value of invalidBooleans)
    assert.equal(Schedule.validateSettings(settings({ automationEnabled: value })).ok, false)
  for (const value of invalidTemperatures)
    assert.equal(Schedule.validateSettings(settings({ nightTemperature: value })).ok, false)
  for (const value of invalidDurations)
    assert.equal(Schedule.validateSettings(settings({ transitionMinutes: value })).ok, false)

  // A rejected multi-field transaction does not manufacture a partially
  // usable settings object for a state owner to commit.
  const rejected = Schedule.validateSettings({ automationEnabled: false, nightTemperature: 999 })
  assert.equal(rejected.ok, false)
  assert.equal('value' in rejected, false)
})

test('settings read only own fields and support null-prototype transactions', () => {
  const inherited = Object.create({
    automationEnabled: false,
    nightTemperature: 1000,
    transitionMinutes: 180,
    ok: true,
    value: { automationEnabled: false, nightTemperature: 1000, transitionMinutes: 180 }
  })
  assert.deepEqual(Schedule.validateSettings(inherited).value, {
    automationEnabled: true,
    nightTemperature: 4000,
    transitionMinutes: 45
  })

  const own = Object.create({
    automationEnabled: true,
    nightTemperature: 6500,
    transitionMinutes: 0
  })
  own.automationEnabled = false
  own.nightTemperature = 3250
  own.transitionMinutes = 30
  assert.deepEqual(Schedule.validateSettings(own).value, {
    automationEnabled: false,
    nightTemperature: 3250,
    transitionMinutes: 30
  })

  const nullPrototype = Object.create(null)
  nullPrototype.automationEnabled = true
  nullPrototype.nightTemperature = 2750
  nullPrototype.transitionMinutes = 15
  nullPrototype.hasOwnProperty = null
  const validated = Schedule.validateSettings(nullPrototype)
  assert.equal(validated.ok, true)
  assert.deepEqual(validated.value, {
    automationEnabled: true,
    nightTemperature: 2750,
    transitionMinutes: 15
  })
  assert.equal(Schedule.evaluate(S, events(), validated).ok, true)

  for (const malformed of [{ ok: false }, { ok: true }, { ok: true, value: null }]) {
    const result = Schedule.evaluate(S, events(), malformed)
    assert.equal(result.ok, false)
    assert.equal(result.error.code, 'settings-invalid')
    assert.equal(result.target, null)
  }
})

test('inherited event snapshots, wrappers, coordinates, and cycle items fail closed', () => {
  const inheritedEvents = Object.create(events())
  const inheritedCoordinates = Object.create({ latitude: 0, longitude: 0 })
  const inheritedWrapper = Object.create({ events: events() })
  const inheritedSolarWrapper = Object.create({ solarEvents: events() })
  const oneInheritedCoordinate = Object.assign(Object.create({ longitude: 0 }), { latitude: 0 })
  const nestedInheritedEvents = {
    status: 'normal',
    events: [Object.create({ sunsetMs: S, sunriseMs: R })]
  }

  for (const location of [inheritedEvents, inheritedCoordinates, inheritedWrapper,
    inheritedSolarWrapper, oneInheritedCoordinate, nestedInheritedEvents]) {
    const result = Schedule.evaluate(S, location, settings())
    assert.equal(result.ok, false)
    assert.equal(result.error.code, 'calculation-failed')
    assert.equal(result.target, null)
  }

  const nullEvents = Object.create(null)
  nullEvents.ok = true
  nullEvents.status = 'normal'
  nullEvents.sunsetMs = S
  nullEvents.sunriseMs = R
  assert.deepEqual(Schedule.evaluate(S, nullEvents, settings()),
    Schedule.evaluate(S, events(), settings()))

  const nullCoordinates = Object.create(null)
  nullCoordinates.latitude = 0
  nullCoordinates.longitude = 0
  const direct = Schedule.evaluate(S, nullCoordinates, settings())
  assert.equal(direct.ok, true)
  assert.deepEqual(direct,
    Schedule.evaluate(S, Solar.surroundingEvents(S, 0, 0), settings()))
})

test('nested event collections accept only small dense arrays of own event objects', () => {
  const dense = Array.from({ length: 8 }, () => ({}))
  dense[3] = { sunsetMs: S }
  dense[4] = { sunriseMs: R }
  const accepted = Schedule.evaluate(S, { status: 'normal', cycles: dense }, settings())
  assert.equal(accepted.ok, true)
  assert.equal(accepted.sunsetMs, S)
  assert.equal(accepted.sunriseMs, R)

  const sparse = new Array(8)
  sparse[0] = { sunsetMs: S, sunriseMs: R }
  const accessor = []
  let accessorRead = false
  Object.defineProperty(accessor, '0', {
    configurable: true,
    get() { accessorRead = true; return { sunsetMs: S, sunriseMs: R } }
  })
  const arrayLike = Object.create(null)
  Object.defineProperty(arrayLike, 'length', {
    get() { throw new Error('array-like length must not be read') }
  })
  const revoked = Proxy.revocable([], {})
  revoked.revoke()

  const rejected = [
    sparse,
    accessor,
    Array.from({ length: 9 }, () => ({})),
    arrayLike,
    revoked.proxy,
    'not an event array'
  ]
  for (const collection of rejected) {
    const result = Schedule.evaluate(S, Object.assign(events(), { cycles: collection }), settings())
    assert.equal(result.ok, false)
    assert.equal(result.error.code, 'calculation-failed')
    assert.equal(result.target, null)
  }
  const polarWithCollection = Schedule.evaluate(S, {
    status: 'polar-day',
    cycles: Array.from({ length: 9 }, () => ({}))
  }, settings())
  assert.equal(polarWithCollection.ok, false)
  assert.equal(polarWithCollection.target, null)
  assert.equal(accessorRead, false)
})

test('maximum sparse event-array length is rejected within a hard subprocess timeout',
  { timeout: 4000 }, () => {
    const schedulePath = JSON.stringify(path.resolve(__dirname, '../ScheduleModel.js'))
    const script = `const s=require(${schedulePath});` +
      `const cycles=[];cycles.length=0xffffffff;` +
      `const result=s.evaluate(${S},{ok:true,status:'normal',sunsetMs:${S},` +
      `sunriseMs:${R},cycles},{automationEnabled:true,nightTemperature:4000,` +
      `transitionMinutes:60});` +
      `process.stdout.write(JSON.stringify(result));`
    const child = spawnSync(process.execPath, ['-e', script], {
      encoding: 'utf8', timeout: 1000
    })

    assert.equal(child.error, undefined, child.error && child.error.message)
    assert.equal(child.status, 0, child.stderr)
    const result = JSON.parse(child.stdout)
    assert.equal(result.ok, false)
    assert.equal(result.error.code, 'calculation-failed')
    assert.equal(result.target, null)
  })

test('event enums and retained polar events use exact own data properties', () => {
  for (const status of ['constructor', 'toString', {}, Symbol('normal')]) {
    const result = Schedule.evaluate(S, {
      status,
      sunsetMs: S,
      sunriseMs: R
    }, settings())
    assert.equal(result.ok, false)
    assert.equal(result.target, null)
  }

  const inheritedNext = Object.create({ kind: 'sunset', epochMs: S + HOUR })
  const polar = Schedule.evaluate(S, {
    status: 'polar-day',
    nextEvent: inheritedNext
  }, settings())
  assert.equal(polar.ok, true)
  assert.equal(polar.nextBoundaryMs, 0)

  const ownNext = Object.assign(Object.create({ kind: 'sunrise', epochMs: R }), {
    kind: 'sunset', epochMs: S + HOUR
  })
  const bounded = Schedule.evaluate(S, {
    status: 'polar-day',
    nextEvent: ownNext
  }, settings())
  assert.equal(bounded.ok, true)
  assert.equal(bounded.nextBoundaryMs, S + HOUR)
})

test('Object.prototype pollution cannot change defaults or supply a location', () => {
  const schedulePath = JSON.stringify(path.resolve(__dirname, '../ScheduleModel.js'))
  const script = `const s=require(${schedulePath});` +
    `const at=${S},rise=${R};` +
    `const pollution={automationEnabled:false,nightTemperature:1000,transitionMinutes:180,` +
    `ok:false,status:'polar-night',phase:'polar-night',kind:'sunrise',latitude:0,longitude:0,` +
    `sunsetMs:at,sunriseMs:rise,nextSunsetMs:at+1,nextSunriseMs:rise,` +
    `events:{status:'normal',sunsetMs:at,sunriseMs:rise},` +
    `solarEvents:{status:'normal',sunsetMs:at,sunriseMs:rise},` +
    `nextEvent:{kind:'sunset',epochMs:at+1},previousEvent:{kind:'sunset',epochMs:at-1}};` +
    `for(const key of Object.keys(pollution))Object.defineProperty(Object.prototype,key,` +
    `{configurable:true,enumerable:true,value:pollution[key],writable:true});` +
    `const defaults=s.validateSettings({});` +
    `const valid=s.evaluate(at,{status:'normal',sunsetMs:at,sunriseMs:rise},{});` +
    `const absent=s.evaluate(at,{},{});` +
    `process.stdout.write(JSON.stringify({defaults,valid,absent}));`
  const child = spawnSync(process.execPath, ['-e', script], {
    encoding: 'utf8', timeout: 2000
  })
  assert.equal(child.error, undefined, child.error && child.error.message)
  assert.equal(child.status, 0, child.stderr)
  const payload = JSON.parse(child.stdout)
  assert.deepEqual(payload.defaults.value, {
    automationEnabled: true,
    nightTemperature: 4000,
    transitionMinutes: 45
  })
  assert.equal(payload.valid.ok, true)
  assert.equal(payload.valid.phase, 'evening-transition')
  assert.equal(payload.absent.ok, false)
  assert.equal(payload.absent.target, null)
})

test('all positive-duration boundaries have exact phase, warmth, and target semantics', () => {
  const d = HOUR
  const cases = [
    [S - 1, 'day', 0, 'identity'],
    [S, 'evening-transition', 0, 'identity'],
    [S + 1, 'evening-transition', null, 'temperature'],
    [S + d / 2, 'evening-transition', 0.5, 'temperature'],
    [S + d, 'night', 1, 'temperature'],
    [R - d, 'night', 1, 'temperature'],
    [R - d / 2, 'morning-transition', 0.5, 'temperature'],
    [R - 1, 'morning-transition', null, 'temperature'],
    [R, 'day', 0, 'identity'],
    [R + 1, 'day', 0, 'identity']
  ]
  for (const [at, phase, warmth, kind] of cases) {
    const result = evaluate(at)
    assert.equal(result.phase, phase, new Date(at).toISOString())
    if (warmth !== null) close(result.warmth, warmth)
    assert.equal(result.target.kind, kind)
    assert.ok(result.target.temperature >= 4000 && result.target.temperature <= 6500)
  }

  assert.equal(evaluate(S).nextBoundaryMs, R)
  assert.equal(evaluate(S - 1).nextBoundaryMs, S)
  assert.equal(evaluate(R).nextBoundaryMs, 0)
})

test('smoothstep warmth is continuous and monotone on both transition edges', () => {
  let previous = -1
  for (let i = 0; i <= 1000; i++) {
    const result = evaluate(S + HOUR * i / 1000)
    assert.ok(result.warmth + 1e-15 >= previous)
    previous = result.warmth
  }
  close(previous, 1)

  previous = 2
  for (let i = 0; i <= 1000; i++) {
    const result = evaluate(R - HOUR + HOUR * i / 1000)
    assert.ok(result.warmth <= previous + 1e-15)
    previous = result.warmth
  }
  close(previous, 0)
})

test('instant transitions use the exact half-open astronomical night', () => {
  const instant = { transitionMinutes: 0 }
  for (const at of [S - 1, R, R + 1]) {
    const result = evaluate(at, instant)
    assert.equal(result.phase, 'day')
    assert.equal(result.warmth, 0)
    assert.equal(result.target.kind, 'identity')
  }
  for (const at of [S, S + 1, (S + R) / 2, R - 1]) {
    const result = evaluate(at, instant)
    assert.equal(result.phase, 'night')
    assert.equal(result.warmth, 1)
    assert.deepEqual(result.target, { kind: 'temperature', temperature: 4000 })
  }
})

test('short nights cap each transition at half the night without overlap', () => {
  const shortS = S
  const shortR = S + 10 * 60 * 1000
  const shortEvents = events(shortS, shortR)
  const before = evaluate(shortS + 5 * 60 * 1000 - 1, {}, shortEvents)
  const middle = evaluate(shortS + 5 * 60 * 1000, {}, shortEvents)
  const after = evaluate(shortS + 5 * 60 * 1000 + 1, {}, shortEvents)
  assert.equal(before.phase, 'evening-transition')
  assert.ok(before.warmth < 1)
  assert.equal(middle.phase, 'night')
  assert.equal(middle.warmth, 1)
  assert.equal(after.phase, 'morning-transition')
  assert.ok(after.warmth < 1)
})

test('transition targets are nearest-10 K, bounded, and wake at every meaningful change', () => {
  const samples = [S + 1, S + HOUR * 0.1, S + HOUR * 0.25, S + HOUR * 0.5,
    R - HOUR * 0.5, R - HOUR * 0.1, R - 1]
  for (const at of samples) {
    const result = evaluate(at)
    assert.equal(result.target.kind, 'temperature')
    assert.equal(result.target.temperature % 10, 0)
    assert.ok(result.target.temperature >= 4000 && result.target.temperature <= 6500)
    assert.ok(result.nextEvaluationMs <= at + 5000)
    const next = evaluate(result.nextEvaluationMs)
    assert.ok(next.target.temperature !== result.target.temperature ||
      next.target.kind !== result.target.kind || result.nextEvaluationMs === R ||
      result.nextEvaluationMs === at + 5000)
  }

  const atSunset = evaluate(S)
  assert.equal(atSunset.nextEvaluationMs, S + 1)
  assert.equal(evaluate(S + 1).target.kind, 'temperature')

  // Equality is still a genuine numeric night target once warmth is nonzero.
  const equal = evaluate(S + 1, { nightTemperature: 6500 })
  assert.deepEqual(equal.target, { kind: 'temperature', temperature: 6500 })
})

test('steady phases probe at 30 seconds or the next boundary, whichever comes first', () => {
  assert.equal(evaluate(S - 60000).nextEvaluationMs, S - 30000)
  assert.equal(evaluate(S - 1000).nextEvaluationMs, S)
  assert.equal(evaluate(S + 2 * HOUR).nextEvaluationMs, S + 2 * HOUR + 30000)
  assert.equal(evaluate(R - HOUR).nextEvaluationMs, R - HOUR + 30000)
})

test('minimum, maximum, and timer epochs stay inside the SolarModel input domain', () => {
  const minimum = -MAX_EVALUATION_EPOCH_MS
  const atMinimum = Schedule.evaluate(minimum, { latitude: 0, longitude: 0 }, settings())
  assert.equal(atMinimum.ok, true)
  assert.equal(atMinimum.nextEvaluationMs, minimum + 30000)
  assert.equal(Solar.surroundingEvents(atMinimum.nextEvaluationMs, 0, 0).ok, true)

  // With one millisecond left, clamping produces a valid final Solar wake
  // instead of the former out-of-domain timer.
  const beforeMaximum = Schedule.evaluate(
    MAX_EVALUATION_EPOCH_MS - 1, { latitude: 0, longitude: 0 }, settings())
  assert.equal(beforeMaximum.ok, true)
  assert.equal(beforeMaximum.nextEvaluationMs, MAX_EVALUATION_EPOCH_MS)
  assert.equal(Solar.surroundingEvents(beforeMaximum.nextEvaluationMs, 0, 0).ok, true)

  // The endpoint itself has no representable future wake.  It must fail before
  // emitting a target, regardless of whether coordinates or a valid snapshot
  // supplied the solar events.
  const maximumEvents = Solar.surroundingEvents(MAX_EVALUATION_EPOCH_MS, 0, 0)
  assert.equal(maximumEvents.ok, true)
  for (const location of [{ latitude: 0, longitude: 0 }, maximumEvents]) {
    const result = Schedule.evaluate(MAX_EVALUATION_EPOCH_MS, location, settings())
    assert.equal(result.ok, false)
    assert.equal(result.target, null)
    assert.equal(result.error.code, 'calculation-failed')
    assert.equal(result.nextEvaluationMs, 0)
  }

  for (const outside of [minimum - 1, MAX_EVALUATION_EPOCH_MS + 1]) {
    const result = Schedule.evaluate(outside, { latitude: 0, longitude: 0 }, settings())
    assert.equal(result.ok, false)
    assert.equal(result.target, null)
    assert.equal(result.nextEvaluationMs, 0)
  }

  const retry = Schedule.evaluate(
    MAX_EVALUATION_EPOCH_MS - 1, null, settings())
  assert.equal(retry.ok, false)
  assert.equal(retry.nextEvaluationMs, MAX_EVALUATION_EPOCH_MS)
  assert.equal(Solar.surroundingEvents(retry.nextEvaluationMs, 0, 0).ok, true)
})

test('reported extreme-min morning transition returns in a timeout-safe subprocess',
  { timeout: 5000 }, () => {
    const schedulePath = JSON.stringify(path.resolve(__dirname, '../ScheduleModel.js'))
    const solarPath = JSON.stringify(path.resolve(__dirname, '../SolarModel.js'))
    const script = `const Schedule=require(${schedulePath});const Solar=require(${solarPath});` +
      `const M=8640000000000000-(370+2)*86400000;const at=-M;` +
      `const events=Solar.surroundingEvents(at,-75,60);` +
      `const result=Schedule.evaluate(at,events,{automationEnabled:true,` +
      `nightTemperature:4000,transitionMinutes:45});` +
      `process.stdout.write(JSON.stringify({at,events,result}));`
    const child = spawnSync(process.execPath, ['-e', script], {
      encoding: 'utf8', timeout: 2000
    })

    assert.equal(child.error, undefined, child.error && child.error.message)
    assert.equal(child.status, 0, child.stderr)
    const payload = JSON.parse(child.stdout)
    assert.equal(payload.at, -MAX_EVALUATION_EPOCH_MS)
    assert.deepEqual(
      [payload.events.status, payload.events.sunsetMs, payload.events.sunriseMs],
      ['normal', -8639967886181493, -8639967858946822])
    assert.equal(payload.result.ok, true)
    assert.equal(payload.result.phase, 'morning-transition')
    assert.deepEqual(payload.result.target, { kind: 'temperature', temperature: 6440 })
    assert.equal(payload.result.nextEvaluationMs, payload.at + 5000)
  })

test('minimum and maximum epoch grids preserve composition and bounded wakes',
  { timeout: 20000 }, () => {
    // Keep the property sweep in a killable process: it deliberately exercises
    // transition searches at the same extreme epochs as the livelock fixture.
    const schedulePath = JSON.stringify(path.resolve(__dirname, '../ScheduleModel.js'))
    const solarPath = JSON.stringify(path.resolve(__dirname, '../SolarModel.js'))
    const script = `const Schedule=require(${schedulePath});const Solar=require(${solarPath});` +
      `const M=8640000000000000-(370+2)*86400000;` +
      `const configs=[` +
      `{automationEnabled:true,nightTemperature:1000,transitionMinutes:0},` +
      `{automationEnabled:true,nightTemperature:1000,transitionMinutes:180},` +
      `{automationEnabled:true,nightTemperature:6500,transitionMinutes:0},` +
      `{automationEnabled:true,nightTemperature:6500,transitionMinutes:180}];` +
      `let count=0;function check(value,message){if(!value)throw new Error(message)}` +
      `for(let lat=-90;lat<=90;lat+=15)for(let lon=-180;lon<=180;lon+=60){` +
      `for(const at of [-M,M-1]){const events=Solar.surroundingEvents(at,lat,lon);` +
      `check(events.ok,'solar '+at+' '+lat+' '+lon);` +
      `for(const config of configs){const direct=Schedule.evaluate(at,{latitude:lat,longitude:lon},config);` +
      `const composed=Schedule.evaluate(at,events,config);` +
      `check(JSON.stringify(direct)===JSON.stringify(composed),'composition '+at+' '+lat+' '+lon);` +
      `check(direct.ok&&direct.target!==null,'target '+at+' '+lat+' '+lon);` +
      `check(direct.warmth>=0&&direct.warmth<=1,'warmth '+at+' '+lat+' '+lon);` +
      `check(direct.target.temperature>=config.nightTemperature&&direct.target.temperature<=6500,` +
      `'temperature '+at+' '+lat+' '+lon);` +
      `check(direct.nextEvaluationMs>at&&direct.nextEvaluationMs<=M,'wake '+at+' '+lat+' '+lon);` +
      `check(Solar.surroundingEvents(direct.nextEvaluationMs,lat,lon).ok,` +
      `'solar wake '+at+' '+lat+' '+lon);count++}}` +
      `const maximumEvents=Solar.surroundingEvents(M,lat,lon);` +
      `check(maximumEvents.ok,'solar maximum '+lat+' '+lon);` +
      `for(const location of [{latitude:lat,longitude:lon},maximumEvents]){` +
      `const result=Schedule.evaluate(M,location,configs[1]);` +
      `check(!result.ok&&result.target===null&&result.nextEvaluationMs===0,` +
      `'closed maximum '+lat+' '+lon)}}process.stdout.write(String(count));`
    const child = spawnSync(process.execPath, ['-e', script], {
      encoding: 'utf8', timeout: 15000
    })

    assert.equal(child.error, undefined, child.error && child.error.message)
    assert.equal(child.status, 0, child.stderr)
    assert.equal(Number(child.stdout), 13 * 7 * 2 * 4)
  })

test('polar day holds identity and polar night holds configured full warmth', () => {
  const nextSet = S + 90 * 86400000
  const nextRise = S + 70 * 86400000
  const day = Schedule.evaluate(S, {
    ok: true, status: 'polar-day', nextSunsetMs: nextSet
  }, settings())
  assert.equal(day.ok, true)
  assert.equal(day.phase, 'polar-day')
  assert.equal(day.warmth, 0)
  assert.deepEqual(day.target, { kind: 'identity', temperature: 6500 })
  assert.equal(day.nextBoundaryMs, nextSet)

  const night = Schedule.evaluate(S, {
    ok: true, status: 'polar-night', nextSunriseMs: nextRise
  }, settings({ nightTemperature: 3250 }))
  assert.equal(night.ok, true)
  assert.equal(night.phase, 'polar-night')
  assert.equal(night.warmth, 1)
  assert.deepEqual(night.target, { kind: 'temperature', temperature: 3250 })
  assert.equal(night.nextBoundaryMs, nextRise)
})

test('real polar-night seams apply positive durations at the exact retained events', () => {
  const fixtures = [
    ['Tromso', Date.parse('2024-12-21T12:00:00Z'), 69.6492, 18.9553],
    ['Antarctic 69 south', Date.parse('2024-06-21T12:00:00Z'), -69, 0]
  ]

  for (const [name, interiorAt, latitude, longitude] of fixtures) {
    const interiorEvents = Solar.surroundingEvents(interiorAt, latitude, longitude)
    assert.equal(interiorEvents.status, 'polar-night', name)
    assert.equal(interiorEvents.sunsetMs, null, name)
    assert.equal(interiorEvents.sunriseMs, null, name)
    assert.equal(interiorEvents.previousEvent.kind, 'sunset', name)
    assert.equal(interiorEvents.nextEvent.kind, 'sunrise', name)
    const sunsetMs = interiorEvents.previousEvent.epochMs
    const sunriseMs = interiorEvents.nextEvent.epochMs

    for (const transitionMinutes of [1, 45, 180]) {
      const durationMs = transitionMinutes * 60000
      const configured = settings({ transitionMinutes })
      const cases = [
        [sunsetMs - 1, 'day', 0, 'identity'],
        [sunsetMs, 'evening-transition', 0, 'identity'],
        [sunsetMs + 1, 'evening-transition', null, 'temperature'],
        [sunsetMs + durationMs / 2, 'evening-transition', 0.5, 'temperature'],
        [sunsetMs + durationMs, 'polar-night', 1, 'temperature'],
        [(sunsetMs + sunriseMs) / 2, 'polar-night', 1, 'temperature'],
        [sunriseMs - durationMs, 'polar-night', 1, 'temperature'],
        [sunriseMs - durationMs / 2, 'morning-transition', 0.5, 'temperature'],
        [sunriseMs - 1, 'morning-transition', null, 'temperature'],
        [sunriseMs, 'day', 0, 'identity'],
        [sunriseMs + 1, 'day', 0, 'identity']
      ]

      for (const [at, phase, warmth, targetKind] of cases) {
        const snapshot = Solar.surroundingEvents(at, latitude, longitude)
        const direct = Schedule.evaluate(at, { latitude, longitude }, configured)
        const composed = Schedule.evaluate(at, snapshot, configured)
        assert.deepEqual(direct, composed, `${name} ${transitionMinutes}m ${at}`)
        assert.equal(direct.ok, true, name)
        assert.equal(direct.phase, phase, `${name} ${transitionMinutes}m ${at}`)
        if (warmth !== null) close(direct.warmth, warmth)
        else assert.ok(direct.warmth > 0 && direct.warmth < 1, name)
        assert.equal(direct.target.kind, targetKind, name)
        assert.ok(direct.nextEvaluationMs > at, name)
      }
    }
  }
})

test('dense real polar-night seam composition is continuous and follows smoothstep',
  { timeout: 30000 }, () => {
    const fixtures = [
      ['Tromso', Date.parse('2024-12-21T12:00:00Z'), 69.6492, 18.9553],
      ['Antarctic 69 south', Date.parse('2024-06-21T12:00:00Z'), -69, 0]
    ]
    const configured = settings({ transitionMinutes: 45 })
    const durationMs = configured.transitionMinutes * 60000
    const steps = 2700 // One real composed sample per second on each edge.

    for (const [name, interiorAt, latitude, longitude] of fixtures) {
      const interiorEvents = Solar.surroundingEvents(interiorAt, latitude, longitude)
      const sunsetMs = interiorEvents.previousEvent.epochMs
      const sunriseMs = interiorEvents.nextEvent.epochMs
      let previousEvening = -1
      let previousMorning = 2

      for (let i = 0; i <= steps; i++) {
        const progress = i / steps
        const eveningAt = sunsetMs + durationMs * progress
        const eveningEvents = Solar.surroundingEvents(eveningAt, latitude, longitude)
        const evening = Schedule.evaluate(eveningAt, eveningEvents, configured)
        const expectedEvening = progress * progress * (3 - 2 * progress)
        close(evening.warmth, expectedEvening)
        assert.ok(evening.warmth + 1e-15 >= previousEvening, name)
        previousEvening = evening.warmth
        assert.equal(eveningEvents.status, 'polar-night', name)
        assert.equal(eveningEvents.sunsetMs, null, name)
        assert.equal(eveningEvents.sunriseMs, null, name)
        assert.equal(evening.sunsetMs, sunsetMs, name)
        assert.equal(evening.sunriseMs, sunriseMs, name)
        assert.deepEqual(evening,
          Schedule.evaluate(eveningAt, { latitude, longitude }, configured), name)

        const morningAt = sunriseMs - durationMs + durationMs * progress
        const morningEvents = Solar.surroundingEvents(morningAt, latitude, longitude)
        const morning = Schedule.evaluate(morningAt, morningEvents, configured)
        const remaining = 1 - progress
        const expectedMorning = remaining * remaining * (3 - 2 * remaining)
        close(morning.warmth, expectedMorning)
        assert.ok(morning.warmth <= previousMorning + 1e-15, name)
        previousMorning = morning.warmth
        if (i < steps) {
          assert.equal(morningEvents.status, 'polar-night', name)
          assert.equal(morningEvents.sunsetMs, null, name)
          assert.equal(morningEvents.sunriseMs, null, name)
          assert.equal(morning.sunsetMs, sunsetMs, name)
          assert.equal(morning.sunriseMs, sunriseMs, name)
        } else {
          assert.equal(morningEvents.status, 'normal', name)
        }
        assert.deepEqual(morning,
          Schedule.evaluate(morningAt, { latitude, longitude }, configured), name)
      }
    }
  })

test('invalid epoch, location, event chronology, status, and settings emit no target', () => {
  const failures = [
    Schedule.evaluate(NaN, events(), settings()),
    Schedule.evaluate(Infinity, events(), settings()),
    Schedule.evaluate(8640000000000000, events(), settings()),
    Schedule.evaluate(S, null, settings()),
    Schedule.evaluate(S, { latitude: 91, longitude: 0 }, settings()),
    Schedule.evaluate(S, { status: 'normal', sunsetMs: R, sunriseMs: S }, settings()),
    Schedule.evaluate(S, { status: 'error' }, settings()),
    Schedule.evaluate(S, events(), settings({ transitionMinutes: -1 }))
  ]
  for (const result of failures) {
    assert.equal(result.ok, false)
    assert.equal(result.phase, 'error')
    assert.equal(result.target, null)
    assert.equal(result.warmth, 0)
    for (const key of ['sunsetMs', 'sunriseMs', 'nextBoundaryMs', 'nextEvaluationMs'])
      assert.ok(Number.isFinite(result[key]))
  }
})

test('evaluation is history-free across forward, backward, and suspend-sized clock jumps', () => {
  const before = evaluate(S - HOUR)
  const afterSuspend = evaluate(R - HOUR / 2)
  const jumpedBack = evaluate(S + HOUR / 4)
  assert.equal(before.phase, 'day')
  assert.equal(afterSuspend.phase, 'morning-transition')
  assert.equal(jumpedBack.phase, 'evening-transition')
  assert.deepEqual(evaluate(R - HOUR / 2), afterSuspend)
  assert.deepEqual(evaluate(S + HOUR / 4), jumpedBack)
})

test('calendar, UTC-midnight, leap-day, and New Year crossings use only epoch ordering', () => {
  const pairs = [
    ['2024-02-29T23:00:00Z', '2024-03-01T05:00:00Z'],
    ['2024-12-31T22:00:00Z', '2025-01-01T07:00:00Z'],
    ['2024-01-31T23:59:00Z', '2024-02-01T00:01:00Z']
  ]
  for (const [sunset, sunrise] of pairs) {
    const sunsetMs = Date.parse(sunset)
    const sunriseMs = Date.parse(sunrise)
    const middle = (sunsetMs + sunriseMs) / 2
    const result = evaluate(middle, { transitionMinutes: 180 }, events(sunsetMs, sunriseMs))
    assert.equal(result.phase, 'night')
    assert.equal(result.warmth, 1)
  }
})

test('synthetic schedule output is byte-identical in every host timezone', () => {
  const script = `const s=require(${JSON.stringify(path.resolve(__dirname, '../ScheduleModel.js'))});` +
    `process.stdout.write(JSON.stringify(s.evaluate(${S + HOUR / 2},` +
    `${JSON.stringify(events())},${JSON.stringify(settings())})))`
  const zones = ['UTC', 'Europe/Amsterdam', 'America/New_York', 'Asia/Kathmandu',
    'Pacific/Kiritimati', 'Pacific/Honolulu']
  const outputs = zones.map(TZ => {
    const child = spawnSync(process.execPath, ['-e', script], {
      encoding: 'utf8', env: Object.assign({}, process.env, { TZ })
    })
    assert.equal(child.status, 0, child.stderr)
    return child.stdout
  })
  for (const output of outputs) assert.equal(output, outputs[0])
})

test('real SolarModel events integrate through coordinates and explicit event snapshots', () => {
  const fixtures = [
    [Date.parse('2024-03-20T12:00:00Z'), 51.4779, 0],
    [Date.parse('2024-06-21T16:00:00Z'), 40.7128, -74.006],
    [Date.parse('2024-12-21T00:00:00Z'), -33.8688, 151.2093],
    [Date.parse('2024-06-21T12:00:00Z'), 69.6492, 18.9553],
    [Date.parse('2024-12-21T12:00:00Z'), 69.6492, 18.9553]
  ]
  for (const [at, latitude, longitude] of fixtures) {
    const direct = Schedule.evaluate(at, { latitude, longitude }, settings())
    assert.equal(direct.ok, true, direct.error && direct.error.message)
    assert.ok(['day', 'evening-transition', 'night', 'morning-transition',
      'polar-day', 'polar-night'].includes(direct.phase))

    const snapshot = Solar.surroundingEvents(at, latitude, longitude)
    const fromSnapshot = Schedule.evaluate(at, snapshot, settings())
    assert.equal(fromSnapshot.ok, true, fromSnapshot.error && fromSnapshot.error.message)
    assert.equal(fromSnapshot.phase, direct.phase)
    assert.equal(fromSnapshot.warmth, direct.warmth)
    assert.deepEqual(fromSnapshot.target, direct.target)
  }
})

test('dense near-pole seasons and retained event seams compose without orphan failures',
  { timeout: 30000 }, () => {
    const years = [1900, 1950, 2000, 2024, 2050, 2100]
    const configured = settings({ transitionMinutes: 45 })
    const retainedEvents = new Map()
    let seasonalSamples = 0

    function assertComposition(at, latitude, longitude, label) {
      const snapshot = Solar.surroundingEvents(at, latitude, longitude)
      assert.equal(snapshot.ok, true, label)
      assert.ok(['normal', 'polar-day', 'polar-night'].includes(snapshot.status), label)

      if (snapshot.previousEvent) {
        assert.ok(snapshot.previousEvent.epochMs <= at, label)
        retainedEvents.set(`${latitude}:${snapshot.previousEvent.kind}:${snapshot.previousEvent.epochMs}`,
          { latitude, longitude, event: snapshot.previousEvent })
      }
      if (snapshot.nextEvent) {
        assert.ok(snapshot.nextEvent.epochMs > at, label)
        retainedEvents.set(`${latitude}:${snapshot.nextEvent.kind}:${snapshot.nextEvent.epochMs}`,
          { latitude, longitude, event: snapshot.nextEvent })
      }
      if (snapshot.previousEvent && snapshot.nextEvent) {
        assert.notEqual(snapshot.previousEvent.kind, snapshot.nextEvent.kind,
          `${label} adjacent real events alternate`)
      }

      if (snapshot.status === 'normal') {
        assert.ok(Number.isFinite(snapshot.sunsetMs), label)
        assert.ok(Number.isFinite(snapshot.sunriseMs), label)
        assert.ok(snapshot.sunsetMs < snapshot.sunriseMs, label)
      } else {
        assert.equal(snapshot.sunsetMs, null, label)
        assert.equal(snapshot.sunriseMs, null, label)
        assert.equal(snapshot.isDay, snapshot.status === 'polar-day', label)
      }

      const direct = Schedule.evaluate(at, { latitude, longitude }, configured)
      const composed = Schedule.evaluate(at, snapshot, configured)
      assert.equal(direct.ok, true, label)
      assert.deepEqual(direct, composed, label)
      assert.ok(direct.nextEvaluationMs > at, label)
      assert.notEqual(direct.target, null, label)
    }

    for (const year of years) {
      for (const hemisphere of [-1, 1]) {
        for (let hundredths = 8900; hundredths <= 9000; hundredths++) {
          const latitude = hemisphere * hundredths / 100
          for (let month = 0; month < 12; month++) {
            const at = Date.UTC(year, month, 15, 12)
            assertComposition(at, latitude, 0,
              `${year}-${month + 1} latitude ${latitude}`)
            seasonalSamples++
          }
        }
      }
    }

    // Every actual event retained by the seasonal snapshots remains coherent
    // on both sides of the model's half-open event boundary.
    const seamEvents = Array.from(retainedEvents.values())
    for (const item of seamEvents) {
      for (const offset of [-1, 0, 1]) {
        const at = item.event.epochMs + offset
        assertComposition(at, item.latitude, item.longitude,
          `latitude ${item.latitude} ${item.event.kind} ${offset}`)
      }
    }

    assert.equal(seasonalSamples, 14544)
    assert.ok(retainedEvents.size > 100)
  })
