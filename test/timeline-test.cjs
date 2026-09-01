'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const Timeline = require('../TimelineModel.js')

const DAY_MS = 86400000
const DATE_KEY = '2026-09-01'

function projected(overrides = {}) {
  return Object.assign({
    epochMs: 1788238305216,
    dateKey: DATE_KEY,
    wallMs: 24705216,
    offsetMinutes: 120,
    fold: 0,
    ambiguous: false
  }, overrides)
}

function event(kind, epochMs, wallMs, overrides = {}) {
  return Object.assign(projected({ epochMs, wallMs }), { kind }, overrides)
}

function input(overrides = {}) {
  return Object.assign({
    revision: 7,
    dateKey: DATE_KEY,
    zoneId: 'Europe/Amsterdam',
    zoneSource: 'location',
    nowMs: 1788273420000,
    markerWallMs: 59820000,
    markerOffsetMinutes: 120,
    markerFold: 0,
    markerAmbiguous: false,
    status: 'normal',
    stateAtMidnight: 'night',
    events: [
      event('sunrise', 1788238305216, 24705216),
      event('sunset', 1788287423925, 73823925)
    ],
    displayTimes: {
      sunset: null,
      sunrise: null,
      nextBoundary: null,
      overrideUntil: null
    }
  }, overrides)
}

function snapshot(overrides = {}) {
  const result = Timeline.buildSnapshot(input(overrides))
  assert.equal(result.ok, true)
  return result.snapshot
}

function invalid(value) {
  assert.deepEqual(Timeline.buildSnapshot(value), {
    ok: false,
    error: 'invalid-timeline'
  })
}

function wall(hours, minutes, seconds = 0, milliseconds = 0) {
  return ((hours * 60 + minutes) * 60 + seconds) * 1000 + milliseconds
}

test('exports exactly the frozen API and the same source loads without CommonJS in QML style', () => {
  assert.deepEqual(Object.keys(Timeline).sort(), [
    'buildSnapshot',
    'positionForWallMs',
    'shouldAnimateMarker'
  ])

  const source = fs.readFileSync(path.resolve(__dirname, '../TimelineModel.js'), 'utf8')
  const context = vm.createContext({})
  assert.doesNotThrow(() => vm.runInContext(source, context, { filename: 'TimelineModel.js' }))
  assert.equal(typeof context.buildSnapshot, 'function')
  assert.equal(typeof context.positionForWallMs, 'function')
  assert.equal(typeof context.shouldAnimateMarker, 'function')
  assert.equal(context.positionForWallMs(43200000), 0.5)
})

test('positionForWallMs is exact on the closed nominal day and rejects every other type', () => {
  assert.ok(Object.is(Timeline.positionForWallMs(-0), -0))
  assert.equal(Timeline.positionForWallMs(0), 0)
  assert.equal(Timeline.positionForWallMs(DAY_MS), 1)
  assert.equal(Timeline.positionForWallMs(1), 1 / DAY_MS)
  assert.equal(Timeline.positionForWallMs(12345678.901), 12345678.901 / DAY_MS)

  for (const value of [undefined, null, false, true, '', '1', [], {}, NaN,
    Infinity, -Infinity, -1, DAY_MS + Number.EPSILON * DAY_MS]) {
    assert.equal(Timeline.positionForWallMs(value), null, String(value))
  }
})

test('reference wall positions and installed Hilversum fixture use civil-day geometry', () => {
  const references = [
    [2, 2, 0.08472222222222223],
    [9, 2, 0.3763888888888889],
    [12, 2, 0.5013888888888889],
    [19, 2, 0.7930555555555555],
    [20, 2, 0.8347222222222223],
    [4, 43, 0.19652777777777777],
    [11, 43, 0.48819444444444443],
    [18, 43, 0.7798611111111111]
  ]
  for (const [hours, minutes, expected] of references)
    assert.equal(Timeline.positionForWallMs(wall(hours, minutes)), expected)

  const result = snapshot()
  assert.ok(Math.abs(Timeline.positionForWallMs(result.events[0].wallMs) - 0.28594) < 0.0001)
  assert.ok(Math.abs(Timeline.positionForWallMs(result.markerWallMs) - 0.69236) < 0.0001)
  assert.ok(Math.abs(Timeline.positionForWallMs(result.events[1].wallMs) - 0.85444) < 0.0001)
})

test('the frozen reference snapshot is canonical, exact, newly allocated, and immutable', () => {
  const raw = input()
  const before = JSON.stringify(raw)
  const result = Timeline.buildSnapshot(raw)
  assert.deepEqual(result, {
    ok: true,
    snapshot: {
      revision: 7,
      dateKey: DATE_KEY,
      zoneId: 'Europe/Amsterdam',
      zoneSource: 'location',
      nowMs: 1788273420000,
      markerWallMs: 59820000,
      markerOffsetMinutes: 120,
      markerFold: 0,
      markerAmbiguous: false,
      status: 'normal',
      stateAtMidnight: 'night',
      isDayNow: true,
      events: [
        {
          key: 'sunrise:1788238305216:120:0',
          kind: 'sunrise',
          epochMs: 1788238305216,
          dateKey: DATE_KEY,
          wallMs: 24705216,
          offsetMinutes: 120,
          fold: 0,
          ambiguous: false
        },
        {
          key: 'sunset:1788287423925:120:0',
          kind: 'sunset',
          epochMs: 1788287423925,
          dateKey: DATE_KEY,
          wallMs: 73823925,
          offsetMinutes: 120,
          fold: 0,
          ambiguous: false
        }
      ],
      daylightSegments: [{ startWallMs: 24705216, endWallMs: 73823925 }],
      displayTimes: Object.assign(Object.create(null), {
        sunset: null,
        sunrise: null,
        nextBoundary: null,
        overrideUntil: null
      })
    }
  })
  assert.equal(JSON.stringify(raw), before)
  assert.notStrictEqual(result.snapshot, raw)
  assert.notStrictEqual(result.snapshot.events, raw.events)
  assert.notStrictEqual(result.snapshot.events[0], raw.events[0])
  assert.equal(Object.isFrozen(result), true)
  assert.equal(Object.isFrozen(result.snapshot), true)
  assert.equal(Object.isFrozen(result.snapshot.events[0]), true)
})

test('sunrise and sunset have exact half-open current-state semantics', () => {
  const sunrise = input().events[0].epochMs
  const sunset = input().events[1].epochMs
  assert.equal(snapshot({ nowMs: sunrise - 1 }).isDayNow, false)
  assert.equal(snapshot({ nowMs: sunrise }).isDayNow, true)
  assert.equal(snapshot({ nowMs: sunset - 1 }).isDayNow, true)
  assert.equal(snapshot({ nowMs: sunset }).isDayNow, false)
})

test('polar, eventless normal, unavailable, and one-event seams never fabricate events', () => {
  const full = snapshot({ status: 'polar-day', stateAtMidnight: 'day', events: [] })
  assert.equal(full.isDayNow, true)
  assert.deepEqual(full.daylightSegments, [{ startWallMs: 0, endWallMs: DAY_MS }])
  assert.deepEqual(full.events, [])

  const empty = snapshot({ status: 'polar-night', stateAtMidnight: 'night', events: [] })
  assert.equal(empty.isDayNow, false)
  assert.deepEqual(empty.daylightSegments, [])

  assert.deepEqual(snapshot({ stateAtMidnight: 'day', events: [] }).daylightSegments,
    [{ startWallMs: 0, endWallMs: DAY_MS }])
  assert.deepEqual(snapshot({ stateAtMidnight: 'night', events: [] }).daylightSegments, [])

  const rise = event('sunrise', 1000, wall(6, 0))
  const riseOnly = snapshot({ nowMs: 999, events: [rise] })
  assert.deepEqual(riseOnly.daylightSegments,
    [{ startWallMs: wall(6, 0), endWallMs: DAY_MS }])
  assert.equal(riseOnly.isDayNow, false)
  assert.equal(snapshot({ nowMs: 1000, events: [rise] }).isDayNow, true)

  const set = event('sunset', 2000, wall(20, 0))
  const setOnly = snapshot({ stateAtMidnight: 'day', nowMs: 1999, events: [set] })
  assert.deepEqual(setOnly.daylightSegments,
    [{ startWallMs: 0, endWallMs: wall(20, 0) }])
  assert.equal(setOnly.isDayNow, true)
  assert.equal(snapshot({ stateAtMidnight: 'day', nowMs: 2000, events: [set] }).isDayNow, false)

  const unavailable = snapshot({
    status: 'unavailable', stateAtMidnight: null, events: []
  })
  assert.equal(unavailable.isDayNow, false)
  assert.deepEqual(unavailable.daylightSegments, [])
})

test('wrapped, merged, edge, short, and same-wall fold geometry stays bounded', () => {
  const wrapped = snapshot({ events: [
    event('sunrise', 1000, wall(20, 0)),
    event('sunset', 2000, wall(4, 0))
  ] })
  assert.deepEqual(wrapped.daylightSegments, [
    { startWallMs: 0, endWallMs: wall(4, 0) },
    { startWallMs: wall(20, 0), endWallMs: DAY_MS }
  ])

  const short = snapshot({ events: [
    event('sunrise', 1000, wall(11, 59)),
    event('sunset', 2000, wall(12, 1))
  ] })
  assert.deepEqual(short.daylightSegments, [
    { startWallMs: wall(11, 59), endWallMs: wall(12, 1) }
  ])

  assert.deepEqual(snapshot({ events: [
    event('sunrise', 1000, 0),
    event('sunset', 2000, DAY_MS - 1)
  ] }).daylightSegments, [{ startWallMs: 0, endWallMs: DAY_MS - 1 }])

  const folded = snapshot({ events: [
    event('sunrise', 1000, wall(1, 30), { offsetMinutes: -240, fold: 0, ambiguous: true }),
    event('sunset', 2000, wall(1, 30), { offsetMinutes: -300, fold: 1, ambiguous: true })
  ] })
  assert.equal(folded.events.length, 2)
  assert.notEqual(folded.events[0].key, folded.events[1].key)
  assert.deepEqual(folded.daylightSegments, [])
})

test('display times accept only named projected values and preserve different civil dates', () => {
  let unknownRead = false
  const times = {
    sunset: projected({ epochMs: 100, wallMs: wall(20, 30) }),
    nextBoundary: projected({
      epochMs: 200,
      dateKey: '2026-09-02',
      wallMs: wall(6, 53),
      offsetMinutes: 60,
      fold: 1,
      ambiguous: true
    }),
    ignored: projected()
  }
  Object.defineProperty(times, 'hostileUnknown', {
    enumerable: true,
    get() { unknownRead = true; throw new Error('unknown key read') }
  })
  const result = snapshot({ displayTimes: times })
  assert.deepEqual(Object.keys(result.displayTimes), ['sunset', 'nextBoundary'])
  assert.deepEqual(result.displayTimes.nextBoundary, {
    epochMs: 200,
    dateKey: '2026-09-02',
    wallMs: wall(6, 53),
    offsetMinutes: 60,
    fold: 1,
    ambiguous: true
  })
  assert.equal(unknownRead, false)

  for (const bad of [
    projected({ epochMs: NaN }), projected({ dateKey: '2026-02-30' }),
    projected({ wallMs: DAY_MS }), projected({ offsetMinutes: 1441 }),
    projected({ fold: 2 }), projected({ ambiguous: 0 })
  ]) invalid(input({ displayTimes: { sunrise: bad } }))
})

test('an own accessor at a known displayTimes name is malformed without invocation', () => {
  const times = {}
  let getterCalls = 0
  Object.defineProperty(times, 'sunrise', {
    configurable: true,
    enumerable: true,
    get() {
      getterCalls++
      throw new Error('known display time getter must not execute')
    }
  })

  assert.deepEqual(Object.keys(times), ['sunrise'])
  invalid(input({ displayTimes: times }))
  assert.equal(getterCalls, 0)
})

test('strict scalar schemas reject malformed, non-finite, unsafe, and out-of-range values', () => {
  const mutations = [
    ['revision', -1], ['revision', 1.5], ['revision', Number.MAX_SAFE_INTEGER + 1],
    ['revision', true], ['dateKey', '2026-9-01'], ['dateKey', '2026-02-29'],
    ['dateKey', '0000-01-01'], ['zoneId', ''], ['zoneId', 'x'.repeat(81)],
    ['zoneId', null], ['zoneSource', 'weather'], ['zoneSource', 'toString'],
    ['nowMs', NaN], ['nowMs', Infinity], ['nowMs', 8640000000000001],
    ['markerWallMs', -1], ['markerWallMs', DAY_MS], ['markerWallMs', true],
    ['markerOffsetMinutes', -1441], ['markerOffsetMinutes', 1441],
    ['markerOffsetMinutes', 1.5], ['markerFold', 2],
    ['markerFold', false], ['markerAmbiguous', 0], ['status', 'polar_day'],
    ['status', 'constructor'], ['stateAtMidnight', 'twilight']
  ]
  for (const [name, value] of mutations) invalid(input({ [name]: value }))

  assert.equal(Timeline.buildSnapshot(input({ dateKey: '2024-02-29', events: [] })).ok, true)
  assert.equal(Timeline.buildSnapshot(input({ revision: Number.MAX_SAFE_INTEGER })).ok, true)
  assert.equal(Timeline.buildSnapshot(input({ nowMs: -8640000000000000 })).ok, true)
  assert.equal(Timeline.buildSnapshot(input({ nowMs: 8640000000000000 })).ok, true)
  assert.equal(Timeline.buildSnapshot(input({ markerOffsetMinutes: -1440 })).ok, true)
  assert.equal(Timeline.buildSnapshot(input({ markerOffsetMinutes: 1440 })).ok, true)
})

test('event arrays, chronology, dates, kinds, state changes, and projected fields fail closed', () => {
  const sunrise = event('sunrise', 1000, wall(6, 0))
  const sunset = event('sunset', 2000, wall(20, 0))
  const invalidEvents = [
    null, {}, 'events', new Array(2),
    [sunrise, sunset, event('sunrise', 3000, wall(23, 0))],
    [sunset],
    [sunrise, event('sunrise', 2000, wall(7, 0))],
    [sunrise, event('sunset', 1000, wall(20, 0))],
    [sunrise, event('sunset', 999, wall(20, 0))],
    [event('dawn', 1000, wall(6, 0))],
    [event('toString', 1000, wall(6, 0))],
    [event('sunrise', 1000, wall(6, 0), { dateKey: '2026-09-02' })],
    [event('sunrise', NaN, wall(6, 0))],
    [event('sunrise', 1000, DAY_MS)],
    [event('sunrise', 1000, wall(6, 0), { offsetMinutes: 1.5 })],
    [event('sunrise', 1000, wall(6, 0), { fold: false })],
    [event('sunrise', 1000, wall(6, 0), { ambiguous: 'false' })]
  ]
  for (const events of invalidEvents) invalid(input({ events }))

  invalid(input({ stateAtMidnight: 'day', events: [sunrise] }))
  invalid(input({ status: 'polar-day', stateAtMidnight: 'night', events: [] }))
  invalid(input({ status: 'polar-night', stateAtMidnight: 'day', events: [] }))
  invalid(input({ status: 'unavailable', stateAtMidnight: null, events: [sunrise] }))
})

test('required fields must be own data properties and caller accessors are never invoked', () => {
  for (const name of [
    'revision', 'dateKey', 'zoneId', 'zoneSource', 'nowMs', 'markerWallMs',
    'markerOffsetMinutes', 'markerFold', 'markerAmbiguous', 'status',
    'stateAtMidnight', 'events', 'displayTimes'
  ]) {
    const value = input()
    delete value[name]
    invalid(value)
  }

  invalid(Object.create(input()))
  const inheritedPartial = { revision: 7 }
  Object.setPrototypeOf(inheritedPartial, input())
  invalid(inheritedPartial)

  for (const target of [input(), event('sunrise', 1000, wall(6, 0)), projected()]) {
    const property = target.kind ? 'epochMs' : (target.revision === 7 ? 'nowMs' : 'wallMs')
    let read = false
    Object.defineProperty(target, property, {
      enumerable: true,
      get() { read = true; throw new Error('must not execute') }
    })
    if (target.kind) invalid(input({ events: [target] }))
    else if (target.revision === 7) invalid(target)
    else invalid(input({ displayTimes: { sunrise: target } }))
    assert.equal(read, false)
  }

  const accessorArray = []
  let itemRead = false
  Object.defineProperty(accessorArray, '0', {
    get() { itemRead = true; return event('sunrise', 1000, wall(6, 0)) }
  })
  invalid(input({ events: accessorArray }))
  assert.equal(itemRead, false)

  const revoked = Proxy.revocable({}, {})
  revoked.revoke()
  invalid(revoked.proxy)
  const revokedArray = Proxy.revocable([], {})
  revokedArray.revoke()
  invalid(input({ events: revokedArray.proxy }))
})

test('displayTimes defines every named field through hostile setters and non-writable prototypes', () => {
  const rawTimes = {
    sunset: null,
    sunrise: projected({ epochMs: 101, wallMs: wall(6, 1) }),
    nextBoundary: null,
    overrideUntil: projected({
      epochMs: 202,
      dateKey: '2026-09-02',
      wallMs: wall(7, 2),
      offsetMinutes: 60,
      fold: 1,
      ambiguous: true
    })
  }
  const raw = input({ displayTimes: rawTimes })
  let setterCalls = 0
  let result
  Object.defineProperty(Object.prototype, 'sunset', {
    configurable: true,
    enumerable: true,
    value: 'hostile non-writable sunset',
    writable: false
  })
  Object.defineProperty(Object.prototype, 'sunrise', {
    configurable: true,
    enumerable: true,
    get() { return 'hostile getter sunrise' },
    set() { setterCalls++ }
  })
  Object.defineProperty(Object.prototype, 'nextBoundary', {
    configurable: true,
    enumerable: true,
    value: 'hostile non-writable boundary',
    writable: false
  })
  Object.defineProperty(Object.prototype, 'overrideUntil', {
    configurable: true,
    enumerable: true,
    get() { return 'hostile getter override' },
    set() { setterCalls++ }
  })
  try {
    result = Timeline.buildSnapshot(raw)
  } finally {
    delete Object.prototype.sunset
    delete Object.prototype.sunrise
    delete Object.prototype.nextBoundary
    delete Object.prototype.overrideUntil
  }

  assert.equal(result.ok, true)
  assert.equal(setterCalls, 0)
  assert.equal(Object.getPrototypeOf(result.snapshot.displayTimes), null)
  assert.deepEqual(Object.keys(result.snapshot.displayTimes), Object.keys(rawTimes))
  for (const name of ['sunset', 'sunrise', 'nextBoundary', 'overrideUntil']) {
    assert.deepEqual(result.snapshot.displayTimes[name], rawTimes[name], name)
    assert.equal(Object.hasOwn(result.snapshot.displayTimes, name), true, name)
    const descriptor = Object.getOwnPropertyDescriptor(result.snapshot.displayTimes, name)
    assert.equal(Object.hasOwn(descriptor, 'value'), true, name)
    assert.equal(Object.hasOwn(descriptor, 'get'), false, name)
    assert.equal(Object.hasOwn(descriptor, 'set'), false, name)
    assert.equal(descriptor.enumerable, true, name)
    assert.equal(descriptor.writable, false, name)
    assert.equal(descriptor.configurable, false, name)
  }
})

test('partial and empty displayTimes keep omitted allowed names unreachable under prototype getters', () => {
  const names = ['sunset', 'sunrise', 'nextBoundary', 'overrideUntil']
  const partialRaw = input({ displayTimes: { sunset: null } })
  const emptyRaw = input({ displayTimes: {} })
  let getterCalls = 0
  let partial
  let empty
  let partialKeys
  let emptyKeys
  let partialReads
  let emptyReads

  for (const name of names) {
    Object.defineProperty(Object.prototype, name, {
      configurable: true,
      enumerable: true,
      get() { getterCalls++; return { hostile: name } }
    })
  }
  try {
    partial = Timeline.buildSnapshot(partialRaw)
    empty = Timeline.buildSnapshot(emptyRaw)
    partialKeys = Object.keys(partial.snapshot.displayTimes)
    emptyKeys = Object.keys(empty.snapshot.displayTimes)
    partialReads = {
      sunset: partial.snapshot.displayTimes.sunset,
      sunrise: partial.snapshot.displayTimes.sunrise,
      nextBoundary: partial.snapshot.displayTimes.nextBoundary,
      overrideUntil: partial.snapshot.displayTimes.overrideUntil
    }
    emptyReads = {
      sunset: empty.snapshot.displayTimes.sunset,
      sunrise: empty.snapshot.displayTimes.sunrise,
      nextBoundary: empty.snapshot.displayTimes.nextBoundary,
      overrideUntil: empty.snapshot.displayTimes.overrideUntil
    }
  } finally {
    for (const name of names) delete Object.prototype[name]
  }

  assert.equal(partial.ok, true)
  assert.equal(empty.ok, true)
  assert.equal(getterCalls, 0)
  assert.equal(Object.getPrototypeOf(partial.snapshot.displayTimes), null)
  assert.equal(Object.getPrototypeOf(empty.snapshot.displayTimes), null)
  assert.deepEqual(partialKeys, ['sunset'])
  assert.deepEqual(emptyKeys, [])
  assert.deepEqual(partialReads, {
    sunset: null,
    sunrise: undefined,
    nextBoundary: undefined,
    overrideUntil: undefined
  })
  assert.deepEqual(emptyReads, {
    sunset: undefined,
    sunrise: undefined,
    nextBoundary: undefined,
    overrideUntil: undefined
  })
  assert.equal(Object.hasOwn(partial.snapshot.displayTimes, 'sunrise'), false)
  assert.equal(Object.hasOwn(empty.snapshot.displayTimes, 'sunset'), false)
})

test('canonical event and segment arrays define exact own indices through numeric prototype attacks', () => {
  const raw = input({ events: [
    event('sunrise', 1000, wall(20, 0)),
    event('sunset', 2000, wall(4, 0))
  ] })
  const expected = Timeline.buildSnapshot(raw)
  assert.equal(expected.ok, true)

  let getterCalls = 0
  let setterCalls = 0
  let result
  Object.defineProperty(Object.prototype, '0', {
    configurable: true,
    enumerable: true,
    get() { getterCalls++; return { hostile: true } },
    set() { setterCalls++ }
  })
  Object.defineProperty(Object.prototype, '1', {
    configurable: true,
    enumerable: true,
    value: { hostile: 'non-writable' },
    writable: false
  })
  try {
    result = Timeline.buildSnapshot(raw)
  } finally {
    delete Object.prototype['0']
    delete Object.prototype['1']
  }

  assert.equal(result.ok, true)
  assert.equal(getterCalls, 0)
  assert.equal(setterCalls, 0)
  assert.deepEqual(result.snapshot.events, expected.snapshot.events)
  assert.deepEqual(result.snapshot.daylightSegments, expected.snapshot.daylightSegments)
  assert.equal(result.snapshot.events.length, 2)
  assert.equal(result.snapshot.daylightSegments.length, 2)

  for (const [name, array] of [
    ['events', result.snapshot.events],
    ['daylightSegments', result.snapshot.daylightSegments]
  ]) {
    for (let index = 0; index < array.length; index++) {
      assert.equal(Object.hasOwn(array, String(index)), true, `${name}[${index}]`)
      const descriptor = Object.getOwnPropertyDescriptor(array, String(index))
      assert.equal(Object.hasOwn(descriptor, 'value'), true, `${name}[${index}]`)
      assert.equal(Object.hasOwn(descriptor, 'get'), false, `${name}[${index}]`)
      assert.equal(Object.hasOwn(descriptor, 'set'), false, `${name}[${index}]`)
      assert.equal(descriptor.enumerable, true, `${name}[${index}]`)
      assert.equal(descriptor.writable, false, `${name}[${index}]`)
      assert.equal(descriptor.configurable, false, `${name}[${index}]`)
    }
  }
})

test('prototype pollution cannot satisfy schemas or alter exact enum decisions', () => {
  const modelPath = JSON.stringify(path.resolve(__dirname, '../TimelineModel.js'))
  const payload = JSON.stringify(input({ events: [] }))
  const script = `const T=require(${modelPath});` +
    `for(const k of ['revision','dateKey','zoneId','zoneSource','nowMs','markerWallMs',` +
    `'markerOffsetMinutes','markerFold','markerAmbiguous','status','stateAtMidnight',` +
    `'events','displayTimes','sunrise','sunset','normal','location'])` +
    `Object.defineProperty(Object.prototype,k,{configurable:true,value:'polluted'});` +
    `const good=T.buildSnapshot(${payload});` +
    `const inherited=T.buildSnapshot(Object.create(${payload}));` +
    `const poisoned=T.buildSnapshot(Object.assign(${payload},{status:'toString'}));` +
    `process.stdout.write(JSON.stringify({good,inherited,poisoned}));`
  const child = spawnSync(process.execPath, ['-e', script], {
    encoding: 'utf8', timeout: 2000
  })
  assert.equal(child.error, undefined, child.error && child.error.message)
  assert.equal(child.status, 0, child.stderr)
  const result = JSON.parse(child.stdout)
  assert.equal(result.good.ok, true)
  assert.deepEqual(result.inherited, { ok: false, error: 'invalid-timeline' })
  assert.deepEqual(result.poisoned, { ok: false, error: 'invalid-timeline' })
})

test('shouldAnimateMarker permits only nearby monotone updates in one civil context', () => {
  const previous = snapshot({ nowMs: 1000000, markerWallMs: wall(12, 0) })
  const normalMinute = snapshot({ nowMs: 1060000, markerWallMs: wall(12, 1) })
  const exactLimit = snapshot({ nowMs: 1120000, markerWallMs: wall(12, 2) })
  assert.equal(Timeline.shouldAnimateMarker(null, normalMinute), false)
  assert.equal(Timeline.shouldAnimateMarker(previous, normalMinute), true)
  assert.equal(Timeline.shouldAnimateMarker(previous, exactLimit), true)
  assert.equal(Timeline.shouldAnimateMarker(previous, previous), true)

  const replacements = [
    snapshot({ revision: 8, nowMs: 1060000, markerWallMs: wall(12, 1) }),
    snapshot({ dateKey: '2026-09-02', events: [], nowMs: 1060000, markerWallMs: wall(0, 1) }),
    snapshot({ zoneId: 'UTC', nowMs: 1060000, markerWallMs: wall(12, 1) }),
    snapshot({ markerOffsetMinutes: 60, nowMs: 1060000, markerWallMs: wall(12, 1) }),
    snapshot({ nowMs: 999999, markerWallMs: wall(12, 1) }),
    snapshot({ nowMs: 1120001, markerWallMs: wall(12, 2) }),
    snapshot({ nowMs: 1060000, markerWallMs: wall(11, 59) }),
    snapshot({ nowMs: 1060000, markerWallMs: wall(12, 2) + 1 })
  ]
  for (const next of replacements)
    assert.equal(Timeline.shouldAnimateMarker(previous, next), false)

  assert.equal(Timeline.shouldAnimateMarker({}, normalMinute), false)
  assert.equal(Timeline.shouldAnimateMarker(previous, {}), false)
})

test('midnight, spring-forward, fall-back, suspend, and backward-clock jumps snap', () => {
  const beforeMidnight = snapshot({
    nowMs: 1000000,
    markerWallMs: DAY_MS - 1
  })
  const afterMidnight = snapshot({
    revision: 8,
    dateKey: '2026-09-02',
    events: [],
    nowMs: 1000001,
    markerWallMs: 0
  })
  assert.equal(Timeline.shouldAnimateMarker(beforeMidnight, afterMidnight), false)

  const springBefore = snapshot({ nowMs: 2000000, markerWallMs: wall(1, 59) })
  const springAfter = snapshot({
    nowMs: 2060000, markerWallMs: wall(3, 0), markerOffsetMinutes: 120
  })
  assert.equal(Timeline.shouldAnimateMarker(springBefore, springAfter), false)

  const fallBefore = snapshot({
    nowMs: 3000000, markerWallMs: wall(2, 59), markerOffsetMinutes: 120,
    markerFold: 0, markerAmbiguous: true
  })
  const fallAfter = snapshot({
    nowMs: 3060000, markerWallMs: wall(2, 0), markerOffsetMinutes: 60,
    markerFold: 1, markerAmbiguous: true
  })
  assert.equal(Timeline.shouldAnimateMarker(fallBefore, fallAfter), false)

  assert.equal(Timeline.shouldAnimateMarker(snapshot({
    nowMs: 4000000, markerWallMs: wall(10, 0)
  }), snapshot({
    nowMs: 4000000 + 3 * 60 * 60 * 1000, markerWallMs: wall(13, 0)
  })), false)
  assert.equal(Timeline.shouldAnimateMarker(snapshot({
    nowMs: 5000000, markerWallMs: wall(10, 0)
  }), snapshot({
    nowMs: 4999000, markerWallMs: wall(9, 59)
  })), false)
})

test('deterministic hostile random sweep preserves input and finite sorted bounded geometry', () => {
  let seed = 0x5eed1234
  function random() {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0
    return seed / 0x100000000
  }

  for (let i = 0; i < 10000; i++) {
    const midnightDay = random() < 0.5
    const count = Math.floor(random() * 3)
    let state = midnightDay ? 'day' : 'night'
    let epoch = -1000000000 + Math.floor(random() * 1000000)
    const events = []
    for (let j = 0; j < count; j++) {
      epoch += 1 + Math.floor(random() * 100000)
      const kind = state === 'day' ? 'sunset' : 'sunrise'
      const wallMs = Math.floor(random() * DAY_MS)
      events.push(event(kind, epoch, wallMs, {
        offsetMinutes: -1440 + Math.floor(random() * 2881),
        fold: random() < 0.5 ? 0 : 1,
        ambiguous: random() < 0.5
      }))
      state = state === 'day' ? 'night' : 'day'
    }
    const raw = input({
      revision: i,
      nowMs: epoch - Math.floor(random() * 200000),
      markerWallMs: random() * DAY_MS,
      markerOffsetMinutes: -1440 + Math.floor(random() * 2881),
      markerFold: random() < 0.5 ? 0 : 1,
      markerAmbiguous: random() < 0.5,
      stateAtMidnight: midnightDay ? 'day' : 'night',
      events
    })
    const before = JSON.stringify(raw)
    const built = Timeline.buildSnapshot(raw)
    assert.equal(built.ok, true, `sample ${i}`)
    assert.equal(JSON.stringify(raw), before, `mutation ${i}`)
    assert.equal(Number.isFinite(Timeline.positionForWallMs(built.snapshot.markerWallMs)), true)

    let priorEnd = -1
    for (const segment of built.snapshot.daylightSegments) {
      assert.equal(Number.isFinite(segment.startWallMs), true)
      assert.equal(Number.isFinite(segment.endWallMs), true)
      assert.ok(segment.startWallMs >= 0)
      assert.ok(segment.startWallMs < segment.endWallMs)
      assert.ok(segment.endWallMs <= DAY_MS)
      assert.ok(segment.startWallMs >= priorEnd)
      priorEnd = segment.endWallMs
    }
  }
})
