'use strict'

var Solar = require('../SolarModel.js')

// A subprocess enters this branch before loading node:test.  The resulting
// JSON is deliberately made only from epoch inputs and pure model outputs.
function timezoneSnapshot() {
  var cases = [
    [Date.parse('2024-03-10T06:30:00Z'), 40.7128, -74.0060],
    [Date.parse('2024-03-10T07:30:00Z'), 40.7128, -74.0060],
    [Date.parse('2024-11-03T05:30:00Z'), 40.7128, -74.0060],
    [Date.parse('2024-11-03T06:30:00Z'), 40.7128, -74.0060],
    [Date.parse('2024-03-31T00:30:00Z'), 52.3676, 4.9041],
    [Date.parse('2024-03-31T01:30:00Z'), 52.3676, 4.9041],
    [Date.parse('2024-10-27T00:30:00Z'), 52.3676, 4.9041],
    [Date.parse('2024-10-27T01:30:00Z'), 52.3676, 4.9041],
    [Date.parse('2024-06-21T12:00:00Z'), 69.6492, 18.9553],
    [Date.parse('2024-12-21T12:00:00Z'), 69.6492, 18.9553],
    [Date.parse('2024-12-31T23:59:59Z'), -33.8688, 151.2093]
  ]
  return cases.map(function(item) {
    return {
      cycle: Solar.cycleAt(item[0], item[1], item[2]),
      surrounding: Solar.surroundingEvents(item[0], item[1], item[2])
    }
  })
}

if (process.env.SOLAR_TZ_SNAPSHOT === '1') {
  process.stdout.write(JSON.stringify(timezoneSnapshot()))
} else {
  var test = require('node:test')
  var assert = require('node:assert/strict')
  var childProcess = require('node:child_process')

  var FIVE_MINUTES = 5 * 60 * 1000
  var DAY_MS = 86400000
  var MAX_INPUT_EPOCH_MS = 8640000000000000 - (370 + 2) * DAY_MS

  function assertNear(actual, expectedIso, tolerance, message) {
    var expected = Date.parse(expectedIso)
    assert.equal(typeof actual, 'number', message + ' is numeric')
    assert.ok(Math.abs(actual - expected) <= tolerance,
      message + ': expected ' + expectedIso + ', got ' + new Date(actual).toISOString())
  }

  function assertCycleInvariant(result) {
    assert.equal(result.ok, true)
    assert.ok(result.status === 'normal' || result.status === 'polar-day' || result.status === 'polar-night')
    assert.equal(Number.isFinite(result.transitMs), true)
    if (result.status === 'normal') {
      assert.equal(Number.isFinite(result.sunriseMs), true)
      assert.equal(Number.isFinite(result.sunsetMs), true)
      assert.ok(result.sunriseMs < result.transitMs)
      assert.ok(result.transitMs < result.sunsetMs)
      assert.ok(result.sunsetMs - result.sunriseMs > 0)
      assert.ok(result.sunsetMs - result.sunriseMs < DAY_MS)
    } else {
      assert.equal(result.sunriseMs, null)
      assert.equal(result.sunsetMs, null)
    }
  }

  function assertSurroundingInvariant(result, epochMs, message) {
    assert.equal(result.ok, true, message)
    var previous = result.previousEvent
    var next = result.nextEvent
    if (previous) {
      assert.ok(previous.kind === 'sunrise' || previous.kind === 'sunset', message)
      assert.ok(previous.epochMs <= epochMs, message)
    }
    if (next) {
      assert.ok(next.kind === 'sunrise' || next.kind === 'sunset', message)
      assert.ok(next.epochMs > epochMs, message)
    }
    if (previous && next) {
      var adjacentDay = previous.kind === 'sunrise' && next.kind === 'sunset'
      var adjacentNight = previous.kind === 'sunset' && next.kind === 'sunrise'
      assert.ok(adjacentDay || adjacentNight, message + ' adjacent events alternate')
      assert.equal(result.isDay, adjacentDay, message + ' state follows adjacent events')
    }

    if (result.status === 'normal') {
      assert.equal(Number.isFinite(result.sunsetMs), true, message)
      assert.equal(Number.isFinite(result.sunriseMs), true, message)
      assert.ok(result.sunsetMs < result.sunriseMs, message)
      if (result.isDay) {
        assert.equal(next.kind, 'sunset', message)
        assert.equal(result.sunsetMs, next.epochMs, message)
        assert.ok(epochMs < result.sunsetMs, message)
      } else {
        assert.equal(previous.kind, 'sunset', message)
        assert.equal(next.kind, 'sunrise', message)
        assert.equal(result.sunsetMs, previous.epochMs, message)
        assert.equal(result.sunriseMs, next.epochMs, message)
        assert.ok(result.sunsetMs <= epochMs && epochMs < result.sunriseMs, message)
      }
    } else {
      assert.ok(result.status === 'polar-day' || result.status === 'polar-night', message)
      assert.equal(result.isDay, result.status === 'polar-day', message)
      assert.equal(result.sunsetMs, null, message)
      assert.equal(result.sunriseMs, null, message)
    }
  }

  test('exports only the frozen public API', function() {
    assert.deepEqual(Object.keys(Solar).sort(), [
      'cycleAt',
      'surroundingEvents',
      'validateCoordinates'
    ])
  })

  test('coordinate validation is strict, finite, bounded, and atomic', function() {
    var invalidScalars = [
      undefined, null, '', ' ', '\n', true, false, [], {}, NaN,
      Infinity, -Infinity, '1e2', '0x10', '51.5x', '--1', '.', '+'
    ]
    for (var i = 0; i < invalidScalars.length; i++) {
      assert.deepEqual(Solar.validateCoordinates(invalidScalars[i], 0),
        { ok: false, error: 'invalid-coordinates' })
      assert.deepEqual(Solar.validateCoordinates(0, invalidScalars[i]),
        { ok: false, error: 'invalid-coordinates' })
    }
    assert.equal(Solar.validateCoordinates(-90.0000001, 0).ok, false)
    assert.equal(Solar.validateCoordinates(90.0000001, 0).ok, false)

    var valid = [
      ['0', 0], [0, 0], ['-0', -0], ['.5', 0.5], ['-.5', -0.5],
      ['+1.25', 1.25], [' 42.5 ', 42.5], [-90, -90], [90, 90]
    ]
    for (var j = 0; j < valid.length; j++) {
      var checked = Solar.validateCoordinates(valid[j][0], 5)
      assert.equal(checked.ok, true)
      assert.ok(Object.is(checked.latitude, valid[j][1]))
      assert.equal(checked.longitude, 5)
    }

    assert.deepEqual(Solar.validateCoordinates('-90', '-180'),
      { ok: true, latitude: -90, longitude: -180 })
    assert.deepEqual(Solar.validateCoordinates('90', '180'),
      { ok: true, latitude: 90, longitude: 180 })
    assert.equal(Solar.validateCoordinates(0, -180.0000001).ok, false)
    assert.equal(Solar.validateCoordinates(0, 180.0000001).ok, false)
    assert.deepEqual(Solar.validateCoordinates(12, undefined),
      { ok: false, error: 'invalid-coordinates' })
  })

  test('invalid epochs and coordinates fail without non-finite public data', function() {
    var epochs = [undefined, null, '', true, NaN, Infinity, -Infinity,
      8640000000000000, -8640000000000000,
      8639999999999999, -8639999999999999]
    for (var i = 0; i < epochs.length; i++) {
      assert.deepEqual(Solar.cycleAt(epochs[i], 0, 0),
        { ok: false, status: 'error', error: 'invalid-epoch' })
      assert.deepEqual(Solar.surroundingEvents(epochs[i], 0, 0),
        { ok: false, status: 'error', error: 'invalid-epoch' })
    }
    assert.deepEqual(Solar.cycleAt(0, 'north', 0),
      { ok: false, status: 'error', error: 'invalid-coordinates' })
    assert.deepEqual(Solar.surroundingEvents(0, 0, 181),
      { ok: false, status: 'error', error: 'invalid-coordinates' })
  })

  test('accepted epoch interval is closed and stable across a minimum/maximum grid',
    { timeout: 10000 }, function() {
      var endpoints = [-MAX_INPUT_EPOCH_MS, MAX_INPUT_EPOCH_MS]
      var count = 0
      for (var endpointIndex = 0; endpointIndex < endpoints.length; endpointIndex++) {
        var endpoint = endpoints[endpointIndex]
        for (var latitude = -90; latitude <= 90; latitude += 15) {
          for (var longitude = -180; longitude <= 180; longitude += 60) {
            assertCycleInvariant(Solar.cycleAt(endpoint, latitude, longitude))
            assertSurroundingInvariant(
              Solar.surroundingEvents(endpoint, latitude, longitude), endpoint,
              endpoint + ' ' + latitude + ',' + longitude)
            count++
          }
        }
      }
      assert.equal(count, 13 * 7 * 2)

      var outside = [-MAX_INPUT_EPOCH_MS - 1, MAX_INPUT_EPOCH_MS + 1]
      for (var j = 0; j < outside.length; j++) {
        assert.deepEqual(Solar.cycleAt(outside[j], 0, 0),
          { ok: false, status: 'error', error: 'invalid-epoch' })
        assert.deepEqual(Solar.surroundingEvents(outside[j], 0, 0),
          { ok: false, status: 'error', error: 'invalid-epoch' })
      }
    })

  // Provenance: the first three frozen references are the NOAA/SunCalc
  // research snapshots recorded in SPEC.md §12 and .work/reports/solar.md.
  // Quito and London are minute-rounded public civil-almanac cross-checks
  // (timeanddate.com 2024 sunrise/sunset tables).  The model's conventional
  // horizon is expected to agree within five minutes, not to model terrain.
  var referenceFixtures = [
    {
      name: 'Greenwich 2024 March equinox',
      provenance: 'SPEC.md NOAA/SunCalc frozen reference',
      epoch: '2024-03-20T12:00:00Z', latitude: 51.4769, longitude: 0,
      sunrise: '2024-03-20T06:03:00Z', sunset: '2024-03-20T18:14:00Z'
    },
    {
      name: 'New York 2024 northern solstice and UTC-midnight crossing',
      provenance: 'SPEC.md NOAA/SunCalc frozen reference',
      epoch: '2024-06-21T16:00:00Z', latitude: 40.7128, longitude: -74.0060,
      sunrise: '2024-06-21T09:26:00Z', sunset: '2024-06-22T00:32:00Z'
    },
    {
      name: 'Sydney 2024 southern solstice and previous UTC-date sunrise',
      provenance: 'SPEC.md NOAA/SunCalc frozen reference',
      epoch: '2024-12-21T00:00:00Z', latitude: -33.8688, longitude: 151.2093,
      sunrise: '2024-12-20T18:42:00Z', sunset: '2024-12-21T09:07:00Z'
    },
    {
      name: 'Quito 2024 March equinox',
      provenance: 'timeanddate.com Quito March 2024 civil almanac',
      epoch: '2024-03-20T17:00:00Z', latitude: -0.1807, longitude: -78.4678,
      sunrise: '2024-03-20T11:20:00Z', sunset: '2024-03-20T23:26:00Z'
    },
    {
      name: 'London leap day 2024',
      provenance: 'timeanddate.com London February 2024 civil almanac',
      epoch: '2024-02-29T12:00:00Z', latitude: 51.5074, longitude: -0.1278,
      sunrise: '2024-02-29T06:49:00Z', sunset: '2024-02-29T17:40:00Z'
    }
  ]

  test('provenance-labeled reference fixtures are within five minutes', function(t) {
    for (var i = 0; i < referenceFixtures.length; i++) {
      var fixture = referenceFixtures[i]
      assert.ok(fixture.provenance.length > 0)
      var result = Solar.cycleAt(Date.parse(fixture.epoch), fixture.latitude, fixture.longitude)
      assertCycleInvariant(result)
      assert.equal(result.status, 'normal', fixture.name)
      assertNear(result.sunriseMs, fixture.sunrise, FIVE_MINUTES, fixture.name + ' sunrise')
      assertNear(result.sunsetMs, fixture.sunset, FIVE_MINUTES, fixture.name + ' sunset')
    }
  })

  test('equinox symmetry and opposite-hemisphere seasons are explicit', function() {
    var equator = Solar.cycleAt(Date.parse('2024-03-20T12:00:00Z'), 0, 0)
    assertCycleInvariant(equator)
    var riseToTransit = equator.transitMs - equator.sunriseMs
    var transitToSet = equator.sunsetMs - equator.transitMs
    assert.ok(Math.abs(riseToTransit - transitToSet) < 1)
    assert.ok(Math.abs((equator.sunsetMs - equator.sunriseMs) - 12 * 60 * 60 * 1000) < 15 * 60 * 1000)

    var dates = ['2024-03-20T12:00:00Z', '2024-06-21T12:00:00Z',
      '2024-09-22T12:00:00Z', '2024-12-21T12:00:00Z']
    for (var i = 0; i < dates.length; i++) {
      assertCycleInvariant(Solar.cycleAt(Date.parse(dates[i]), 35, 20))
      assertCycleInvariant(Solar.cycleAt(Date.parse(dates[i]), -35, 20))
    }

    var northJune = Solar.cycleAt(Date.parse(dates[1]), 35, 20)
    var southJune = Solar.cycleAt(Date.parse(dates[1]), -35, 20)
    var northDecember = Solar.cycleAt(Date.parse(dates[3]), 35, 20)
    var southDecember = Solar.cycleAt(Date.parse(dates[3]), -35, 20)
    assert.ok(northJune.sunsetMs - northJune.sunriseMs > southJune.sunsetMs - southJune.sunriseMs)
    assert.ok(southDecember.sunsetMs - southDecember.sunriseMs > northDecember.sunsetMs - northDecember.sunriseMs)
  })

  test('polar solstices are explicit and contain no fabricated rise/set', function() {
    var places = [
      ['Tromso', 69.6492, 18.9553],
      ['Longyearbyen', 78.2232, 15.6469],
      ['Utqiagvik', 71.2906, -156.7886]
    ]
    for (var i = 0; i < places.length; i++) {
      var summer = Solar.cycleAt(Date.parse('2024-06-21T12:00:00Z'), places[i][1], places[i][2])
      var winter = Solar.cycleAt(Date.parse('2024-12-21T12:00:00Z'), places[i][1], places[i][2])
      assertCycleInvariant(summer)
      assertCycleInvariant(winter)
      assert.equal(summer.status, 'polar-day', places[i][0] + ' summer')
      assert.equal(winter.status, 'polar-night', places[i][0] + ' winter')
    }

    var antarcticSummer = Solar.cycleAt(Date.parse('2024-12-21T12:00:00Z'), -69, 0)
    var antarcticWinter = Solar.cycleAt(Date.parse('2024-06-21T12:00:00Z'), -69, 0)
    assert.equal(antarcticSummer.status, 'polar-day')
    assert.equal(antarcticWinter.status, 'polar-night')
  })

  test('surrounding events order real nights across midnight and polar seasons', function() {
    var newYorkNight = Solar.surroundingEvents(
      Date.parse('2024-06-22T02:00:00Z'), 40.7128, -74.0060)
    assert.equal(newYorkNight.ok, true)
    assert.equal(newYorkNight.status, 'normal')
    assert.equal(newYorkNight.isDay, false)
    assert.ok(newYorkNight.sunsetMs <= Date.parse('2024-06-22T02:00:00Z'))
    assert.ok(newYorkNight.sunriseMs > Date.parse('2024-06-22T02:00:00Z'))
    assert.ok(newYorkNight.sunsetMs < newYorkNight.sunriseMs)

    var sydneyDay = Solar.surroundingEvents(
      Date.parse('2024-12-21T03:00:00Z'), -33.8688, 151.2093)
    assert.equal(sydneyDay.isDay, true)
    assert.ok(sydneyDay.sunsetMs < sydneyDay.sunriseMs)
    assert.ok(sydneyDay.sunsetMs > Date.parse('2024-12-21T03:00:00Z'))

    var polarDay = Solar.surroundingEvents(
      Date.parse('2024-06-21T12:00:00Z'), 69.6492, 18.9553)
    assert.equal(polarDay.status, 'polar-day')
    assert.equal(polarDay.sunsetMs, null)
    assert.equal(polarDay.sunriseMs, null)
    assert.deepEqual(polarDay.previousEvent.kind, 'sunrise')
    assert.deepEqual(polarDay.nextEvent.kind, 'sunset')
    assert.ok(polarDay.previousEvent.epochMs < Date.parse('2024-06-21T12:00:00Z'))
    assert.ok(polarDay.nextEvent.epochMs > Date.parse('2024-06-21T12:00:00Z'))

    var polarNight = Solar.surroundingEvents(
      Date.parse('2024-12-21T12:00:00Z'), 69.6492, 18.9553)
    assert.equal(polarNight.status, 'polar-night')
    assert.equal(polarNight.previousEvent.kind, 'sunset')
    assert.equal(polarNight.nextEvent.kind, 'sunrise')
  })

  test('polar-day seam events have exact half-open state semantics at plus/minus one millisecond', function() {
    var fixtures = [
      {
        name: 'Tromso', latitude: 69.6492, longitude: 18.9553,
        enteringEpoch: '2024-05-17T12:00:00Z',
        returningEpoch: '2024-07-26T12:00:00Z'
      },
      {
        name: 'Antarctic 67.75 south', latitude: -67.75, longitude: 0,
        enteringEpoch: '2023-11-29T12:00:00Z',
        returningEpoch: '2024-01-14T12:00:00Z'
      }
    ]

    for (var i = 0; i < fixtures.length; i++) {
      var fixture = fixtures[i]
      var entering = Solar.cycleAt(
        Date.parse(fixture.enteringEpoch), fixture.latitude, fixture.longitude)
      var returning = Solar.cycleAt(
        Date.parse(fixture.returningEpoch), fixture.latitude, fixture.longitude)
      assert.equal(entering.status, 'normal', fixture.name)
      assert.equal(returning.status, 'normal', fixture.name)

      var beforeEntry = Solar.surroundingEvents(
        entering.sunriseMs - 1, fixture.latitude, fixture.longitude)
      assertSurroundingInvariant(beforeEntry, entering.sunriseMs - 1, fixture.name + ' before entry')
      assert.equal(beforeEntry.status, 'normal', fixture.name)
      assert.equal(beforeEntry.isDay, false, fixture.name)

      var atEntry = Solar.surroundingEvents(
        entering.sunriseMs, fixture.latitude, fixture.longitude)
      var afterEntry = Solar.surroundingEvents(
        entering.sunriseMs + 1, fixture.latitude, fixture.longitude)
      assertSurroundingInvariant(atEntry, entering.sunriseMs, fixture.name + ' at entry')
      assertSurroundingInvariant(afterEntry, entering.sunriseMs + 1, fixture.name + ' after entry')
      assert.equal(atEntry.status, 'polar-day', fixture.name)
      assert.equal(afterEntry.status, 'polar-day', fixture.name)

      var seamEvents = [entering.sunsetMs, returning.sunriseMs]
      for (var eventIndex = 0; eventIndex < seamEvents.length; eventIndex++) {
        for (var offset = -1; offset <= 1; offset++) {
          var at = seamEvents[eventIndex] + offset
          var heldDay = Solar.surroundingEvents(at, fixture.latitude, fixture.longitude)
          assertSurroundingInvariant(heldDay, at, fixture.name + ' held polar day')
          assert.equal(heldDay.status, 'polar-day', fixture.name)
          assert.equal(heldDay.previousEvent.kind, 'sunrise', fixture.name)
          assert.equal(heldDay.nextEvent.kind, 'sunset', fixture.name)
        }
      }

      var beforeReturnSet = Solar.surroundingEvents(
        returning.sunsetMs - 1, fixture.latitude, fixture.longitude)
      var atReturnSet = Solar.surroundingEvents(
        returning.sunsetMs, fixture.latitude, fixture.longitude)
      var afterReturnSet = Solar.surroundingEvents(
        returning.sunsetMs + 1, fixture.latitude, fixture.longitude)
      assertSurroundingInvariant(beforeReturnSet, returning.sunsetMs - 1,
        fixture.name + ' before returning sunset')
      assertSurroundingInvariant(atReturnSet, returning.sunsetMs,
        fixture.name + ' at returning sunset')
      assertSurroundingInvariant(afterReturnSet, returning.sunsetMs + 1,
        fixture.name + ' after returning sunset')
      assert.equal(beforeReturnSet.status, 'polar-day', fixture.name)
      assert.equal(atReturnSet.status, 'normal', fixture.name)
      assert.equal(atReturnSet.isDay, false, fixture.name)
      assert.equal(afterReturnSet.status, 'normal', fixture.name)
      assert.equal(afterReturnSet.sunsetMs, returning.sunsetMs, fixture.name)
      assert.ok(afterReturnSet.sunriseMs - afterReturnSet.sunsetMs < DAY_MS, fixture.name)
    }
  })

  test('polar-night starts at sunset and ends at sunrise at plus/minus one millisecond', function() {
    var latitude = 69.6492
    var longitude = 18.9553
    var entering = Solar.cycleAt(Date.parse('2024-11-27T12:00:00Z'), latitude, longitude)
    var returning = Solar.cycleAt(Date.parse('2025-01-15T12:00:00Z'), latitude, longitude)
    var samples = [
      [entering.sunsetMs - 1, 'normal', true],
      [entering.sunsetMs, 'polar-night', false],
      [entering.sunsetMs + 1, 'polar-night', false],
      [returning.sunriseMs - 1, 'polar-night', false],
      [returning.sunriseMs, 'normal', true],
      [returning.sunriseMs + 1, 'normal', true]
    ]
    for (var i = 0; i < samples.length; i++) {
      var result = Solar.surroundingEvents(samples[i][0], latitude, longitude)
      assertSurroundingInvariant(result, samples[i][0], 'Tromso polar-night seam')
      assert.equal(result.status, samples[i][1])
      assert.equal(result.isDay, samples[i][2])
    }
  })

  test('dense Tromso and Antarctic walks preserve adjacent-event state across every season',
    { timeout: 30000 }, function() {
      var places = [
        ['Tromso', 69.6492, 18.9553],
        ['Antarctic 67.75 south', -67.75, 0]
      ]
      var start = Date.parse('2024-01-01T00:00:00Z')
      var end = Date.parse('2025-01-01T00:00:00Z')
      var step = 15 * 60 * 1000
      var count = 0
      var statuses = { normal: 0, 'polar-day': 0, 'polar-night': 0 }
      for (var placeIndex = 0; placeIndex < places.length; placeIndex++) {
        var place = places[placeIndex]
        for (var epoch = start; epoch < end; epoch += step) {
          var result = Solar.surroundingEvents(epoch, place[1], place[2])
          assertSurroundingInvariant(result, epoch,
            place[0] + ' ' + new Date(epoch).toISOString())
          statuses[result.status]++
          count++
        }
      }
      assert.equal(count, 70272)
      assert.ok(statuses.normal > 20000)
      assert.ok(statuses['polar-day'] > 5000)
      assert.ok(statuses['polar-night'] > 3000)
    })

  test('normal-to-polar edges retain the last and first displayable events', function() {
    var latitude = 69.6492
    var longitude = 18.9553
    var sawNormalBeforeSummer = false
    var sawNormalAfterSummer = false
    var enteredPolarDay = false
    for (var day = -80; day <= 100; day++) {
      var epoch = Date.parse('2024-06-21T12:00:00Z') + day * DAY_MS
      var result = Solar.cycleAt(epoch, latitude, longitude)
      assertCycleInvariant(result)
      if (!enteredPolarDay && result.status === 'normal') sawNormalBeforeSummer = true
      if (result.status === 'polar-day') enteredPolarDay = true
      if (enteredPolarDay && result.status === 'normal') sawNormalAfterSummer = true
    }
    assert.equal(sawNormalBeforeSummer, true)
    assert.equal(enteredPolarDay, true)
    assert.equal(sawNormalAfterSummer, true)

    var boundaryLatitudes = [66, 66.56, 69, 80, 89.999999, 90,
      -66, -66.56, -69, -80, -89.999999, -90]
    for (var i = 0; i < boundaryLatitudes.length; i++) {
      for (var month = 0; month < 12; month++) {
        var cycle = Solar.cycleAt(Date.UTC(2024, month, 15, 12), boundaryLatitudes[i], 0)
        assertCycleInvariant(cycle)
      }
    }
  })

  test('exact poles are stable binary classifications', function() {
    var epochs = [
      Date.parse('2024-03-20T12:00:00Z'),
      Date.parse('2024-06-21T12:00:00Z'),
      Date.parse('2024-09-22T12:00:00Z'),
      Date.parse('2024-12-21T12:00:00Z')
    ]
    for (var latitude = -90; latitude <= 90; latitude += 180) {
      for (var i = 0; i < epochs.length; i++) {
        var first = Solar.cycleAt(epochs[i], latitude, 123)
        var second = Solar.cycleAt(epochs[i], latitude, 123)
        assertCycleInvariant(first)
        assert.notEqual(first.status, 'normal')
        assert.deepEqual(first, second)
      }
    }
  })

  test('dateline representations and signed zero are equivalent', function() {
    var epochs = [
      Date.parse('1900-01-15T12:00:00Z'), Date.parse('1970-01-01T00:00:00Z'),
      Date.parse('1999-12-31T23:59:59Z'), Date.parse('2000-02-29T12:00:00Z'),
      Date.parse('2038-01-19T03:14:07Z'), Date.parse('2099-06-21T12:00:00Z'),
      Date.parse('2100-03-01T00:00:00Z')
    ]
    for (var i = 0; i < epochs.length; i++) {
      assert.deepEqual(Solar.cycleAt(epochs[i], 0, -180), Solar.cycleAt(epochs[i], 0, 180))
      assert.deepEqual(Solar.cycleAt(epochs[i], -0, 0), Solar.cycleAt(epochs[i], 0, -0))
    }
  })

  test('solar outputs are byte-identical across timezone and DST subprocesses', function() {
    var zones = [
      'UTC', 'Europe/Amsterdam', 'America/New_York', 'Asia/Tokyo',
      'Pacific/Auckland', 'Asia/Kathmandu', 'Pacific/Kiritimati', 'Pacific/Honolulu'
    ]
    var reference = null
    for (var i = 0; i < zones.length; i++) {
      var environment = Object.assign({}, process.env, {
        TZ: zones[i],
        SOLAR_TZ_SNAPSHOT: '1'
      })
      var child = childProcess.spawnSync(process.execPath, [__filename], {
        env: environment,
        encoding: 'utf8',
        timeout: 15000
      })
      assert.equal(child.status, 0, zones[i] + ': ' + child.stderr)
      assert.equal(child.stderr, '', zones[i] + ' stderr')
      if (reference === null) reference = child.stdout
      else assert.equal(child.stdout, reference, zones[i])
    }
  })

  test('deterministic 897,900-cycle property sweep has no numerical or chronology failures',
    { timeout: 30000 }, function() {
      var count = 0
      var polarCount = 0
      for (var year = 1900; year <= 2100; year += 5) {
        for (var month = 0; month < 12; month++) {
          var epoch = Date.UTC(year, month, 15, 12)
          for (var latitude = -90; latitude <= 90.000001; latitude += 2.5) {
            for (var longitude = -180; longitude <= 180; longitude += 15) {
              var result = Solar.cycleAt(epoch, latitude, longitude)
              assertCycleInvariant(result)
              if (result.status !== 'normal') polarCount++
              count++
            }
          }
        }
      }
      assert.equal(count, 897900)
      assert.ok(polarCount > 100000)
      assert.ok(polarCount < 250000)

      // Exercise the richer surrounding-events result on a broad subset,
      // including exact poles where conventional rise/set events do not
      // exist. Null is explicit; every event that does exist must be finite.
      for (var sampleYear = 1900; sampleYear <= 2100; sampleYear += 25) {
        for (var sampleMonth = 0; sampleMonth < 12; sampleMonth += 3) {
          var sampleEpoch = Date.UTC(sampleYear, sampleMonth, 15, 12)
          for (var sampleLatitude = -90; sampleLatitude <= 90; sampleLatitude += 10) {
            for (var sampleLongitude = -180; sampleLongitude <= 180; sampleLongitude += 60) {
              var events = Solar.surroundingEvents(sampleEpoch, sampleLatitude, sampleLongitude)
              assert.equal(events.ok, true)
              if (events.status === 'normal') {
                assert.equal(Number.isFinite(events.sunsetMs), true)
                assert.equal(Number.isFinite(events.sunriseMs), true)
                assert.ok(events.sunsetMs < events.sunriseMs)
              } else {
                assert.equal(events.sunsetMs, null)
                assert.equal(events.sunriseMs, null)
              }
              if (events.previousEvent !== null) {
                assert.ok(events.previousEvent.kind === 'sunrise' || events.previousEvent.kind === 'sunset')
                assert.equal(Number.isFinite(events.previousEvent.epochMs), true)
                assert.ok(events.previousEvent.epochMs <= sampleEpoch)
              }
              if (events.nextEvent !== null) {
                assert.ok(events.nextEvent.kind === 'sunrise' || events.nextEvent.kind === 'sunset')
                assert.equal(Number.isFinite(events.nextEvent.epochMs), true)
                assert.ok(events.nextEvent.epochMs > sampleEpoch)
              }
            }
          }
        }
      }
    })
}
