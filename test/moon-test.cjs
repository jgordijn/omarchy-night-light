'use strict'

var fs = require('node:fs')
var path = require('node:path')
var vm = require('node:vm')
var childProcess = require('node:child_process')
var Moon = require('../MoonModel.js')

var MODEL_PATH = path.resolve(__dirname, '../MoonModel.js')
var SYNODIC_MONTH_DAYS = 29.530588853
var MAX_EPOCH_MS = 8640000000000000
var VALID_IDENTITIES = {
  'new-moon': 'New Moon',
  'waxing-crescent': 'Waxing Crescent',
  'first-quarter': 'First Quarter',
  'waxing-gibbous': 'Waxing Gibbous',
  'full-moon': 'Full Moon',
  'waning-gibbous': 'Waning Gibbous',
  'last-quarter': 'Last Quarter',
  'waning-crescent': 'Waning Crescent'
}

var referenceFixtures = [
  {
    name: 'J2000 new moon',
    provenance: 'USNO Astronomical Applications phase tables, 2000 new moon',
    utc: '2000-01-06T18:14:00Z',
    phase: 0.998198,
    illumination: 0.000207,
    cardinal: 'new'
  },
  {
    name: '2024 total-eclipse new moon',
    provenance: 'USNO phase tables; NASA/GSFC 2024-04-08 eclipse cross-check',
    utc: '2024-04-08T18:21:00Z',
    phase: 0.003305,
    illumination: 0.000110,
    cardinal: 'new'
  },
  {
    name: '2024 April first quarter',
    provenance: 'USNO Astronomical Applications phase tables',
    utc: '2024-04-15T19:13:00Z',
    phase: 0.249230,
    illumination: 0.498910,
    cardinal: 'quarter'
  },
  {
    name: '2024 April full moon',
    provenance: 'USNO Astronomical Applications phase tables',
    utc: '2024-04-23T23:49:00Z',
    phase: 0.499022,
    illumination: 0.999682,
    cardinal: 'full'
  },
  {
    name: '2024 May last quarter',
    provenance: 'USNO Astronomical Applications phase tables',
    utc: '2024-05-01T11:27:00Z',
    phase: 0.754757,
    illumination: 0.486330,
    cardinal: 'quarter'
  }
]

function timezoneSnapshot() {
  var epochs = referenceFixtures.map(function(fixture) { return Date.parse(fixture.utc) })
  epochs.push(Date.parse('2026-09-01T13:49:00Z'))
  epochs.push(Date.parse('2024-03-10T07:30:00Z'))
  epochs.push(Date.parse('2024-11-03T06:30:00Z'))
  return epochs.map(Moon.phaseAt)
}

if (process.env.MOON_TZ_SNAPSHOT === '1') {
  process.stdout.write(JSON.stringify(timezoneSnapshot()))
} else {
  var test = require('node:test')
  var assert = require('node:assert/strict')

  function circularDistance(left, right) {
    var distance = Math.abs(left - right)
    return Math.min(distance, 1 - distance)
  }

  function assertSuccess(result, message) {
    assert.deepEqual(Object.keys(result), [
      'ok', 'phase', 'ageDays', 'illumination', 'trend', 'phaseId', 'phaseName'
    ], message)
    assert.equal(result.ok, true, message)
    assert.equal(Number.isFinite(result.phase), true, message)
    assert.equal(Number.isFinite(result.ageDays), true, message)
    assert.equal(Number.isFinite(result.illumination), true, message)
    assert.ok(result.phase >= 0 && result.phase < 1, message)
    assert.equal(result.ageDays, result.phase * SYNODIC_MONTH_DAYS, message)
    assert.ok(result.ageDays >= 0 && result.ageDays < SYNODIC_MONTH_DAYS, message)
    assert.ok(result.illumination >= 0 && result.illumination <= 1, message)
    assert.equal(result.trend, result.phase < 0.5 ? 'waxing' : 'waning', message)
    assert.equal(VALID_IDENTITIES[result.phaseId], result.phaseName, message)
  }

  test('exports only the frozen public API and loads unchanged without CommonJS', function() {
    assert.deepEqual(Object.keys(Moon).sort(), [
      'orientationForLatitude',
      'phaseAt'
    ])

    var source = fs.readFileSync(MODEL_PATH, 'utf8')
    var context = vm.createContext({ Math: Math, isFinite: isFinite })
    vm.runInContext(source, context, { filename: MODEL_PATH })
    assert.equal(typeof context.phaseAt, 'function')
    assert.equal(typeof context.orientationForLatitude, 'function')
    assert.equal(JSON.stringify(context.phaseAt(0)), JSON.stringify(Moon.phaseAt(0)))
    assert.equal(JSON.stringify(context.orientationForLatitude(null)),
      JSON.stringify(Moon.orientationForLatitude(null)))

    assert.doesNotMatch(source, /\bnew\s+Date\b|Date\s*\.|toLocale|Intl\s*\.|Qt\s*\.|\.toFixed\s*\(|Math\.round\s*\(/)
    assert.doesNotMatch(source, /\brequire\s*\(/)
  })

  test('phaseAt rejects hostile and out-of-range epochs with the exact failure', function() {
    var revoked = Proxy.revocable({}, {})
    revoked.revoke()
    var throwing = Object.create(null)
    Object.defineProperty(throwing, 'valueOf', {
      get: function() { throw new Error('must not inspect hostile objects') }
    })
    var invalid = [
      undefined, null, '', '0', true, false, NaN, Infinity, -Infinity,
      MAX_EPOCH_MS + 1, -MAX_EPOCH_MS - 1, [], {}, function() {},
      Symbol('epoch'), 0n, new Number(0), throwing, revoked.proxy
    ]
    for (var i = 0; i < invalid.length; i++) {
      assert.doesNotThrow(function() { Moon.phaseAt(invalid[i]) })
      assert.deepEqual(Moon.phaseAt(invalid[i]), { ok: false, error: 'invalid-epoch' })
    }
  })

  test('the full closed ECMAScript Date range and fractional milliseconds stay finite', function() {
    var valid = [-MAX_EPOCH_MS, -1.25, -0, 0, 0.25, MAX_EPOCH_MS]
    for (var i = 0; i < valid.length; i++) {
      var first = Moon.phaseAt(valid[i])
      var second = Moon.phaseAt(valid[i])
      assertSuccess(first, String(valid[i]))
      assert.deepEqual(first, second)
    }
  })

  test('provenance-labeled UTC cardinal fixtures meet the frozen phase and illumination gates', function() {
    for (var i = 0; i < referenceFixtures.length; i++) {
      var fixture = referenceFixtures[i]
      assert.ok(fixture.provenance.length > 0)
      var result = Moon.phaseAt(Date.parse(fixture.utc))
      assertSuccess(result, fixture.name)
      var phaseError = circularDistance(result.phase, fixture.phase)
      assert.ok(phaseError <= 0.01, fixture.name + ' phase error ' + phaseError)
      assert.ok(phaseError * SYNODIC_MONTH_DAYS <= 0.20,
        fixture.name + ' age error')
      if (fixture.cardinal === 'new')
        assert.ok(result.illumination <= 0.01, fixture.name)
      else if (fixture.cardinal === 'quarter')
        assert.ok(Math.abs(result.illumination - 0.5) <= 0.03, fixture.name)
      else
        assert.ok(result.illumination >= 0.99, fixture.name)
      assert.ok(Math.abs(result.illumination - fixture.illumination) <= 0.000001,
        fixture.name + ' frozen illumination')
    }
  })

  test('captured Hilversum product fixture is northern, waning-gibbous, and about 79.49 percent lit', function() {
    var result = Moon.phaseAt(Date.parse('2026-09-01T13:49:00Z'))
    assertSuccess(result, 'Hilversum capture')
    assert.ok(Math.abs(result.phase - 0.6495230623756667) < 1e-12)
    assert.ok(Math.abs(result.ageDays - 19.180798505557288) < 1e-10)
    assert.ok(Math.abs(result.illumination - 0.7948970595391965) < 1e-12)
    assert.equal(result.trend, 'waning')
    assert.equal(result.phaseId, 'waning-gibbous')
    assert.equal(result.phaseName, 'Waning Gibbous')
    assert.deepEqual(Moon.orientationForLatitude(52.2292), {
      ok: true, orientation: 'northern', source: 'location'
    })
  })

  test('all octant boundaries are exact, half-open, and independent of rounded illumination', function() {
    var source = fs.readFileSync(MODEL_PATH, 'utf8')
    var context = vm.createContext({ Math: Math, isFinite: isFinite })
    vm.runInContext(source, context, { filename: MODEL_PATH })

    var boundaries = [
      [0, 'new-moon', 'New Moon'],
      [1 / 16, 'waxing-crescent', 'Waxing Crescent'],
      [3 / 16, 'first-quarter', 'First Quarter'],
      [5 / 16, 'waxing-gibbous', 'Waxing Gibbous'],
      [7 / 16, 'full-moon', 'Full Moon'],
      [9 / 16, 'waning-gibbous', 'Waning Gibbous'],
      [11 / 16, 'last-quarter', 'Last Quarter'],
      [13 / 16, 'waning-crescent', 'Waning Crescent'],
      [15 / 16, 'new-moon', 'New Moon']
    ]
    for (var i = 0; i < boundaries.length; i++) {
      var at = context.phaseIdentity(boundaries[i][0])
      assert.equal(at.phaseId, boundaries[i][1])
      assert.equal(at.phaseName, boundaries[i][2])
      if (i > 0) {
        var below = context.phaseIdentity(boundaries[i][0] - Number.EPSILON)
        assert.equal(below.phaseId, boundaries[i - 1][1])
      }
    }

    assert.equal(context.phaseDetails(0.5 - Number.EPSILON, 0.5).trend, 'waxing')
    assert.equal(context.phaseDetails(0.5, 0.5).trend, 'waning')
    assert.equal(context.phaseDetails(0.5, 0.49999999999999994).phaseId, 'full-moon')
    assert.equal(context.phaseDetails(0.5, 1).phaseId, 'full-moon')
  })

  test('illumination and waxing/waning derive from astronomy rather than phase names', function() {
    var newBeforeWrap = Moon.phaseAt(Date.parse('2000-01-06T18:14:00Z'))
    var newAfterWrap = Moon.phaseAt(Date.parse('2024-04-08T18:21:00Z'))
    var firstQuarter = Moon.phaseAt(Date.parse('2024-04-15T19:13:00Z'))
    var full = Moon.phaseAt(Date.parse('2024-04-23T23:49:00Z'))
    var lastQuarter = Moon.phaseAt(Date.parse('2024-05-01T11:27:00Z'))

    assert.equal(newBeforeWrap.trend, 'waning')
    assert.equal(newAfterWrap.trend, 'waxing')
    assert.equal(firstQuarter.trend, 'waxing')
    assert.equal(full.trend, 'waxing')
    assert.equal(lastQuarter.trend, 'waning')
    assert.ok(newBeforeWrap.illumination < 0.001)
    assert.ok(newAfterWrap.illumination < 0.001)
    assert.ok(Math.abs(firstQuarter.illumination - 0.5) < 0.01)
    assert.ok(full.illumination > 0.999)
    assert.ok(Math.abs(lastQuarter.illumination - 0.5) < 0.02)
  })

  test('orientation policy handles no location, equator, poles, and hostile scalars exactly', function() {
    assert.deepEqual(Moon.orientationForLatitude(), {
      ok: true, orientation: 'northern', source: 'default'
    })
    assert.deepEqual(Moon.orientationForLatitude(null), {
      ok: true, orientation: 'northern', source: 'default'
    })
    for (var i = 0; i < [0, -0, 90, 0.000001].length; i++) {
      assert.deepEqual(Moon.orientationForLatitude([0, -0, 90, 0.000001][i]), {
        ok: true, orientation: 'northern', source: 'location'
      })
    }
    for (var j = 0; j < [-90, -0.000001, -45].length; j++) {
      assert.deepEqual(Moon.orientationForLatitude([-90, -0.000001, -45][j]), {
        ok: true, orientation: 'southern', source: 'location'
      })
    }

    var hostile = Object.create(null)
    Object.defineProperty(hostile, 'valueOf', {
      get: function() { throw new Error('must not coerce latitude') }
    })
    var invalid = [91, -91, NaN, Infinity, -Infinity, '', '0', true, false,
      [], {}, Symbol('latitude'), 0n, new Number(0), hostile]
    for (var k = 0; k < invalid.length; k++) {
      assert.doesNotThrow(function() { Moon.orientationForLatitude(invalid[k]) })
      assert.deepEqual(Moon.orientationForLatitude(invalid[k]), {
        ok: false, error: 'invalid-latitude'
      })
    }
  })

  test('phase snapshots are byte-identical across host timezones and DST rules', function() {
    var zones = [
      'UTC', 'Europe/Amsterdam', 'America/New_York', 'Asia/Tokyo',
      'Pacific/Auckland', 'Asia/Kathmandu', 'Pacific/Kiritimati', 'Pacific/Honolulu'
    ]
    var reference = null
    for (var i = 0; i < zones.length; i++) {
      var child = childProcess.spawnSync(process.execPath, [__filename], {
        env: Object.assign({}, process.env, {
          TZ: zones[i],
          MOON_TZ_SNAPSHOT: '1'
        }),
        encoding: 'utf8',
        timeout: 10000
      })
      assert.equal(child.error, undefined, zones[i])
      assert.equal(child.status, 0, zones[i] + ': ' + child.stderr)
      assert.equal(child.stderr, '', zones[i] + ' stderr')
      if (reference === null) reference = child.stdout
      else assert.equal(child.stdout, reference, zones[i])
    }
  })

  test('six-hour sweep from 1900 through 2100 is finite, deterministic, and forward except legal wraps',
    { timeout: 30000 }, function() {
      var start = Date.parse('1900-01-01T00:00:00Z')
      var end = Date.parse('2101-01-01T00:00:00Z')
      var step = 6 * 60 * 60 * 1000
      var previous = null
      var count = 0
      var wraps = 0

      for (var epoch = start; epoch < end; epoch += step) {
        var result = Moon.phaseAt(epoch)
        assertSuccess(result, String(epoch))
        assert.deepEqual(result, Moon.phaseAt(epoch))
        if (previous !== null && result.phase < previous) {
          assert.ok(previous > 0.95 && result.phase < 0.05,
            'only a new-moon wrap may move backward at ' + epoch)
          wraps++
        }
        previous = result.phase
        count++
      }

      assert.equal(count, (end - start) / step)
      assert.ok(wraps > 2400 && wraps < 2600)
    })
}
