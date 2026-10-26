/* Shared verbatim by Node and iOS JavaScriptCore. No network, filesystem, or DOM. */
(function (root) {
  'use strict';
  const VERSION = 1;
  const PLATFORMS = ['doordash', 'uber_eats', 'grubhub'];
  const DEFAULTS = Object.freeze({ centsPerMile: 100, minimumOfferCents: null,
    hourlyTargetCents: null, hourlyBasis: 'gross', vehicleCentsPerMile: null, timeFactors: null, returnTimeShare: 1, slowBar: null });
  const has = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);
  const clone = value => JSON.parse(JSON.stringify(value));
  function assert(ok, message) { if (!ok) throw new Error(message); }
  function object(value, name) {
    assert(value !== null && typeof value === 'object' && !Array.isArray(value), name + ' must be an object');
  }
  function keys(value, allowed, name) {
    object(value, name);
    Object.keys(value).forEach(key => assert(allowed.includes(key), name + ': unexpected field ' + key));
  }
  function integer(value, name, min, max) {
    assert(Number.isSafeInteger(value) && value >= min && value <= max, name + ' is out of range');
  }
  function nullableInteger(value, name, min, max) { if (value !== null) integer(value, name, min, max); }
  function oneOf(value, choices, name) { assert(choices.includes(value), 'Invalid ' + name); }
  function id(value, name) {
    assert(typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$/.test(value) &&
      !['constructor', 'prototype', '__proto__'].includes(value), 'Invalid ' + name);
  }
  function time(value) {
    assert(typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(value), 'Timestamp must include timezone');
    const ms = Date.parse(value);
    assert(Number.isFinite(ms), 'Invalid timestamp');
    return ms;
  }
  function canonical(value) {
    if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
    if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + canonical(value[k])).join(',') + '}';
    assert(value === null || ['string', 'boolean', 'number'].includes(typeof value), 'Event contains a non-JSON value');
    if (typeof value === 'number') assert(Number.isFinite(value), 'Event contains a non-finite number');
    return JSON.stringify(value);
  }
  function settings(input) {
    keys(input || {}, Object.keys(DEFAULTS), 'settings');
    const s = Object.assign({}, DEFAULTS, input || {});
    integer(s.centsPerMile, 'centsPerMile', 1, 10000);
    nullableInteger(s.minimumOfferCents, 'minimumOfferCents', 0, 1000000);
    nullableInteger(s.hourlyTargetCents, 'hourlyTargetCents', 0, 1000000);
    nullableInteger(s.vehicleCentsPerMile, 'vehicleCentsPerMile', 0, 10000);
    oneOf(s.hourlyBasis, ['gross', 'after_vehicle_expenses'], 'hourlyBasis');
    // Share of the drive-back minutes counted toward $/hr (core/shift.js returnShare: the next order often comes on the
    // way back, user Oct 24). Miles always count the whole drive back.
    assert(typeof s.returnTimeShare === 'number' && s.returnTimeShare >= 0 && s.returnTimeShare <= 1, 'returnTimeShare');
    // Learned per app from your own orders (core/shift.js timeFactors): estimated trip times × this.
    if (s.timeFactors !== null) {
      object(s.timeFactors, 'timeFactors');
      for (const k of Object.keys(s.timeFactors)) assert(typeof s.timeFactors[k] === 'number' && s.timeFactors[k] >= 0.5 && s.timeFactors[k] <= 3, 'timeFactors.' + k);
    }
    // Slow hours (user, Oct 26): a lower bar for when good offers are rare — { hourlyCents, centsPerMile, band, reason }.
    if (s.slowBar !== null) {
      object(s.slowBar, 'slowBar');
      integer(s.slowBar.hourlyCents, 'slowBar.hourlyCents', 0, 1000000);
      integer(s.slowBar.centsPerMile, 'slowBar.centsPerMile', 1, 10000);
    }
    return s;
  }
  function validateRoute(r) {
    keys(r, ['toPickupMilliMiles', 'deliveryMilliMiles', 'outboundMilliMiles', 'returnMilliMiles', 'minutesLow', 'minutesHigh', 'source', 'conflicts'], 'route');
    ['toPickupMilliMiles', 'deliveryMilliMiles', 'returnMilliMiles'].forEach(k => nullableInteger(r[k], k, 0, 10000000));
    // Optional: one platform-reported figure from the current location through the final drop-off.
    if (has(r, 'outboundMilliMiles')) {
      nullableInteger(r.outboundMilliMiles, 'outboundMilliMiles', 0, 10000000);
      if (r.outboundMilliMiles !== null) assert(r.toPickupMilliMiles === null && r.deliveryMilliMiles === null, 'Inclusive outbound mileage cannot be combined with separate legs');
    }
    ['minutesLow', 'minutesHigh'].forEach(k => nullableInteger(r[k], k, 1, 1440));
    assert((r.minutesLow === null) === (r.minutesHigh === null), 'Time range must be complete');
    if (r.minutesLow !== null) assert(r.minutesHigh >= r.minutesLow, 'Reversed time range');
    oneOf(r.source, ['fixture', 'verified_routing', 'unavailable'], 'route source');
    assert(typeof r.conflicts === 'boolean', 'conflicts must be a boolean');
  }
  function validateOffer(o) {
    keys(o, ['offerId', 'platform', 'merchantKey', 'orderType', 'payCents', 'payBasis', 'route', 'source', 'confidence'], 'offer');
    id(o.offerId, 'offerId'); oneOf(o.platform, PLATFORMS, 'platform');
    id(o.merchantKey, 'merchantKey'); oneOf(o.orderType, ['food', 'shop', 'other'], 'orderType');
    nullableInteger(o.payCents, 'payCents', 0, 1000000);
    oneOf(o.payBasis, ['displayed_estimate', 'guaranteed', 'unknown'], 'payBasis');
    oneOf(o.source, ['fixture', 'verified_adapter', 'unverified_adapter'], 'offer source');
    assert(Number.isFinite(o.confidence) && o.confidence >= 0 && o.confidence <= 1, 'Invalid confidence');
    validateRoute(o.route);
  }
  function evaluateOffer(offer, inputSettings) {
    validateOffer(offer);
    const s = settings(inputSettings), r = offer.route;
    const missing = [], failed = [], notes = [];
    if (offer.payCents === null || offer.payBasis === 'unknown') missing.push('Offered pay is unverified');
    if (offer.source === 'unverified_adapter' || offer.confidence < 0.9) missing.push('Offer reading needs verification');
    if (r.source === 'unavailable') missing.push('Driving route is unverified');
    const inclusive = has(r, 'outboundMilliMiles') && r.outboundMilliMiles !== null;
    const outbound = inclusive ? r.outboundMilliMiles : r.toPickupMilliMiles !== null && r.deliveryMilliMiles !== null ? r.toPickupMilliMiles + r.deliveryMilliMiles : null;
    if (outbound === null) missing.push('Pickup or delivery distance is missing');
    if (r.returnMilliMiles === null) missing.push('Return distance to __HOME_NAME__ is missing');
    const total = outbound === null || r.returnMilliMiles === null ? null : outbound + r.returnMilliMiles;
    if (total === 0) missing.push('Total driving distance must be greater than zero');
    const pay = offer.payCents;
    const ratio = total > 0 && pay !== null ? pay * 10 / total : null;
    // Longest return that still meets the mileage rule; negative means it fails before any return driving.
    const maxReturn = pay !== null && outbound !== null ? Math.floor(pay * 1000 / s.centsPerMile) - outbound : null;
    // Compare integer cents*milliMiles before any UI rounding.
    const mileageMeets = total > 0 && pay !== null ? pay * 1000 >= s.centsPerMile * total : maxReturn !== null && maxReturn < 0 ? false : null;
    if (mileageMeets === false) failed.push(total === null ? 'Below the total-mileage target even before the return trip' : 'Below the total-mileage target');
    if (s.minimumOfferCents !== null && pay !== null && pay < s.minimumOfferCents) failed.push('Below the minimum payout');
    const expense = s.vehicleCentsPerMile !== null && total !== null ? s.vehicleCentsPerMile * total / 1000 : null;
    const net = pay !== null && expense !== null ? pay - expense : null;
    const hourly = pay !== null && r.minutesLow !== null ? { lowCents: pay * 60 / r.minutesHigh, highCents: pay * 60 / r.minutesLow } : null;
    const netHourly = net !== null && r.minutesLow !== null ? { lowCents: Math.min(net * 60 / r.minutesHigh, net * 60 / r.minutesLow), highCents: Math.max(net * 60 / r.minutesHigh, net * 60 / r.minutesLow) } : null;
    if (s.hourlyTargetCents !== null) {
      const selected = s.hourlyBasis === 'gross' ? hourly : netHourly;
      if (selected === null) missing.push('Hourly target cannot be checked without time and applicable expenses');
      else if (selected.lowCents < s.hourlyTargetCents) failed.push('Below the hourly target at the slower time estimate');
    }
    if (r.minutesLow === null) notes.push('Time estimate unavailable; mileage result only');
    if (r.conflicts) failed.push('Conflicts with an existing delivery');
    if (offer.payBasis === 'displayed_estimate') notes.push('Displayed pay is an estimate; final payout may change');
    if (s.vehicleCentsPerMile === null) notes.push('Vehicle expenses have not been configured');
    const required = total !== null ? Math.ceil(s.centsPerMile * total / 1000) : null;
    const shortfall = required !== null && pay !== null ? Math.max(0, required - pay) : null;
    // Only the user's specific example is recognized; no invented general exception threshold.
    const exampleCandidate = pay === 3900 && outbound === 20000 && failed.length === 1 && mileageMeets === false;
    const status = missing.length ? 'insufficient_data' : failed.length ? (exampleCandidate ? 'exception_candidate' : 'below_target') : 'meets_targets';
    return { status, totalMilliMiles: total, outboundMilliMiles: outbound, dollarsPerTotalMile: ratio,
      dollarsPerOutboundMile: pay !== null && outbound > 0 ? pay * 10 / outbound : null, maxReturnMilliMilesForTarget: maxReturn, mileageMeets,
      mileageShortfallCents: shortfall, estimatedExpenseCents: expense, estimatedAfterExpenseCents: net,
      grossHourly: hourly, afterExpenseHourly: netHourly, minutesLow: r.minutesLow, minutesHigh: r.minutesHigh,
      reasons: missing.concat(failed), notes, requiresDriverDecision: true };
  }
  function evaluateAddon(current, combined, inputSettings) {
    validateOffer(current); validateOffer(combined);
    const before = evaluateOffer(current, inputSettings), after = evaluateOffer(combined, inputSettings);
    return { combined: after,
      extraPayCents: current.payCents === null || combined.payCents === null ? null : combined.payCents - current.payCents,
      extraMilliMiles: before.totalMilliMiles === null || after.totalMilliMiles === null ? null : after.totalMilliMiles - before.totalMilliMiles,
      extraMinutesLow: current.route.minutesLow === null || combined.route.minutesLow === null ? null : combined.route.minutesLow - current.route.minutesLow,
      extraMinutesHigh: current.route.minutesHigh === null || combined.route.minutesHigh === null ? null : combined.route.minutesHigh - current.route.minutesHigh };
  }
  function initialState() {
    return { schemaVersion: VERSION, mode: null, seen: {}, lastAt: null, shifts: {}, offers: {}, outings: {}, segments: {}, waits: {}, capture: {}, availability: {} };
  }
  const payloadKeys = {
    'shift.started': ['shiftId', 'mode'], 'shift.ended': ['shiftId'],
    'capture.health': ['shiftId', 'platform', 'status', 'coverage'],
    'availability.changed': ['shiftId', 'platform', 'available'],
    'offer.observed': ['shiftId', 'offer'],
    'offer.status': ['shiftId', 'offerId', 'status', 'evidence', 'outingId'],
    'offer.payment': ['shiftId', 'offerId', 'payCents', 'stage'],
    'outing.started': ['shiftId', 'outingId'], 'outing.ended': ['shiftId', 'outingId'],
    'trip.segment': ['shiftId', 'outingId', 'segmentId', 'startedAt', 'endedAt', 'milliMiles', 'kind'],
    'merchant.wait': ['shiftId', 'offerId', 'minutes']
  };
  function applyEvent(state, event) {
    keys(event, ['schemaVersion', 'id', 'at', 'type', 'payload'], 'event');
    assert(event.schemaVersion === VERSION, 'Unsupported event schema');
    id(event.id, 'event id'); const at = time(event.at);
    assert(has(payloadKeys, event.type), 'Unsupported event type');
    keys(event.payload, payloadKeys[event.type], 'payload');
    const encoded = canonical(event);
    if (has(state.seen, event.id)) { assert(state.seen[event.id] === encoded, 'Event ID collision'); return state; }
    assert(state.lastAt === null || at >= time(state.lastAt), 'Out-of-order event; reconciliation is required');
    const next = clone(state), p = event.payload;
    id(p.shiftId, 'shiftId');
    if (p.outingId !== undefined && p.outingId !== null) id(p.outingId, 'outingId');
    const shift = next.shifts[p.shiftId];
    if (event.type !== 'shift.started') {
      assert(shift, 'Unknown shift');
      assert(shift.endedAt === null || event.type === 'offer.payment', 'Shift is already closed');
    }
    function offerRecord() {
      id(p.offerId, 'offerId'); const o = next.offers[p.offerId];
      assert(o && o.shiftId === p.shiftId, 'Unknown offer in this shift'); return o;
    }
    function outingRecord() {
      id(p.outingId, 'outingId'); const o = next.outings[p.outingId];
      assert(o && o.shiftId === p.shiftId, 'Unknown outing in this shift'); return o;
    }
    switch (event.type) {
      case 'shift.started':
        assert(!shift, 'Shift already exists');
        assert(!Object.values(next.shifts).some(s => s.endedAt === null), 'Another shift is open');
        oneOf(p.mode, ['fixture', 'live'], 'shift mode');
        assert(next.mode === null || next.mode === p.mode, 'Fixture and live data must use separate journals');
        next.mode = p.mode;
        next.shifts[p.shiftId] = { startedAt: event.at, endedAt: null };
        break;
      case 'shift.ended':
        shift.endedAt = event.at;
        break;
      case 'capture.health':
        oneOf(p.platform, PLATFORMS, 'platform');
        oneOf(p.status, ['observing', 'paused', 'stopped', 'interrupted'], 'capture status');
        oneOf(p.coverage, ['visible_only', 'verified_full', 'none'], 'capture coverage');
        assert(p.status === 'observing' || p.coverage === 'none', 'Inactive capture cannot claim coverage');
        next.capture[p.platform] = { at: event.at, shiftId: p.shiftId, status: p.status, coverage: p.coverage };
        break;
      case 'availability.changed':
        oneOf(p.platform, PLATFORMS, 'platform'); assert(typeof p.available === 'boolean', 'available must be a boolean');
        next.availability[p.platform] = { at: event.at, shiftId: p.shiftId, available: p.available };
        break;
      case 'offer.observed': {
        validateOffer(p.offer);
        const isFixture = p.offer.source === 'fixture' || p.offer.route.source === 'fixture';
        assert(next.mode === 'fixture' || !isFixture, 'Fixture offer cannot enter live journal');
        assert(!has(next.offers, p.offer.offerId), 'Offer already observed; adapter must deduplicate or explicitly reconcile');
        next.offers[p.offer.offerId] = { shiftId: p.shiftId, observedAt: event.at, offer: clone(p.offer), status: 'pending', observationGap: false, outingId: null, provisionalCents: null, finalCents: null };
        break;
      }
      case 'offer.status': {
        const o = offerRecord();
        const expected = { accepted: 'assignment', declined: 'explicit_decline', expired: 'expiry', lost: 'withdrawn', canceled: 'cancellation', completed: 'completion', unknown: 'missing' };
        assert(has(expected, p.status) && p.evidence === expected[p.status], 'Status needs matching evidence');
        if (p.status === 'unknown') { o.observationGap = true; if (o.status === 'pending') o.status = 'unknown'; break; }
        const allowed = { pending: ['accepted', 'declined', 'expired', 'lost'], unknown: ['accepted', 'declined', 'expired', 'lost'], accepted: ['canceled', 'completed'], declined: [], expired: [], lost: [], canceled: [], completed: [] };
        assert(allowed[o.status].includes(p.status), 'Invalid offer status transition');
        if (p.outingId !== undefined && p.outingId !== null) {
          assert(['accepted', 'completed', 'canceled'].includes(p.status), 'Unassigned offer cannot belong to an outing');
          const outing = outingRecord(); assert(outing.endedAt === null, 'Outing is closed');
          assert(o.outingId === null || o.outingId === p.outingId, 'Cannot move offer between outings');
          o.outingId = p.outingId;
        }
        o.status = p.status; o.statusAt = event.at;
        break;
      }
      case 'offer.payment': {
        const o = offerRecord(); integer(p.payCents, 'payCents', 0, 1000000);
        oneOf(p.stage, ['provisional', 'final'], 'payment stage');
        assert(['accepted', 'completed', 'canceled'].includes(o.status), 'Payment requires an assigned delivery');
        if (p.stage === 'final') {
          assert(['completed', 'canceled'].includes(o.status), 'Final payout requires completion or cancellation');
          o.finalCents = p.payCents; o.finalAt = event.at;
        } else { o.provisionalCents = p.payCents; }
        break;
      }
      case 'outing.started':
        id(p.outingId, 'outingId'); assert(!has(next.outings, p.outingId), 'Outing already exists');
        assert(!Object.values(next.outings).some(o => o.shiftId === p.shiftId && o.endedAt === null), 'Another outing is open');
        next.outings[p.outingId] = { shiftId: p.shiftId, startedAt: event.at, endedAt: null };
        break;
      case 'outing.ended':
        assert(outingRecord().endedAt === null, 'Outing is already closed');
        assert(!Object.values(next.offers).some(o => o.outingId === p.outingId && o.status === 'accepted'), 'Cannot close outing with active deliveries');
        outingRecord().endedAt = event.at;
        break;
      case 'trip.segment': {
        const outing = outingRecord(); assert(outing.endedAt === null, 'Outing is closed');
        id(p.segmentId, 'segmentId'); assert(!has(next.segments, p.segmentId), 'Segment already recorded');
        integer(p.milliMiles, 'milliMiles', 0, 10000000); oneOf(p.kind, ['delivery', 'return', 'reposition'], 'segment kind');
        const start = time(p.startedAt), end = time(p.endedAt);
        assert(start >= time(outing.startedAt) && end > start && end <= at, 'Invalid observed segment interval');
        Object.values(next.segments).filter(s => s.shiftId === p.shiftId).forEach(s => {
          assert(end <= time(s.startedAt) || start >= time(s.endedAt), 'Overlapping mileage segments would double-count driving');
        });
        next.segments[p.segmentId] = clone(p); break;
      }
      case 'merchant.wait': {
        const o = offerRecord(); assert(o.status === 'completed', 'Learn wait times only from completed deliveries');
        assert(!has(next.waits, p.offerId), 'Wait observation already recorded');
        integer(p.minutes, 'wait minutes', 0, 360);
        next.waits[p.offerId] = { at: o.observedAt, minutes: p.minutes, merchantKey: o.offer.merchantKey, orderType: o.offer.orderType }; break;
      }
    }
    next.seen[event.id] = encoded; next.lastAt = event.at;
    return next;
  }
  function replay(events) { assert(Array.isArray(events), 'Events must be an array'); return events.reduce(applyEvent, initialState()); }
  function captureHealth(state, now) {
    const at = time(now);
    return PLATFORMS.map(platform => {
      const h = state.capture[platform], a = state.availability[platform];
      const activeShift = h && state.shifts[h.shiftId] && state.shifts[h.shiftId].endedAt === null;
      const age = h ? at - time(h.at) : null;
      const observing = !!(h && activeShift && age >= 0 && age <= 30000 && h.status === 'observing');
      return { platform, status: observing ? 'observing' : h && activeShift && h.status === 'observing' && (age > 30000 || age < 0) ? 'stale' : h && !activeShift ? 'stopped' : h ? h.status : 'not_connected',
        coverage: observing ? h.coverage : 'none',
        canMeasureWaiting: !!(observing && h.coverage === 'verified_full' && a && a.shiftId === h.shiftId && a.available) };
    });
  }
  function totalsFor(records, segments, minutes, s) {
    const final = records.filter(o => o.finalCents !== null), unfinishedPay = records.filter(o => ['accepted', 'completed', 'canceled'].includes(o.status) && o.finalCents === null);
    const finalPayCents = final.reduce((n, o) => n + o.finalCents, 0);
    const provisionalPayCents = unfinishedPay.filter(o => o.provisionalCents !== null).reduce((n, o) => n + o.provisionalCents, 0);
    const actualMilliMiles = segments.reduce((n, seg) => n + seg.milliMiles, 0);
    const expense = s.vehicleCentsPerMile === null ? null : actualMilliMiles * s.vehicleCentsPerMile / 1000;
    return { finalPayCents, provisionalPayCents, unfinalizedDeliveries: unfinishedPay.length, actualMilliMiles,
      observedReturnMilliMiles: segments.filter(seg => seg.kind === 'return').reduce((n, seg) => n + seg.milliMiles, 0),
      elapsedMinutes: minutes, estimatedVehicleExpenseCents: expense,
      finalPayHourlyCents: minutes > 0 ? finalPayCents * 60 / minutes : null,
      finalPayAfterExpenseCents: expense === null ? null : finalPayCents - expense,
      mileageCoverage: 'observed_segments_only' };
  }
  function shiftSummary(state, shiftId, now, inputSettings) {
    id(shiftId, 'shiftId'); const shift = state.shifts[shiftId]; assert(shift, 'Unknown shift');
    const end = time(shift.endedAt || now), start = time(shift.startedAt); assert(end >= start, 'Summary time precedes shift');
    const s = settings(inputSettings), records = Object.values(state.offers).filter(o => o.shiftId === shiftId);
    const segments = Object.values(state.segments).filter(seg => seg.shiftId === shiftId);
    const outings = Object.keys(state.outings).filter(key => state.outings[key].shiftId === shiftId).map(outingId => {
      const o = state.outings[outingId], stop = Math.min(end, time(o.endedAt || now));
      return Object.assign({ outingId, returned: o.endedAt !== null }, totalsFor(records.filter(r => r.outingId === outingId), segments.filter(seg => seg.outingId === outingId), (stop - time(o.startedAt)) / 60000, s));
    });
    const counts = {}; records.forEach(o => { counts[o.status] = (counts[o.status] || 0) + 1; });
    return Object.assign({ shiftId, mode: state.mode, status: shift.endedAt ? 'ended' : 'open', counts, outings }, totalsFor(records, segments, (end - start) / 60000, s));
  }
  function localBucket(at) {
    const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'America/Chicago', weekday: 'short', hour: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(time(at)));
    const get = type => parts.find(p => p.type === type).value;
    return { day: get('weekday'), block: Math.floor(Number(get('hour')) / 3) };
  }
  function predictMerchantWait(state, merchantKey, orderType, now) {
    id(merchantKey, 'merchantKey'); oneOf(orderType, ['food', 'shop', 'other'], 'orderType');
    const at = time(now), bucket = localBucket(now);
    const samples = Object.values(state.waits).filter(w => {
      const b = localBucket(w.at), age = at - time(w.at);
      return w.merchantKey === merchantKey && w.orderType === orderType && age >= 0 && age <= 90 * 86400000 && b.day === bucket.day && b.block === bucket.block;
    });
    if (samples.length < 3) return { status: 'insufficient_data', sampleCount: samples.length, minutes: null };
    let numerator = 0, denominator = 0;
    samples.forEach(w => { const weight = Math.pow(0.5, (at - time(w.at)) / (14 * 86400000)); numerator += w.minutes * weight; denominator += weight; });
    return { status: 'estimate', sampleCount: samples.length, minutes: numerator / denominator,
      observedLowMinutes: Math.min.apply(null, samples.map(w => w.minutes)), observedHighMinutes: Math.max.apply(null, samples.map(w => w.minutes)),
      note: 'Observed range, not a statistical confidence interval; recent completed trips weighted more heavily' };
  }
  function snapshot(events, inputSettings, now) {
    const state = replay(events), s = settings(inputSettings);
    return { schemaVersion: VERSION, mode: state.mode, waitingSpot: '__HOME_NAME__',
      offers: Object.values(state.offers).map(record => ({ offerId: record.offer.offerId, platform: record.offer.platform,
        merchantKey: record.offer.merchantKey, payCents: record.offer.payCents, status: record.status,
        finalCents: record.finalCents, assessment: evaluateOffer(record.offer, s) })),
      capture: captureHealth(state, now),
      shifts: Object.keys(state.shifts).map(shiftId => shiftSummary(state, shiftId, now, s)) };
  }
  const api = { VERSION, DEFAULTS, PLATFORMS, settings, validateOffer, evaluateOffer, evaluateAddon,
    initialState, applyEvent, replay, captureHealth, shiftSummary, predictMerchantWait, snapshot, canonical,
    snapshotJSON: (eventsJSON, settingsJSON, now) => JSON.stringify(snapshot(JSON.parse(eventsJSON), JSON.parse(settingsJSON), now)) };
  root.Copilot = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
