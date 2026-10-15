/* Shared verbatim by Node and iOS JavaScriptCore. No network, filesystem, or DOM.
 * The on-phone journal as append-only events (docs/ROADMAP-ADDENDUM.md §8–11) and the order record derived from
 * them (§2–5). What was observed on screen (`offer_seen`) is kept apart from what Lumen predicted
 * (`prediction_made`, stamped with the logic versions that produced it), so old observations can be replayed through
 * future models. Lifecycle events (accepted … completed / unassigned / cancelled) come from the driver's taps in the app
 * (source 'manual', Oct 14) and later from screen recognizers; an offer card disappearing is never evidence of anything.
 * Multi-stop and stacked orders: stop events carry `stop` (0-based index within the order's pickups or drop-offs) and
 * `tripId` (offers driven together); each store visit is timed separately. `retracted` undoes a mistaken tap.
 * No customer names, streets, or coordinates. */
(function (root) {
  'use strict';
  const SCHEMA = 2;
  // Forward stages (addendum §2, plus arrival at the customer for drop-off overhead). Apps may skip screens, so a
  // stage may be skipped but never reversed.
  const STAGES = ['OFFER_SHOWN', 'ACCEPTED', 'DRIVING_TO_PICKUP', 'ARRIVED_AT_PICKUP', 'WAITING_FOR_PICKUP', 'PICKED_UP',
    'DRIVING_TO_CUSTOMER', 'ARRIVED_AT_CUSTOMER', 'COMPLETED'];
  const STAGE_EVENTS = { offer_seen: 'OFFER_SHOWN', accepted: 'ACCEPTED', driving_to_pickup: 'DRIVING_TO_PICKUP',
    arrived_pickup: 'ARRIVED_AT_PICKUP', waiting_started: 'WAITING_FOR_PICKUP', picked_up: 'PICKED_UP',
    driving_to_customer: 'DRIVING_TO_CUSTOMER', arrived_customer: 'ARRIVED_AT_CUSTOMER', completed: 'COMPLETED' };
  const TIME_KEYS = { offer_seen: 'offer_seen_at', accepted: 'accepted_at', driving_to_pickup: 'driving_to_pickup_at',
    arrived_pickup: 'arrived_at_pickup_at', waiting_started: 'waiting_started_at', picked_up: 'pickup_confirmed_at',
    driving_to_customer: 'driving_to_customer_at', arrived_customer: 'arrived_at_customer_at', completed: 'completed_at' };
  // Early endings of an accepted order: first-class outcomes, not edge cases (§2, §5).
  const CANCELLED_BY = { customer: 'CANCELLED_BY_CUSTOMER', restaurant: 'CANCELLED_BY_RESTAURANT', platform: 'CANCELLED_BY_PLATFORM' };
  const ENDINGS = { unassigned: 'UNASSIGNED_BY_DRIVER', failed_pickup: 'FAILED_PICKUP', aborted_unknown: 'UNKNOWN_ABORT' };
  // Endings before acceptance; only from explicit evidence (a decline tap confirmed, an expiry message).
  const NOT_TAKEN = { declined: 'DECLINED', expired: 'EXPIRED' };
  const REASONS = ['excessive_wait', 'restaurant_closed', 'order_already_picked_up', 'customer_cancelled', 'platform_cancelled',
    'restaurant_cancelled', 'driver_unassigned', 'unknown'];
  const TYPES = Object.keys(STAGE_EVENTS).concat(['prediction_made', 'cancelled', 'available_again', 'delivered', 'retracted', 'pay_adjusted', 'deleted'],
    Object.keys(ENDINGS), Object.keys(NOT_TAKEN));
  // Events that belong to one store or drop-off of a multi-stop order.
  const STOP_EVENTS = { arrived_pickup: 'pickup', picked_up: 'pickup', arrived_customer: 'dropoff', delivered: 'dropoff' };
  // Lifecycle events below this confidence stay in the journal for debugging but do not move an order's state.
  const MIN_EVENT_CONFIDENCE = 0.8;
  // Offer readings below this do not train models (the live notification threshold).
  const MIN_READER_CONFIDENCE = 0.9;

  function assert(ok, message) { if (!ok) throw new Error(message); }
  const ms = at => Date.parse(at);
  function seconds(from, to) {
    if (!from || !to) return null;
    return Math.round((ms(to) - ms(from)) / 1000);
  }
  /* Local weekday (0 = Sunday) and minutes since local midnight, from an ISO time carrying its UTC offset
   * ("2026-10-14T18:11:00-05:00"). The phone writes local offsets so learning can bucket by the driver's own clock. */
  function localParts(at) {
    const m = /(Z|([+-])(\d{2}):?(\d{2}))$/.exec(at || '');
    if (!m || !Number.isFinite(ms(at))) return null;
    const offset = m[1] === 'Z' ? 0 : (m[2] === '-' ? -1 : 1) * (Number(m[3]) * 60 + Number(m[4]));
    const local = new Date(ms(at) + offset * 60000);
    return { weekday: local.getUTCDay(), minuteOfDay: local.getUTCHours() * 60 + local.getUTCMinutes(), offsetMinutes: offset };
  }

  /* One journal event. fields must already be privacy-safe. */
  function event(type, offerId, at, source, confidence, fields) {
    assert(TYPES.includes(type), 'Unknown event type ' + type);
    assert(typeof offerId === 'string' && offerId.length > 0 && offerId.length <= 120, 'Invalid offerId');
    assert(typeof at === 'string' && Number.isFinite(ms(at)), 'Invalid time');
    assert(confidence === null || (typeof confidence === 'number' && confidence >= 0 && confidence <= 1), 'Invalid confidence');
    const stage = fields && fields.stage ? ':' + fields.stage : '';
    return Object.assign({ v: SCHEMA, id: offerId + ':' + type + stage + ':' + Math.floor(ms(at) / 1000), type, offerId, at,
      source: source || 'unknown', confidence }, fields || {});
  }

  /* Recommendation word from a notification line (mirrors ios/Shared/Verdict.swift). */
  function verdictWord(notice) {
    const text = String(notice || '').replace(/^UPDATE · /, '');
    if (/Decline$/.test(text)) return 'Decline';
    if (/· Close call$/.test(text)) return 'CloseCall';
    if (/· Accept \(time unknown\)$/.test(text)) return 'AcceptTimeUnknown';
    if (/· Accept$/.test(text)) return 'Accept';
    if (/^Likely Accept/.test(text)) return 'LikelyAccept';
    if (/^Accept if return/.test(text)) return 'Conditional';
    return 'Check';
  }

  function versions(appBuild) {
    const reader = (root.ScreenReader && root.ScreenReader.VERSIONS) || {};
    return { schema: SCHEMA, appBuild: appBuild === undefined ? null : appBuild, rules: reader.rules || null, reader: reader.reader || null,
      map: (root.MapReader && root.MapReader.VERSION) || null, waitModel: reader.waitModel || null, tripModel: reader.tripModel || null,
      marketModel: reader.marketModel || null, evModel: reader.evModel || null };
  }

  /* The events for one offer, written when its refined verdict is ready:
   *   offer_seen        — only what the card showed (observation, §10)
   *   prediction_made   — stage 'preliminary' and 'refined', each with versions (§9) and data-quality flags (§11)
   * input: { offerId, seenAt, preliminaryAt, refinedAt (ISO with offset), refined (withReturn output), preliminary
   *          { word, notice }, timingsMs, quality { accurateOCR, positionKnown }, appBuild, settings, returnTo }. */
  function offerEvents(input) {
    const r = input.refined || {}, q = input.quality || {}, settings = input.settings || {};
    const v = versions(input.appBuild);
    const readerConfidence = typeof r.confidence === 'number' ? Math.max(0, Math.min(1, r.confidence)) : null;
    const local = localParts(input.seenAt);
    const seen = event('offer_seen', input.offerId, input.seenAt, q.accurateOCR ? 'screen_ocr_accurate' : 'screen_ocr', readerConfidence, {
      observed: { platform: r.platform || null, payCents: r.payCents === undefined ? null : r.payCents,
        appMilliMiles: r.outboundMilliMiles === undefined ? null : r.outboundMilliMiles,
        appMinutes: r.appMinutes === undefined ? null : r.appMinutes, merchant: r.merchant || null,
        dropoffArea: r.dropoffArea || null, orderCount: r.orderCount === undefined ? null : r.orderCount,
        weekday: local ? local.weekday : null, minuteOfDay: local ? local.minuteOfDay : null },
      quality: { mileageRead: r.outboundMilliMiles !== null && r.outboundMilliMiles !== undefined,
        timeShown: r.appMinutes !== null && r.appMinutes !== undefined, accurateOCR: !!q.accurateOCR }
    });
    // returnTo: the destination the user chose in the app (their own place; default __HOME_NAME__).
    const rules = { centsPerMile: settings.centsPerMile || 100, hourlyTargetCents: settings.hourlyTargetCents === undefined ? null : settings.hourlyTargetCents,
      returnTo: input.returnTo || '__HOME_NAME__' };
    const prelim = input.preliminary || { word: 'Unreadable', notice: 'Check offer' };
    const first = event('prediction_made', input.offerId, input.preliminaryAt || input.seenAt, 'lumen', readerConfidence, {
      stage: 'preliminary', verdict: verdictWord(prelim.notice), notice: prelim.notice, versions: v, rules,
      inputs: { positionKnown: !!q.positionKnown } });
    const kind = r.returnKind || null;
    const refined = event('prediction_made', input.offerId, input.refinedAt || input.seenAt, 'lumen', readerConfidence, {
      stage: 'refined', verdict: verdictWord(r.notice), notice: r.notice || null, tone: r.tone || null, versions: v, rules,
      predicted: { returnMilliMiles: r.returnMilliMiles === undefined ? null : r.returnMilliMiles, returnKind: kind,
        uncertaintyMilliMiles: r.uncertaintyMilliMiles === undefined ? null : r.uncertaintyMilliMiles,
        creditMilliMiles: r.creditMilliMiles === undefined ? null : r.creditMilliMiles,
        creditMinutes: r.creditMinutes === undefined ? null : r.creditMinutes,
        effectiveMilliMiles: r.effectiveMilliMiles === undefined ? null : r.effectiveMilliMiles,
        returnMinutes: r.returnMinutes === undefined ? null : r.returnMinutes,
        tripMinutes: r.tripMinutes === undefined ? null : r.tripMinutes,
        tripMinutesEstimated: r.tripMinutesEstimated === undefined ? null : r.tripMinutesEstimated,
        hourlyCents: r.hourlyCents === undefined ? null : r.hourlyCents,
        maxReturnMilliMiles: r.maxReturnMilliMiles === undefined ? null : r.maxReturnMilliMiles },
      quality: { returnFound: r.returnMilliMiles !== null && r.returnMilliMiles !== undefined,
        returnIsBound: kind === 'worst_case', mapSolved: kind === 'map', positionKnown: !!q.positionKnown,
        updatedNotification: !!r.updated },
      timingsMs: input.timingsMs || {} });
    return [seen, first, refined];
  }

  function emptyOrder(offerId) {
    return { offerId, platform: null, merchant: null, originalOfferPayCents: null, appMilliMiles: null, appMinutes: null,
      readerConfidence: null, weekday: null, minuteOfDay: null, predictions: {}, stage: null, outcome: 'UNKNOWN', reason: null,
      stageWhenEnded: null, acceptance: null, times: {}, durationsSec: {}, restaurantWait: null, tripId: null, stacked: false,
      pickupStops: [], dropoffStops: [],
      actualCompensationCents: null, milesBeforeExitMilli: null, actual: null, issues: [], trainable: false };
  }

  /* Folds one offer's events (any order on input; applied chronologically) into its order record. */
  function deriveOrder(events, options) {
    const minConfidence = options && Number.isFinite(options.minConfidence) ? options.minConfidence : MIN_EVENT_CONFIDENCE;
    // A retracted event (undo of a mistaken tap) is dropped along with the retraction.
    const retracted = new Set(events.filter(e => e.type === 'retracted').map(e => e.target));
    const list = events.filter(e => e.type !== 'retracted' && !retracted.has(e.id)).sort((a, b) => ms(a.at) - ms(b.at));
    const o = emptyOrder(list.length ? list[0].offerId : null);
    let index = -1, ended = false;
    const note = text => { if (!o.issues.includes(text)) o.issues.push(text); };
    for (const e of list) {
      if (e.type === 'prediction_made') { o.predictions[e.stage] = { verdict: e.verdict, notice: e.notice, versions: e.versions, at: e.at }; continue; }
      if (e.type === 'offer_seen') {
        const ob = e.observed || {};
        if (o.times.offer_seen_at) continue;
        o.times.offer_seen_at = e.at; o.platform = ob.platform || null; o.merchant = ob.merchant || null;
        o.originalOfferPayCents = ob.payCents === undefined ? null : ob.payCents; o.appMilliMiles = ob.appMilliMiles === undefined ? null : ob.appMilliMiles;
        o.appMinutes = ob.appMinutes === undefined ? null : ob.appMinutes; o.readerConfidence = e.confidence;
        o.weekday = ob.weekday === undefined ? null : ob.weekday; o.minuteOfDay = ob.minuteOfDay === undefined ? null : ob.minuteOfDay;
        if (index < 0) { index = 0; o.stage = STAGES[0]; }
        continue;
      }
      if (e.confidence !== null && e.confidence !== undefined && e.confidence < minConfidence) { note('low_confidence:' + e.type); continue; }
      if (e.type === 'available_again') { if (ended && !o.times.available_again_at) o.times.available_again_at = e.at; continue; }
      // The driver's corrected payout (tips change it), usually after completion.
      if (e.type === 'pay_adjusted') { if (Number.isSafeInteger(e.payCents)) o.actualCompensationCents = e.payCents; continue; }
      if (ended) { note('after_end:' + e.type); continue; }
      if (e.tripId && !o.tripId) o.tripId = e.tripId;
      if (e.type === 'accepted') {
        if (e.stacked) o.stacked = true;
        // A tap in the app carries the offer it accepted, for installs whose app can't read the reader's journal.
        const f = e.offer || {};
        if (o.platform === null && f.platform) o.platform = f.platform;
        if (o.merchant === null && f.merchant) o.merchant = f.merchant;
        if (o.originalOfferPayCents === null && Number.isSafeInteger(f.payCents)) o.originalOfferPayCents = f.payCents;
        if (o.appMilliMiles === null && Number.isSafeInteger(f.appMilliMiles)) o.appMilliMiles = f.appMilliMiles;
        if (o.readerConfidence === null && typeof f.readerConfidence === 'number') o.readerConfidence = f.readerConfidence;
      }
      if (STOP_EVENTS[e.type] && Number.isSafeInteger(e.stop) && e.stop >= 0 && e.stop < 20) {
        // Multi-stop orders revisit stages (store 2 after leaving store 1), so stops are ordered per stop, not globally.
        const kind = STOP_EVENTS[e.type], stops = kind === 'pickup' ? o.pickupStops : o.dropoffStops;
        const stop = stops[e.stop] = stops[e.stop] || { stop: e.stop, store: null, arrivedAt: null, doneAt: null };
        if (e.store && !stop.store) stop.store = String(e.store).slice(0, 80);
        const arriving = e.type === 'arrived_pickup' || e.type === 'arrived_customer';
        if (arriving ? stop.arrivedAt : stop.doneAt) { note('repeated:' + e.type); continue; }
        if (!arriving && stop.arrivedAt && ms(e.at) < ms(stop.arrivedAt)) { note('out_of_order:' + e.type); continue; }
        if (arriving) stop.arrivedAt = e.at; else stop.doneAt = e.at;
        if (!o.acceptance) o.acceptance = 'implied_by_' + e.type;
        if (STAGE_EVENTS[e.type]) {
          if (!o.times[TIME_KEYS[e.type]]) o.times[TIME_KEYS[e.type]] = e.at;
          const next = STAGES.indexOf(STAGE_EVENTS[e.type]);
          if (next > index) { index = next; o.stage = STAGES[next]; }
        }
        continue;
      }
      if (e.type === 'delivered') continue; // A drop-off without a stop index carries no timing of its own.
      if (STAGE_EVENTS[e.type]) {
        const next = STAGES.indexOf(STAGE_EVENTS[e.type]);
        if (next < index) { note('out_of_order:' + e.type); continue; }
        if (!o.times[TIME_KEYS[e.type]]) o.times[TIME_KEYS[e.type]] = e.at;
        index = next; o.stage = STAGES[next];
        // A post-acceptance screen (heading to the store, picked up, …) is positive evidence of assignment.
        if (e.type === 'accepted') o.acceptance = 'observed';
        else if (next > 1 && !o.acceptance) o.acceptance = 'implied_by_' + e.type;
        if (e.type === 'completed') {
          ended = true; o.outcome = 'COMPLETED'; o.stageWhenEnded = 'COMPLETED'; o.times.ended_at = e.at;
          if (Number.isSafeInteger(e.payCents)) o.actualCompensationCents = e.payCents;
        }
        continue;
      }
      if (NOT_TAKEN[e.type]) {
        if (o.acceptance) { note('not_taken_after_acceptance:' + e.type); continue; }
        ended = true; o.outcome = NOT_TAKEN[e.type]; o.stageWhenEnded = o.stage; o.times.ended_at = e.at;
        continue;
      }
      // Early endings: unassigned, cancelled, failed pickup, unknown abort.
      if (!o.acceptance) o.acceptance = 'implied_by_' + e.type;
      ended = true; o.stageWhenEnded = o.stage; o.times.ended_at = e.at;
      if (e.type === 'cancelled') {
        o.outcome = CANCELLED_BY[e.by] || 'UNKNOWN_ABORT'; o.times.cancelled_at = e.at;
        o.reason = REASONS.includes(e.reason) ? e.reason : CANCELLED_BY[e.by] ? e.by + '_cancelled' : 'unknown';
      } else {
        o.outcome = ENDINGS[e.type];
        if (e.type === 'unassigned') o.times.unassigned_at = e.at;
        o.reason = REASONS.includes(e.reason) ? e.reason : e.type === 'unassigned' ? 'driver_unassigned' : 'unknown';
      }
      if (Number.isSafeInteger(e.payCents)) o.actualCompensationCents = e.payCents;
      if (Number.isSafeInteger(e.milliMiles)) o.milesBeforeExitMilli = e.milliMiles;
    }
    derive(o);
    o.trainable = o.issues.length === 0 && o.readerConfidence !== null && o.readerConfidence >= MIN_READER_CONFIDENCE;
    // The driver deleted this order from their history: kept in the journal, never learned from.
    if (list.some(e => e.type === 'deleted')) { o.outcome = 'DELETED'; o.trainable = false; }
    return o;
  }

  /* Durations in seconds (addendum §3). Restaurant wait is right-censored when the order ended before pickup (§4):
   * "food not ready within N minutes", never "wait = N minutes". */
  function derive(o) {
    const t = o.times, d = o.durationsSec;
    const put = (key, value) => {
      if (value === null) return;
      if (value < 0) { o.issues.push('negative_duration:' + key); return; }
      d[key] = value;
    };
    put('decision_time', seconds(t.offer_seen_at, t.accepted_at));
    put('drive_to_restaurant', seconds(t.driving_to_pickup_at || t.accepted_at, t.arrived_at_pickup_at));
    const waitStart = t.waiting_started_at || t.arrived_at_pickup_at;
    if (waitStart && t.pickup_confirmed_at) {
      o.restaurantWait = { seconds: seconds(waitStart, t.pickup_confirmed_at), censored: false };
    } else if (waitStart && t.ended_at && o.outcome !== 'COMPLETED') {
      o.restaurantWait = { seconds: seconds(waitStart, t.ended_at), censored: true };
    }
    if (o.restaurantWait) put('restaurant_wait', o.restaurantWait.seconds);
    // Each store of a multi-stop or stacked order: arrival → left, censored if the order ended first.
    o.pickupStops = o.pickupStops.filter(Boolean);
    o.dropoffStops = o.dropoffStops.filter(Boolean);
    for (const stop of o.pickupStops) {
      stop.waitSec = stop.arrivedAt && stop.doneAt ? seconds(stop.arrivedAt, stop.doneAt)
        : stop.arrivedAt && t.ended_at && o.outcome !== 'COMPLETED' ? seconds(stop.arrivedAt, t.ended_at) : null;
      stop.censored = stop.waitSec !== null && !stop.doneAt;
    }
    for (const stop of o.dropoffStops) stop.handoffSec = stop.arrivedAt && stop.doneAt ? seconds(stop.arrivedAt, stop.doneAt) : null;
    // Time at the restaurant that is not waiting for food: walking in (arrival → waiting) and out (pickup → driving).
    const walkIn = seconds(t.arrived_at_pickup_at, t.waiting_started_at), walkOut = seconds(t.pickup_confirmed_at, t.driving_to_customer_at);
    if (walkIn !== null || walkOut !== null) put('pickup_overhead', (walkIn || 0) + (walkOut || 0));
    put('drive_to_customer', seconds(t.driving_to_customer_at || t.pickup_confirmed_at, t.arrived_at_customer_at || t.completed_at));
    put('dropoff_overhead', seconds(t.arrived_at_customer_at, t.completed_at));
    put('total_commitment', seconds(t.accepted_at, t.ended_at));
    // The order timer (user, Oct 14): accepted → completed, and the hourly pace it actually earned.
    if (o.outcome === 'COMPLETED' && Number.isFinite(d.total_commitment) && d.total_commitment >= 60) {
      const pay = o.actualCompensationCents !== null ? o.actualCompensationCents : o.originalOfferPayCents;
      o.actual = { minutes: Math.round(d.total_commitment / 6) / 10,
        hourlyCents: pay === null ? null : Math.round(pay * 3600 / d.total_commitment) };
    }
    if (o.outcome !== 'COMPLETED' && o.acceptance && t.ended_at) {
      put('time_spent_before_exit', seconds(t.accepted_at, t.ended_at));
      if (o.restaurantWait && o.restaurantWait.censored) put('restaurant_wait_before_exit', o.restaurantWait.seconds);
    }
  }

  /* The running order timer: elapsed time since acceptance and the pace if the order completed now (pay ÷ elapsed).
   * Null unless the order is accepted (with a time) and not ended. */
  function livePace(order, now) {
    if (!order.times.accepted_at || order.times.ended_at) return null;
    const elapsed = seconds(order.times.accepted_at, now);
    if (elapsed === null || elapsed < 0) return null;
    const pay = order.originalOfferPayCents;
    return { elapsedSec: elapsed, paceCents: pay === null || elapsed < 60 ? null : Math.round(pay * 3600 / elapsed) };
  }

  /* All orders from a journal, plus what happened after each one ended (addendum §3): seconds until the next offer, the
   * next good offer (refined verdict Accept), and the next acceptance (post-order idle). Null when nothing followed. */
  function deriveOrders(events, options) {
    const groups = {};
    for (const e of events) (groups[e.offerId] = groups[e.offerId] || []).push(e);
    const orders = Object.keys(groups).map(id => deriveOrder(groups[id], options));
    const byTime = key => orders.filter(o => o.times[key]).sort((a, b) => ms(a.times[key]) - ms(b.times[key]));
    const offers = byTime('offer_seen_at'), accepts = byTime('accepted_at');
    for (const o of orders) {
      if (!o.acceptance || !o.times.ended_at) continue;
      const free = o.times.available_again_at || o.times.ended_at;
      const after = (list, key, keep) => {
        const next = list.find(x => x !== o && ms(x.times[key]) > ms(free) && (!keep || keep(x)));
        return next ? seconds(free, next.times[key]) : null;
      };
      o.durationsSec.time_until_next_offer = after(offers, 'offer_seen_at');
      o.durationsSec.time_until_next_good_offer = after(offers, 'offer_seen_at',
        x => x.predictions.refined && x.predictions.refined.verdict === 'Accept');
      o.durationsSec.post_order_idle_time = after(accepts, 'accepted_at');
    }
    return orders;
  }

  /* Restaurant wait observations for learning (§4, §13): trainable orders only; censored ones are lower bounds.
   * Orders with timed stores give one observation per store (named by the stop, else the order's restaurant). */
  function waitObservations(orders) {
    const perStop = orders.filter(o => o.trainable && o.pickupStops.some(s => s.waitSec !== null)).flatMap(o =>
      o.pickupStops.filter(s => s.waitSec !== null && (s.store || (o.pickupStops.length === 1 && o.merchant))).map(s => {
        const local = localParts(s.arrivedAt);
        return { platform: o.platform, merchant: s.store || o.merchant, weekday: local ? local.weekday : null,
          minuteOfDay: local ? local.minuteOfDay : null, seconds: s.waitSec, censored: s.censored };
      }));
    return perStop.concat(orders.filter(o => o.trainable && o.restaurantWait && o.merchant && !o.pickupStops.some(s => s.waitSec !== null)).map(o => {
      const local = localParts(o.times.waiting_started_at || o.times.arrived_at_pickup_at);
      return { platform: o.platform, merchant: o.merchant, weekday: local ? local.weekday : null,
        minuteOfDay: local ? local.minuteOfDay : null, seconds: o.restaurantWait.seconds, censored: o.restaurantWait.censored };
    }));
  }

  const api = { SCHEMA, STAGES, TYPES, REASONS, MIN_EVENT_CONFIDENCE, MIN_READER_CONFIDENCE, event, verdictWord, versions, localParts,
    offerEvents, deriveOrder, deriveOrders, waitObservations, livePace,
    // JSON bridges for the iPhone.
    offerEventsJSON: inputJSON => JSON.stringify(offerEvents(JSON.parse(inputJSON))),
    deriveOrdersJSON: eventsJSON => JSON.stringify(deriveOrders(JSON.parse(eventsJSON))) };
  root.Lifecycle = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
