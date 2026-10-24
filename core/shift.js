/* Shared verbatim by Node and iOS JavaScriptCore. No network, filesystem, or DOM.
 * Shift totals (user, Oct 14): earnings overall and per app, online/active/idle time, miles by kind, $/online hour,
 * $/active hour, $/mile, completed and unassigned/cancelled orders, restaurant waits, and the live earnings goal.
 * The restaurant database built from offers and store visits, with duplicate merging. CSV export of the driver's own
 * history. Inputs are the app's own records (trips the driver ticked, offers read on screen, mile totals by kind);
 * customer locations are never part of them. */
(function (root) {
  'use strict';
  const METERS_PER_MILE = 1609.344;
  // Two names within this distance are the same store; farther apart they are separate branches.
  const SAME_PLACE_MILES = 0.35;
  const ms = at => (at === null || at === undefined ? NaN : Date.parse(at));
  const valid = v => Number.isFinite(v);

  // MARK: Restaurants

  /* "Buffalo Wild Wings (361 W Townline Rd)" → "buffalo wild wings"; "Crisp & Green" → "crisp and green";
   * "Timothy O'Toole's Pub" → "timothy otooles pub". Used only to compare names. */
  function normalizeName(name) {
    return String(name || '').toLowerCase()
      .replace(/\([^)]*\)/g, ' ')
      .replace(/&/g, ' and ')
      .replace(/['’`]/g, '')
      .replace(/[^a-z0-9]+/g, ' ')
      .replace(/^the /, '')
      .replace(/ (restaurant|restaurants|kitchen|grill)$/, '')
      .replace(/\s+/g, ' ').trim();
  }
  /* 0–1: shared words (Jaccard), boosted when one name contains the other ("Chipotle" vs "Chipotle Mexican Grill"). */
  function similarity(a, b) {
    const x = normalizeName(a), y = normalizeName(b);
    if (!x || !y) return 0;
    if (x === y) return 1;
    const wa = new Set(x.split(' ')), wb = new Set(y.split(' '));
    let shared = 0;
    for (const w of wa) if (wb.has(w)) shared++;
    const jaccard = shared / (wa.size + wb.size - shared);
    const contains = x.includes(y) || y.includes(x) ? 0.85 : 0;
    return Math.max(jaccard, contains);
  }
  function distanceMiles(a, b) {
    if (!a || !b || !valid(a.lat) || !valid(b.lat)) return null;
    const rad = Math.PI / 180, dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad;
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLon / 2) ** 2;
    return 2 * 3958.8 * Math.asin(Math.min(1, Math.sqrt(h)));
  }

  function emptyDb() { return { v: 1, nextId: 1, restaurants: [], countedOffers: [], countedVisits: [] }; }
  const place = r => (valid(r.lat) && valid(r.lon) ? { lat: r.lat, lon: r.lon } : null);

  /* The restaurant a name (and optional location) belongs to: same normalized name or alias, and — when both have a
   * location — within SAME_PLACE_MILES. Without a location: the only match, else the most visited. */
  function matchRestaurant(db, name, location) {
    const key = normalizeName(name);
    if (!key || !db || !db.restaurants) return null;
    const named = db.restaurants.filter(r => r.keys.includes(key));
    if (!named.length) return null;
    if (location && valid(location.lat)) {
      const near = named.map(r => ({ r, d: distanceMiles(place(r), location) })).filter(x => x.d !== null && x.d <= SAME_PLACE_MILES)
        .sort((a, b) => a.d - b.d);
      if (near.length) return near[0].r.id;
      const unplaced = named.filter(r => !place(r));
      return unplaced.length ? unplaced[0].id : null; // Same name far away: another branch.
    }
    return named.slice().sort((a, b) => (b.visits || 0) - (a.visits || 0) || (b.offers || 0) - (a.offers || 0))[0].id;
  }

  function addRestaurant(db, name, platform, location, at) {
    const r = { id: 'r' + db.nextId++, name: String(name).slice(0, 80), aliases: [String(name).slice(0, 80)], keys: [normalizeName(name)],
      platforms: platform ? [platform] : [], lat: null, lon: null, placeSamples: 0, offers: 0, visits: 0, firstSeen: at || null, lastSeen: at || null };
    db.restaurants.push(r);
    if (location) placeAt(r, location);
    return r;
  }
  function placeAt(r, location) {
    if (!location || !valid(location.lat) || !valid(location.lon)) return;
    const n = r.placeSamples || 0;
    r.lat = n ? (r.lat * n + location.lat) / (n + 1) : location.lat;
    r.lon = n ? (r.lon * n + location.lon) / (n + 1) : location.lon;
    r.placeSamples = n + 1;
  }
  function note(r, name, platform, at) {
    const key = normalizeName(name);
    if (!r.keys.includes(key)) r.keys.push(key);
    if (!r.aliases.includes(name) && r.aliases.length < 12) r.aliases.push(String(name).slice(0, 80));
    if (platform && !r.platforms.includes(platform)) r.platforms.push(platform);
    if (at && (!r.lastSeen || ms(at) > ms(r.lastSeen))) r.lastSeen = at;
    if (at && (!r.firstSeen || ms(at) < ms(r.firstSeen))) r.firstSeen = at;
  }

  /* Adds what's new: every store name on an offer card (counted once per offer) and every store arrival the driver
   * ticked (counted once per step, with the phone's position at arrival — a business location). */
  function updateRestaurants(db, input) {
    const out = JSON.parse(JSON.stringify(db && db.restaurants ? db : emptyDb()));
    const counted = new Set(out.countedOffers), visited = new Set(out.countedVisits);
    const fromTrips = input && input.trips ? storeVisits(input.trips).map(v => ({ id: v.id, name: v.name, platform: v.platform,
      lat: v.lat, lon: v.lon, at: v.arrivedAt })) : [];
    for (const visit of ((input && input.visits) || []).concat(fromTrips)) {
      if (!visit.id || visited.has(visit.id) || !normalizeName(visit.name) || /^store \d+$/i.test(visit.name)) continue;
      const location = valid(visit.lat) ? { lat: visit.lat, lon: visit.lon } : null;
      const id = matchRestaurant(out, visit.name, location);
      const r = id ? out.restaurants.find(x => x.id === id) : addRestaurant(out, visit.name, visit.platform, null, visit.at);
      note(r, visit.name, visit.platform, visit.at);
      placeAt(r, location);
      r.visits = (r.visits || 0) + 1;
      visited.add(visit.id);
    }
    for (const offer of (input && input.offers) || []) {
      if (!offer.id || counted.has(offer.id)) continue;
      const names = offer.merchants && offer.merchants.length ? offer.merchants : offer.merchant ? [offer.merchant] : [];
      for (const name of names) {
        if (!normalizeName(name)) continue;
        const id = matchRestaurant(out, name, null);
        const r = id ? out.restaurants.find(x => x.id === id) : addRestaurant(out, name, offer.platform, null, offer.seenAt);
        note(r, name, offer.platform, offer.seenAt);
        r.offers = (r.offers || 0) + 1;
      }
      counted.add(offer.id);
    }
    out.countedOffers = Array.from(counted).slice(-20000);
    out.countedVisits = Array.from(visited).slice(-20000);
    return out;
  }

  /* Merge `sourceId` into `targetId` (the driver's call: same store under different names). Future names that match any
   * of the merged names land on the target. */
  function mergeRestaurants(db, sourceId, targetId) {
    if (sourceId === targetId) return db;
    const out = JSON.parse(JSON.stringify(db));
    const source = out.restaurants.find(r => r.id === sourceId), target = out.restaurants.find(r => r.id === targetId);
    if (!source || !target) return db;
    for (const key of source.keys) if (!target.keys.includes(key)) target.keys.push(key);
    for (const alias of source.aliases) if (!target.aliases.includes(alias) && target.aliases.length < 12) target.aliases.push(alias);
    for (const p of source.platforms) if (!target.platforms.includes(p)) target.platforms.push(p);
    if (place(source)) {
      const a = target.placeSamples || 0, b = source.placeSamples || 1;
      target.lat = place(target) ? (target.lat * a + source.lat * b) / (a + b) : source.lat;
      target.lon = place(target) ? (target.lon * a + source.lon * b) / (a + b) : source.lon;
      target.placeSamples = a + b;
    }
    target.offers = (target.offers || 0) + (source.offers || 0);
    target.visits = (target.visits || 0) + (source.visits || 0);
    if (source.firstSeen && (!target.firstSeen || ms(source.firstSeen) < ms(target.firstSeen))) target.firstSeen = source.firstSeen;
    if (source.lastSeen && (!target.lastSeen || ms(source.lastSeen) > ms(target.lastSeen))) target.lastSeen = source.lastSeen;
    out.restaurants = out.restaurants.filter(r => r.id !== sourceId);
    return out;
  }

  function renameRestaurant(db, id, name) {
    const clean = String(name || '').trim().slice(0, 80);
    if (!clean) return db;
    const out = JSON.parse(JSON.stringify(db));
    const r = out.restaurants.find(x => x.id === id);
    if (!r) return db;
    r.name = clean;
    note(r, clean, null, null);
    return out;
  }

  /* Likely duplicates of one restaurant, best first: similar name, and close by when both have a location. */
  function mergeSuggestions(db, id) {
    if (!db || !db.restaurants) return [];
    const r = db.restaurants.find(x => x.id === id);
    if (!r) return [];
    return db.restaurants.filter(x => x.id !== id).map(x => {
      const nameScore = Math.max(...r.aliases.flatMap(a => x.aliases.map(b => similarity(a, b))));
      const d = distanceMiles(place(r), place(x));
      const score = d === null ? nameScore * 0.8 : d <= SAME_PLACE_MILES ? Math.min(1, nameScore + 0.25) : nameScore * 0.3;
      return { id: x.id, name: x.name, score: Math.round(score * 100) / 100, miles: d === null ? null : Math.round(d * 10) / 10 };
    }).filter(x => x.score >= 0.3).sort((a, b) => b.score - a.score).slice(0, 8);
  }

  // MARK: Waits from the driver's ticked trips

  // Meal periods by local time: lunch 10:30–14:00, dinner 16:30–21:00, else other.
  /* Time-of-day periods (user, Oct 15). The user's ranges had 30-minute gaps; each period runs until the next starts:
   * Breakfast 6:00–11:00, Lunch 11:00–15:30, Dinner 15:30–22:30, Late night 22:30–1:30, Early morning 1:30–6:00. */
  const DAY_PARTS = [
    { key: 'early_morning', label: 'Early morning', start: 90 },
    { key: 'breakfast', label: 'Breakfast', start: 360 },
    { key: 'lunch', label: 'Lunch', start: 660 },
    { key: 'dinner', label: 'Dinner', start: 930 },
    { key: 'late_night', label: 'Late night', start: 1350 }
  ];
  const DAY_PART_ORDER = ['breakfast', 'lunch', 'dinner', 'late_night', 'early_morning'];
  function dayPart(minuteOfDay) {
    let part = DAY_PARTS[DAY_PARTS.length - 1]; // Before 1:30 AM is still late night.
    for (const p of DAY_PARTS) if (minuteOfDay >= p.start) part = p;
    return { key: part.key, label: part.label };
  }
  function mealPeriod(minuteOfDay) { return dayPart(minuteOfDay).key; }
  /* The period a span of time mostly falls in (sampled every 15 minutes, local time), e.g. a 5–9 PM shift → Dinner. */
  function dominantPart(from, to, offsetMinutes) {
    const a = ms(from), b = ms(to);
    if (!valid(a) || !valid(b) || b <= a) return null;
    const counts = {};
    for (let t = a; t < b; t += 15 * 60000) {
      const local = new Date(t + (offsetMinutes || 0) * 60000);
      const key = dayPart(local.getUTCHours() * 60 + local.getUTCMinutes()).key;
      counts[key] = (counts[key] || 0) + 1;
    }
    const key = Object.keys(counts).sort((x, y) => counts[y] - counts[x])[0];
    return DAY_PARTS.filter(p => p.key === key).map(p => ({ key: p.key, label: p.label }))[0];
  }
  function localMinute(at, offsetMinutes) {
    const t = ms(at);
    if (!valid(t)) return null;
    const local = new Date(t + (offsetMinutes || 0) * 60000);
    return { weekday: local.getUTCDay(), minuteOfDay: local.getUTCHours() * 60 + local.getUTCMinutes() };
  }

  /* Every store visit in the trips: arrival → left, or a lower bound when the order ended first (unassigned/cancelled). */
  function storeVisits(trips) {
    const visits = [];
    for (const trip of trips || []) {
      for (const order of trip.orders || []) {
        (order.stores || []).forEach((store, stop) => {
          const arrived = (trip.steps || []).find(s => s.kind === 'arrivedStore' && s.offerId === order.offerId && s.stop === stop);
          if (!arrived) return;
          const left = (trip.steps || []).find(s => s.kind === 'leftStore' && s.offerId === order.offerId && s.stop === stop);
          const end = left ? left.at : order.endedAt && order.ended !== 'completed' ? order.endedAt : null;
          const seconds = end ? Math.round((ms(end) - ms(arrived.at)) / 1000) : null;
          visits.push({ id: arrived.id, tripId: trip.id, offerId: order.offerId, platform: order.platform, name: store, stop,
            arrivedAt: arrived.at, leftAt: left ? left.at : null, seconds: seconds !== null && seconds >= 0 ? seconds : null,
            censored: !left && seconds !== null, lat: valid(arrived.latitude) ? arrived.latitude : null,
            lon: valid(arrived.longitude) ? arrived.longitude : null });
        });
      }
    }
    return visits;
  }

  /* Per restaurant: visits, waits (finished ones and "at least" ones), average, longest, and by meal period. */
  function restaurantStats(db, trips, offsetMinutes) {
    const stats = {};
    if (!db || !db.restaurants) return stats;
    for (const v of storeVisits(trips)) {
      const id = matchRestaurant(db, v.name, valid(v.lat) ? { lat: v.lat, lon: v.lon } : null);
      if (!id) continue;
      const s = stats[id] = stats[id] || { visits: 0, waits: 0, totalSeconds: 0, longestSeconds: 0, atLeast: [], byPeriod: {} };
      s.visits++;
      if (v.seconds === null) continue;
      if (v.censored) { s.atLeast.push(v.seconds); continue; }
      s.waits++; s.totalSeconds += v.seconds; s.longestSeconds = Math.max(s.longestSeconds, v.seconds);
      const local = localMinute(v.arrivedAt, offsetMinutes);
      const period = local ? mealPeriod(local.minuteOfDay) : 'other';
      const p = s.byPeriod[period] = s.byPeriod[period] || { waits: 0, totalSeconds: 0 };
      p.waits++; p.totalSeconds += v.seconds;
    }
    for (const s of Object.values(stats)) {
      s.averageMinutes = s.waits ? Math.round(s.totalSeconds / s.waits / 6) / 10 : null;
      for (const p of Object.values(s.byPeriod)) p.averageMinutes = Math.round(p.totalSeconds / p.waits / 6) / 10;
    }
    return stats;
  }

  // MARK: Shift totals

  function clip(from, to, start, end) {
    const a = Math.max(from, start), b = Math.min(to, end);
    return b > a ? [a, b] : null;
  }
  function unionSeconds(intervals) {
    const sorted = intervals.filter(Boolean).sort((x, y) => x[0] - y[0]);
    let total = 0, current = null;
    for (const [a, b] of sorted) {
      if (!current || a > current[1]) { if (current) total += current[1] - current[0]; current = [a, b]; }
      else current[1] = Math.max(current[1], b);
    }
    if (current) total += current[1] - current[0];
    return total / 1000;
  }

  /* shift: { startedAt, endedAt|null, meters: { toPickup, delivery, driveBack, reposition }, goalCents|null }.
   * Earnings are the offered pay of completed orders (what the cards showed; tips can change it). */
  function shiftMetrics(shift, trips, now, offsetMinutes) {
    const start = ms(shift.startedAt), end = shift.endedAt ? ms(shift.endedAt) : ms(now);
    const orders = [], intervals = [];
    for (const trip of trips || []) {
      const tripEnd = trip.endedAt ? ms(trip.endedAt) : end;
      const inShift = (trip.orders || []).filter(o => ms(o.acceptedAt) >= start - 60000 && ms(o.acceptedAt) <= end);
      if (!inShift.length) continue;
      orders.push(...inShift.map(o => Object.assign({ tripId: trip.id }, o)));
      intervals.push(clip(ms(trip.startedAt), tripEnd, start, end));
    }
    const completed = orders.filter(o => o.ended === 'completed');
    const earningsCents = completed.reduce((sum, o) => sum + (o.payCents || 0), 0);
    const byPlatform = {};
    for (const o of completed) {
      const p = byPlatform[o.platform] = byPlatform[o.platform] || { earningsCents: 0, completed: 0 };
      p.earningsCents += o.payCents || 0; p.completed++;
    }
    const shiftSeconds = Math.max(0, (end - start) / 1000);
    const activeSeconds = Math.min(shiftSeconds, unionSeconds(intervals));
    /* The shift clock (user, Oct 15): each completed order is timed on it. clockSeconds = shift time when it was
     * delivered; sinceLastSeconds = since the previous delivery (or the shift start), idle time included, so its
     * hourly is what that order really paid for the shift time it took; hourlyCents = all earnings so far ÷ the clock. */
    let lastAt = start, runningCents = 0;
    const completions = completed.filter(o => o.endedAt).sort((a, b) => ms(a.endedAt) - ms(b.endedAt)).map(o => {
      const at = Math.min(Math.max(ms(o.endedAt), start), end);
      const sinceLast = Math.max(0, (at - lastAt) / 1000);
      lastAt = at; runningCents += o.payCents || 0;
      return { offerId: o.offerId, platform: o.platform, merchant: o.merchant || null, payCents: o.payCents || 0, endedAt: o.endedAt,
        clockSeconds: Math.round((at - start) / 1000), sinceLastSeconds: Math.round(sinceLast),
        orderHourlyCents: sinceLast >= 60 ? Math.round((o.payCents || 0) * 3600 / sinceLast) : null,
        earningsCents: runningCents, hourlyCents: at - start >= 300000 ? Math.round(runningCents * 3600000 / (at - start)) : null };
    });
    const m = shift.meters || {};
    const miles = k => (valid(m[k]) ? m[k] / METERS_PER_MILE : 0);
    const round1 = v => Math.round(v * 10) / 10;
    const mileage = { toPickup: miles('toPickup'), delivery: miles('delivery'), driveBack: miles('driveBack'), reposition: miles('reposition') };
    mileage.order = mileage.toPickup + mileage.delivery;
    mileage.deadhead = mileage.driveBack + mileage.reposition;
    mileage.total = mileage.order + mileage.deadhead;
    for (const k of Object.keys(mileage)) mileage[k] = round1(mileage[k]);
    const perHour = seconds => (seconds >= 300 ? Math.round(earningsCents * 3600 / seconds) : null);
    const waits = storeVisits(trips).filter(v => ms(v.arrivedAt) >= start && ms(v.arrivedAt) <= end);
    const finished = waits.filter(v => v.seconds !== null && !v.censored);
    const metrics = {
      startedAt: shift.startedAt, endedAt: shift.endedAt || null, live: !shift.endedAt,
      earningsCents, byPlatform,
      completed: completed.length,
      unassigned: orders.filter(o => o.ended === 'unassigned').length,
      cancelled: orders.filter(o => typeof o.ended === 'string' && o.ended.indexOf('cancelled') === 0).length,
      inProgress: orders.filter(o => !o.ended).length,
      shiftSeconds: Math.round(shiftSeconds), activeSeconds: Math.round(activeSeconds), idleSeconds: Math.round(shiftSeconds - activeSeconds),
      miles: mileage,
      perOnlineHourCents: perHour(shiftSeconds), perActiveHourCents: perHour(activeSeconds),
      completions,
      // During a shift the hourly moves only when an order is delivered: earnings ÷ the shift clock at that delivery.
      clockHourlyCents: completions.length ? completions[completions.length - 1].hourlyCents : null,
      perMileCents: mileage.total >= 1 ? Math.round(earningsCents / mileage.total) : null,
      restaurantWait: { visits: waits.length, finished: finished.length,
        averageMinutes: finished.length ? round1(finished.reduce((s, v) => s + v.seconds, 0) / finished.length / 60) : null,
        longestMinutes: finished.length ? round1(Math.max(...finished.map(v => v.seconds)) / 60) : null,
        atLeastCount: waits.filter(v => v.censored).length },
      goal: null
    };
    if (valid(shift.goalCents) && shift.goalCents > 0) {
      const remaining = Math.max(0, shift.goalCents - earningsCents);
      const rate = metrics.perOnlineHourCents;
      metrics.goal = { goalCents: shift.goalCents, progress: Math.min(1, earningsCents / shift.goalCents), remainingCents: remaining,
        reached: remaining === 0,
        // At the pace so far (per online hour, which includes waiting between offers).
        etaAt: remaining > 0 && rate && rate > 0 && metrics.live ? new Date(end + remaining / rate * 3600000).toISOString() : null };
    }
    metrics.period = dominantPart(shift.startedAt, shift.endedAt || now, offsetMinutes);
    return metrics;
  }

  // MARK: Weeks and days (user, Oct 15: week → day → shift → order)

  const KINDS = ['toPickup', 'delivery', 'driveBack', 'reposition'];
  function overlapMs(a0, a1, b0, b1) { return Math.max(0, Math.min(a1, b1) - Math.max(a0, b0)); }
  function ordersOf(trips) {
    const list = [];
    for (const trip of trips || []) {
      (trip.orders || []).forEach((o, index) => list.push(Object.assign({ tripId: trip.id, stacked: index > 0 }, o)));
    }
    return list;
  }
  function orderSeconds(o) {
    return o.ended && o.endedAt ? Math.max(0, (ms(o.endedAt) - ms(o.acceptedAt)) / 1000) : null;
  }
  const perHourOf = (cents, seconds) => (seconds >= 300 ? Math.round(cents * 3600 / seconds) : null);

  /* Shift miles inside [a, b): from the hourly buckets ({ "<hour start, epoch seconds>": { kind: meters } }) when the
   * shift has them; older shifts (totals only) count all their miles on the day they started. */
  function milesIn(shifts, a, b) {
    const meters = { toPickup: 0, delivery: 0, driveBack: 0, reposition: 0 };
    for (const s of shifts) {
      if (s.buckets && Object.keys(s.buckets).length) {
        for (const key of Object.keys(s.buckets)) {
          const t = Number(key) * 1000;
          if (t >= a && t < b) for (const k of KINDS) meters[k] += valid(s.buckets[key][k]) ? s.buckets[key][k] : 0;
        }
      } else if (ms(s.startedAt) >= a && ms(s.startedAt) < b) {
        for (const k of KINDS) meters[k] += valid((s.meters || {})[k]) ? s.meters[k] : 0;
      }
    }
    const miles = {};
    for (const k of KINDS) miles[k] = meters[k] / METERS_PER_MILE;
    miles.order = miles.toPickup + miles.delivery;
    miles.deadhead = miles.driveBack + miles.reposition;
    miles.total = miles.order + miles.deadhead;
    for (const k of Object.keys(miles)) miles[k] = Math.round(miles[k] * 10) / 10;
    return miles;
  }

  /* Totals for any time range [from, to): online time = shift time inside the range; active = trips inside it;
   * orders, earnings, and waits by when the order was accepted / the store reached. */
  function rangeMetrics(input, from, to) {
    const a = ms(from), b = ms(to), now = ms(input.now);
    const end = s => (s.endedAt ? ms(s.endedAt) : now);
    const shifts = (input.shifts || []).filter(s => ms(s.startedAt) < b && end(s) > a);
    const shiftSeconds = shifts.reduce((t, s) => t + overlapMs(ms(s.startedAt), end(s), a, b), 0) / 1000;
    const activeSeconds = unionSeconds((input.trips || []).map(t => clip(ms(t.startedAt), t.endedAt ? ms(t.endedAt) : now, a, b)));
    const onlineSeconds = Math.max(shiftSeconds, activeSeconds); // A trip ticked outside a shift still counts as online.
    const orders = ordersOf(input.trips).filter(o => ms(o.acceptedAt) >= a && ms(o.acceptedAt) < b);
    const completed = orders.filter(o => o.ended === 'completed');
    /* Added by hand (user, Oct 15, Gridwise-style ＋): "extra" = tips, bonuses, and other earnings (counted in
     * earnings and its app's share); "expense" = costs, giving net earnings. */
    const entries = (input.entries || []).filter(e => ms(e.at) >= a && ms(e.at) < b && valid(e.amountCents) && (e.amountCents > 0 || e.kind === 'mileage'))
      .sort((x, y) => ms(x.at) - ms(y.at));
    const extras = entries.filter(e => e.kind === 'extra'), expenses = entries.filter(e => e.kind === 'expense');
    /* Daily totals imported from Gridwise (kind 'imported'): earnings and app share, but no time or miles behind them, so
     * never in $/hr or $/mi. A day and app __APP_NAME__ tracked orders for itself uses those orders instead (no double count). */
    const offset = input.offsetMinutes || 0;
    const dayOf = at => new Date(ms(at) + offset * 60000).toISOString().slice(0, 10);
    const trackedDays = new Set(orders.filter(o => o.ended === 'completed').map(o => dayOf(o.acceptedAt) + '|' + o.platform));
    const importedAll = entries.filter(e => e.kind === 'imported');
    const imported = importedAll.filter(e => !trackedDays.has(dayOf(e.at) + '|' + e.platform));
    const importedCents = imported.reduce((t, e) => t + e.amountCents, 0);
    const extrasCents = extras.reduce((t, e) => t + e.amountCents, 0);
    const expensesCents = expenses.reduce((t, e) => t + e.amountCents, 0);
    const trackedCents = completed.reduce((t, o) => t + (o.payCents || 0), 0) + extrasCents;
    const earningsCents = trackedCents + importedCents;
    const byPlatform = {};
    for (const o of completed) {
      const p = byPlatform[o.platform] = byPlatform[o.platform] || { earningsCents: 0, completed: 0 };
      p.earningsCents += o.payCents || 0; p.completed++;
    }
    for (const e of extras.concat(imported)) {
      if (!e.platform) continue;
      const p = byPlatform[e.platform] = byPlatform[e.platform] || { earningsCents: 0, completed: 0 };
      p.earningsCents += e.amountCents;
    }
    /* Gridwise's daily hours and miles (kind 'mileage'): hours join online time, miles join total miles (the deduction uses
     * Gridwise's own amounts), and imported earnings on those days join $/hr and $/mi — there is time and distance behind
     * them now. A day __APP_NAME__ tracked itself (a shift or an order that day) uses its own numbers instead. */
    const ownDays = new Set(orders.map(o => dayOf(o.acceptedAt)));
    for (const s of shifts) for (let t = ms(s.startedAt); t <= end(s); t += 12 * 3600000) ownDays.add(dayOf(new Date(t).toISOString()));
    const mileage = entries.filter(e => e.kind === 'mileage' && !ownDays.has(dayOf(e.at)));
    const importedSeconds = mileage.reduce((t, e) => t + (e.seconds || 0), 0);
    const importedMilli = mileage.reduce((t, e) => t + (e.milliMiles || 0), 0);
    const importedDeductionCents = mileage.reduce((t, e) => t + (e.amountCents || 0), 0);
    const mileageDays = new Set(mileage.map(e => dayOf(e.at)));
    const pacedCents = trackedCents + imported.filter(e => mileageDays.has(dayOf(e.at))).reduce((t, e) => t + e.amountCents, 0);
    const miles = milesIn(shifts, a, b);
    miles.imported = Math.round(importedMilli / 100) / 10;
    miles.total = Math.round((miles.total + importedMilli / 1000) * 10) / 10;
    const online = onlineSeconds + importedSeconds;
    const visits = storeVisits(input.trips).filter(v => ms(v.arrivedAt) >= a && ms(v.arrivedAt) < b);
    const finished = visits.filter(v => v.seconds !== null && !v.censored);
    return {
      from, to, earningsCents, byPlatform, extrasCents, importedCents, importedDays: new Set(imported.map(e => dayOf(e.at))).size,
      expensesCents, netCents: earningsCents - expensesCents,
      importedSeconds, importedMiles: miles.imported, importedDeductionCents,
      entries: entries.filter(e => e.kind !== 'mileage' && (e.kind !== 'imported' || imported.includes(e))).map(e => ({ id: e.id, kind: e.kind, at: e.at, amountCents: e.amountCents, category: e.category || null,
        platform: e.platform || null, note: e.note || null })),
      completed: completed.length,
      unassigned: orders.filter(o => o.ended === 'unassigned').length,
      cancelled: orders.filter(o => typeof o.ended === 'string' && o.ended.indexOf('cancelled') === 0).length,
      onlineSeconds: Math.round(online), activeSeconds: Math.round(activeSeconds),
      idleSeconds: Math.round(Math.max(0, onlineSeconds - activeSeconds)), // Imported hours have no idle/active split.
      miles,
      perOnlineHourCents: perHourOf(pacedCents, online), perActiveHourCents: perHourOf(trackedCents, activeSeconds),
      perMileCents: miles.total >= 1 ? Math.round(pacedCents / miles.total) : null,
      restaurantWait: { visits: visits.length, finished: finished.length, atLeastCount: visits.filter(v => v.censored).length,
        averageMinutes: finished.length ? Math.round(finished.reduce((t, v) => t + v.seconds, 0) / finished.length / 6) / 10 : null },
      shiftIds: shifts.map(s => s.id)
    };
  }

  /* One lens on a range's completed orders: grouped by platform, area, restaurant, or hour, each with earnings, orders,
   * and the pace those orders earned (pay ÷ their accepted→completed time). */
  function lens(input, from, to, keyOf, labelOf) {
    const a = ms(from), b = ms(to);
    const groups = {};
    for (const o of ordersOf(input.trips)) {
      if (o.ended !== 'completed' || ms(o.acceptedAt) < a || ms(o.acceptedAt) >= b) continue;
      const key = String(keyOf(o));
      const g = groups[key] = groups[key] || { key, label: labelOf ? labelOf(key, o) : key, earningsCents: 0, orders: 0, seconds: 0 };
      g.earningsCents += o.payCents || 0; g.orders++; g.seconds += orderSeconds(o) || 0;
    }
    return Object.values(groups).map(g => ({ key: g.key, label: g.label, earningsCents: g.earningsCents, orders: g.orders,
      perHourCents: perHourOf(g.earningsCents, g.seconds) })).sort((x, y) => y.earningsCents - x.earningsCents);
  }
  function hourLabel(hour) {
    const h = hour % 12 === 0 ? 12 : hour % 12;
    return h + (hour < 12 ? ' AM' : ' PM');
  }
  function lenses(input, from, to) {
    const off = input.offsetMinutes || 0;
    const areaOf = {};
    for (const x of input.offers || []) areaOf[x.offerId || x.id] = x.dropoffArea || null;
    const db = input.restaurants;
    const restaurantName = o => {
      const name = (o.stores && o.stores[0]) || o.merchant || 'Unknown';
      const id = matchRestaurant(db, name, null);
      const r = id && db.restaurants.find(x => x.id === id);
      return r ? r.name : name;
    };
    const restaurant = lens(input, from, to, restaurantName);
    // Waits for the same restaurants in the same range.
    const a = ms(from), b = ms(to), waits = {};
    for (const v of storeVisits(input.trips)) {
      if (v.seconds === null || v.censored || ms(v.arrivedAt) < a || ms(v.arrivedAt) >= b) continue;
      const id = matchRestaurant(db, v.name, valid(v.lat) ? { lat: v.lat, lon: v.lon } : null);
      const r = id && db.restaurants.find(x => x.id === id);
      const name = r ? r.name : v.name;
      const w = waits[name] = waits[name] || { total: 0, n: 0 };
      w.total += v.seconds; w.n++;
    }
    for (const row of restaurant) {
      const w = waits[row.key];
      row.waitMinutes = w ? Math.round(w.total / w.n / 6) / 10 : null;
    }
    return {
      platform: lens(input, from, to, o => o.platform),
      area: lens(input, from, to, o => areaOf[o.offerId] || 'Not shown on the card'),
      restaurant,
      period: lens(input, from, to, o => {
        const local = new Date(ms(o.acceptedAt) + off * 60000);
        return dayPart(local.getUTCHours() * 60 + local.getUTCMinutes()).key;
      }, key => DAY_PARTS.find(p => p.key === key).label).sort((x, y) => DAY_PART_ORDER.indexOf(x.key) - DAY_PART_ORDER.indexOf(y.key)),
      hour: lens(input, from, to, o => new Date(ms(o.acceptedAt) + off * 60000).getUTCHours(), h => hourLabel(Number(h)))
        .sort((x, y) => Number(x.key) - Number(y.key))
    };
  }

  function change(current, previous) {
    return valid(current) && valid(previous) && previous > 0 ? Math.round((current - previous) / previous * 100) : null;
  }

  /* The Stats tab's week: input = { shifts (with buckets), trips, offers (offerId, dropoffArea), restaurants (db),
   * days: 7 × { start, end } (local midnights from the phone's calendar), previous: { start, end } | null, now,
   * offsetMinutes }. Every number traces to shifts and orders: each day lists its shifts and orders. */
  function weekStats(input) {
    const days = input.days || [];
    const weekFrom = days[0].start, weekTo = days[days.length - 1].end;
    const week = rangeMetrics(input, weekFrom, weekTo);
    const previous = input.previous ? rangeMetrics(input, input.previous.start, input.previous.end) : null;
    const shiftsById = {};
    for (const s of input.shifts || []) shiftsById[s.id] = s;
    const dayStats = days.map(d => {
      const m = rangeMetrics(input, d.start, d.end);
      const a = ms(d.start), b = ms(d.end);
      m.orders = ordersOf(input.trips).filter(o => ms(o.acceptedAt) >= a && ms(o.acceptedAt) < b)
        .sort((x, y) => ms(x.acceptedAt) - ms(y.acceptedAt))
        .map(o => {
          const seconds = orderSeconds(o);
          return { offerId: o.offerId, tripId: o.tripId, platform: o.platform, stores: o.stores || [], payCents: o.payCents,
            acceptedAt: o.acceptedAt, endedAt: o.endedAt || null, ended: o.ended || null, stacked: o.stacked,
            minutes: seconds === null ? null : Math.round(seconds / 6) / 10,
            perHourCents: o.ended === 'completed' && seconds >= 60 ? Math.round(o.payCents * 3600 / seconds) : null };
        });
      m.shifts = m.shiftIds.map(id => ({ id, startedAt: shiftsById[id].startedAt, endedAt: shiftsById[id].endedAt || null,
        period: dominantPart(shiftsById[id].startedAt, shiftsById[id].endedAt || input.now, input.offsetMinutes) }));
      m.platforms = lens(input, d.start, d.end, o => o.platform);
      return m;
    });
    const comparison = previous && (previous.onlineSeconds > 0 || previous.earningsCents > 0) ? {
      earnings: change(week.earningsCents, previous.earningsCents),
      perOnlineHour: change(week.perOnlineHourCents, previous.perOnlineHourCents),
      perMile: change(week.perMileCents, previous.perMileCents),
      deadhead: change(week.miles.deadhead, previous.miles.deadhead),
      idle: change(week.idleSeconds, previous.idleSeconds),
      storeWait: change(week.restaurantWait.averageMinutes, previous.restaurantWait.averageMinutes)
    } : null;
    return { week, days: dayStats, previous, comparison, lenses: lenses(input, weekFrom, weekTo) };
  }

  // MARK: Export

  function csvCell(v) {
    if (v === null || v === undefined) return '';
    const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
    return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }
  function toCSV(columns, rows) {
    return [columns.join(',')].concat(rows.map(r => columns.map(c => csvCell(r[c])).join(','))).join('\n') + '\n';
  }
  function localTime(at, offsetMinutes) {
    const t = ms(at);
    if (!valid(t)) return null;
    return new Date(t + (offsetMinutes || 0) * 60000).toISOString().slice(0, 19).replace('T', ' ');
  }
  const dollars = c => (valid(c) ? (c / 100).toFixed(2) : null);
  const miles1 = mm => (valid(mm) ? (mm / 1000).toFixed(1) : null);

  /* The driver's history as CSV tables (local times). data: { offers, trips, shifts (with metrics), restaurants (db),
   * offsetMinutes }. Prediction columns sit next to what actually happened. */
  function exportTables(data) {
    const off = data.offsetMinutes || 0, t = at => localTime(at, off);
    const ordersById = {};
    for (const trip of data.trips || []) for (const o of trip.orders || []) ordersById[o.offerId] = Object.assign({ trip }, o);
    const minutesOf = o => (o.endedAt ? Math.round((ms(o.endedAt) - ms(o.acceptedAt)) / 6000) / 10 : null);
    const paceOf = o => {
      const s = o.endedAt ? (ms(o.endedAt) - ms(o.acceptedAt)) / 1000 : 0;
      return o.ended === 'completed' && s >= 60 ? dollars(Math.round(o.payCents * 3600 / s)) : null;
    };
    const offers = (data.offers || []).map(x => {
      const o = ordersById[x.offerId || x.id];
      return { seen_at: t(x.seenAt), offer_id: x.offerId || x.id, app: x.platform, pay: dollars(x.payCents), app_miles: miles1(x.outboundMilliMiles),
        app_minutes: x.appMinutes, stores: (x.merchants && x.merchants.join(' + ')) || x.merchant, dropoffs: x.dropoffCount || x.orderCount,
        drop_off_town: x.dropoffArea, return_miles: miles1(x.returnMilliMiles), return_kind: x.returnKind,
        first_notification: x.preliminaryNotice, verdict: x.notice, reader_confidence: x.confidence,
        accepted: o ? 'yes' : 'no', outcome: o ? o.ended || 'in progress' : null,
        actual_minutes: o ? minutesOf(o) : null, actual_per_hour: o ? paceOf(o) : null };
    });
    const orders = Object.values(ordersById).map(o => ({ offer_id: o.offerId, trip_id: o.trip.id, app: o.platform, stores: (o.stores || []).join(' + '),
      dropoffs: o.dropoffs, pay: dollars(o.payCents), accepted_at: t(o.acceptedAt), ended_at: t(o.endedAt), outcome: o.ended || 'in progress',
      minutes: minutesOf(o), per_hour: paceOf(o), stacked: (o.trip.orders || []).indexOf((o.trip.orders || []).find(x => x.offerId === o.offerId)) > 0 ? 'yes' : 'no' }));
    const stops = [];
    for (const trip of data.trips || []) {
      for (const s of trip.steps || []) {
        stops.push({ trip_id: trip.id, offer_id: s.offerId, step: s.kind, stop: s.stop + 1, label: s.label, at: t(s.at) });
      }
    }
    const waits = storeVisits(data.trips).map(v => ({ store: v.name, app: v.platform, arrived_at: t(v.arrivedAt), left_at: t(v.leftAt),
      wait_minutes: v.seconds === null ? null : Math.round(v.seconds / 6) / 10, at_least: v.censored ? 'yes' : 'no', offer_id: v.offerId }));
    const shifts = (data.shifts || []).map(s => {
      const m = s.metrics || {};
      return { started_at: t(s.startedAt), ended_at: t(s.endedAt), earnings: dollars(m.earningsCents),
        doordash: dollars(((m.byPlatform || {}).doordash || {}).earningsCents), uber_eats: dollars(((m.byPlatform || {}).uber_eats || {}).earningsCents),
        grubhub: dollars(((m.byPlatform || {}).grubhub || {}).earningsCents),
        online_hours: valid(m.shiftSeconds) ? (m.shiftSeconds / 3600).toFixed(2) : null,
        active_hours: valid(m.activeSeconds) ? (m.activeSeconds / 3600).toFixed(2) : null,
        idle_hours: valid(m.idleSeconds) ? (m.idleSeconds / 3600).toFixed(2) : null,
        total_miles: m.miles && m.miles.total, order_miles: m.miles && m.miles.order, to_pickup_miles: m.miles && m.miles.toPickup,
        delivery_miles: m.miles && m.miles.delivery, deadhead_miles: m.miles && m.miles.deadhead,
        drive_back_miles: m.miles && m.miles.driveBack, reposition_miles: m.miles && m.miles.reposition,
        per_online_hour: dollars(m.perOnlineHourCents), per_active_hour: dollars(m.perActiveHourCents), per_mile: dollars(m.perMileCents),
        completed: m.completed, unassigned: m.unassigned, cancelled: m.cancelled,
        avg_restaurant_wait_minutes: m.restaurantWait && m.restaurantWait.averageMinutes, goal: dollars(s.goalCents) };
    });
    const restaurants = ((data.restaurants && data.restaurants.restaurants) || []).map(r => ({ id: r.id, name: r.name,
      other_names: r.aliases.filter(a => a !== r.name).join(' | '), apps: r.platforms.join(' '), offers: r.offers, visits: r.visits,
      latitude: valid(r.lat) ? r.lat.toFixed(4) : null, longitude: valid(r.lon) ? r.lon.toFixed(4) : null }));
    return {
      'offers.csv': toCSV(['seen_at', 'offer_id', 'app', 'pay', 'app_miles', 'app_minutes', 'stores', 'dropoffs', 'drop_off_town', 'return_miles',
        'return_kind', 'first_notification', 'verdict', 'reader_confidence', 'accepted', 'outcome', 'actual_minutes', 'actual_per_hour'], offers),
      'orders.csv': toCSV(['offer_id', 'trip_id', 'app', 'stores', 'dropoffs', 'pay', 'accepted_at', 'ended_at', 'outcome', 'minutes', 'per_hour', 'stacked'], orders),
      'trip-steps.csv': toCSV(['trip_id', 'offer_id', 'step', 'stop', 'label', 'at'], stops),
      'restaurant-waits.csv': toCSV(['store', 'app', 'arrived_at', 'left_at', 'wait_minutes', 'at_least', 'offer_id'], waits),
      'shifts.csv': toCSV(['started_at', 'ended_at', 'earnings', 'doordash', 'uber_eats', 'grubhub', 'online_hours', 'active_hours', 'idle_hours',
        'total_miles', 'order_miles', 'to_pickup_miles', 'delivery_miles', 'deadhead_miles', 'drive_back_miles', 'reposition_miles',
        'per_online_hour', 'per_active_hour', 'per_mile', 'completed', 'unassigned', 'cancelled', 'avg_restaurant_wait_minutes', 'goal'], shifts),
      'restaurants.csv': toCSV(['id', 'name', 'other_names', 'apps', 'offers', 'visits', 'latitude', 'longitude'], restaurants),
      'expenses-and-other-earnings.csv': toCSV(['date', 'kind', 'category', 'app', 'amount', 'note'],
        (data.entries || []).map(e => ({ date: t(e.at), kind: e.kind === 'expense' ? 'expense' : e.kind === 'imported' ? 'imported daily earnings' : e.kind === 'mileage' ? 'imported mileage (amount = deduction)' : 'tip/bonus/other', category: e.category,
          app: e.platform, amount: dollars(e.amountCents), note: e.note })))
    };
  }

  // MARK: Zones (where to wait)

  /* How much an offer says "worth driving for" (user's rules: $1/mi incl. the return, $25/hr): the verdict on its
   * notification, else its tone; the predicted $/hr when known. Older offers count less (half after 30 days). */
  function offerWorth(o, now, targetHourlyCents) {
    const notice = String(o.notice || '');
    let q = 0.5;
    if (/·\s*Accept\b/i.test(notice)) q = 1;
    else if (/·\s*Decline\b/i.test(notice)) q = 0.25;
    else if (/^Accept if\b/i.test(notice)) q = 0.6;
    else if (o.tone === 'good') q = 1;
    else if (o.tone === 'tight') q = 0.6;
    else if (o.tone === 'bad') q = 0.25;
    if (valid(o.hourlyCents) && targetHourlyCents) q = o.hourlyCents >= targetHourlyCents ? Math.max(q, 1) : Math.min(q, 0.5);
    const age = (now - ms(o.seenAt)) / 86400000;
    return { q, recency: Math.pow(0.5, Math.max(0, valid(age) ? age : 0) / 30), good: q >= 0.9 };
  }

  /* Friday from 3:30 PM through Sunday counts as the weekend (Friday dinner behaves like a weekend). */
  function partMatches(at, offsetMinutes, part, days) {
    const local = localMinute(at, offsetMinutes);
    if (!local) return false;
    const weekend = local.weekday === 0 || local.weekday === 6 || (local.weekday === 5 && local.minuteOfDay >= 930);
    if (days === 'weekday' && weekend) return false;
    if (days === 'weekend' && !weekend) return false;
    return !part || part === 'all' || dayPart(local.minuteOfDay).key === part;
  }

  /* Where to wait (user, Oct 19: "a heat map that shows the best zones to wait in… it'll improve over time").
   * Every offer read is evidence of demand at its restaurant(s), weighted by how good it was and how recent; offers also
   * mark where the phone was when they arrived (waitLat/waitLon), the most direct evidence of a good place to wait. Each
   * spreads over the area apps dispatch from (≈1 mi around a restaurant, ≈0.6 mi around a waiting spot). Filtered to a
   * time-of-day period and weekdays/weekends. Restaurant positions: your arrivals, else an Apple Maps search (`places`).
   * input: { restaurants (db), offers, places: {id: {lat, lon}}, shifts: [{startedAt, endedAt}], part, days,
   *          now, offsetMinutes, targetHourlyCents } */
  function zoneHeat(input) {
    const db = input.restaurants && input.restaurants.restaurants ? input.restaurants : emptyDb();
    const now = valid(ms(input.now)) ? ms(input.now) : Date.now();
    const offset = input.offsetMinutes || 0, part = input.part || 'all', days = input.days || 'all';
    const places = input.places || {};
    // "Now" (user, Oct 23: "at 3:00pm on Friday it shows me the usual hot zones for 3pm on Friday"): this weekday within
    // an hour of the time now; with under 15 such offers, the same time (±90 min) on all weekdays or all weekend days.
    let matches = at => partMatches(at, offset, part, days), scope = null;
    if (part === 'now') {
      const here = localMinute(new Date(now).toISOString(), offset);
      const weekendDay = l => l.weekday === 0 || l.weekday === 6 || (l.weekday === 5 && l.minuteOfDay >= 930);
      const near = (l, span) => { const d = Math.abs(l.minuteOfDay - here.minuteOfDay); return Math.min(d, 1440 - d) <= span; };
      const narrow = at => { const l = localMinute(at, offset); return !!l && l.weekday === here.weekday && near(l, 60); };
      const wide = at => { const l = localMinute(at, offset); return !!l && weekendDay(l) === weekendDay(here) && near(l, 90); };
      const enough = (input.offers || []).filter(o => narrow(o.seenAt)).length >= 15;
      matches = enough ? narrow : wide;
      scope = enough ? 'day' : weekendDay(here) ? 'weekend' : 'weekdays';
    }
    const byId = {};
    for (const r of db.restaurants) byId[r.id] = r;
    const located = id => {
      const r = byId[id];
      if (!r) return null;
      if (place(r)) return { lat: r.lat, lon: r.lon, source: 'visits' };
      const p = places[id];
      return p && valid(p.lat) && valid(p.lon) ? { lat: p.lat, lon: p.lon, source: 'search' } : null;
    };
    const points = [], perRestaurant = {}, unplaced = {};
    let counted = 0, good = 0, fromSpots = 0, placed = 0;
    for (const o of input.offers || []) {
      if (!matches(o.seenAt)) continue;
      const w = offerWorth(o, now, input.targetHourlyCents);
      counted++; if (w.good) good++;
      const names = (o.merchants && o.merchants.length ? o.merchants : o.merchant ? [o.merchant] : []).filter(n => normalizeName(n));
      const before = points.length;
      for (const name of names) {
        const id = matchRestaurant(db, name, null);
        if (!id) continue;
        const stat = perRestaurant[id] = perRestaurant[id] || { offers: 0, good: 0 };
        stat.offers++; if (w.good) stat.good++;
        const at = located(id);
        if (at) points.push({ lat: at.lat, lon: at.lon, w: w.q * w.recency / names.length, sigma: 1.0 });
        else unplaced[id] = (unplaced[id] || 0) + 1;
      }
      if (valid(o.waitLat) && valid(o.waitLon)) {
        fromSpots++;
        points.push({ lat: o.waitLat, lon: o.waitLon, w: 0.7 * w.q * w.recency, sigma: 0.6 });
      }
      if (points.length > before) placed++;
    }
    // Hours online in this period, for good offers per hour.
    let minutes = 0;
    for (const sh of input.shifts || []) {
      const a = ms(sh.startedAt), b = valid(ms(sh.endedAt)) ? ms(sh.endedAt) : now;
      if (!valid(a) || b <= a || b - a > 24 * 3600000) continue;
      for (let t = a; t < b; t += 5 * 60000) if (matches(new Date(t).toISOString())) minutes += 5;
    }
    const hours = minutes / 60;
    const restaurants = Object.keys(perRestaurant).map(id => {
      const at = located(id);
      return at ? { id, name: byId[id].name, lat: at.lat, lon: at.lon, source: at.source, offers: perRestaurant[id].offers,
        good: perRestaurant[id].good } : null;
    }).filter(Boolean).sort((a, b) => b.offers - a.offers);
    // Confidence from the offers the map could place (a restaurant position or a waiting spot).
    const result = { part, days, scope, offers: counted, goodOffers: good, placedOffers: placed, fromSpots, hours: Math.round(hours * 10) / 10,
      confidence: placed < 20 ? 'early' : placed < 80 ? 'building' : 'solid', cellMiles: null, cells: [], zones: [], restaurants,
      unplaced: Object.keys(unplaced).sort((a, b) => unplaced[b] - unplaced[a]) };
    if (!points.length) return result;

    // Points on the same spot (≈100 m) are merged so long histories stay fast on the phone.
    const merged = {};
    for (const p of points) {
      const key = p.lat.toFixed(3) + ',' + p.lon.toFixed(3) + ',' + p.sigma;
      const m = merged[key] = merged[key] || { lat: p.lat, lon: p.lon, sigma: p.sigma, w: 0 };
      m.w += p.w;
    }
    const sources = Object.values(merged);
    const lat0 = sources.reduce((n, p) => n + p.lat, 0) / sources.length;
    const milesPerLon = 69.17 * Math.cos(lat0 * Math.PI / 180);
    let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity;
    for (const p of sources) {
      minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat); minLon = Math.min(minLon, p.lon); maxLon = Math.max(maxLon, p.lon);
    }
    const pad = 1.5;
    minLat -= pad / 69.05; maxLat += pad / 69.05; minLon -= pad / milesPerLon; maxLon += pad / milesPerLon;
    let cell = 0.3;
    while (((maxLat - minLat) * 69.05 / cell) * ((maxLon - minLon) * milesPerLon / cell) > 3600) cell *= 1.25;
    const dLat = cell / 69.05, dLon = cell / milesPerLon;
    const grid = [];
    for (let la = minLat + dLat / 2; la < maxLat; la += dLat) {
      for (let lo = minLon + dLon / 2; lo < maxLon; lo += dLon) {
        let v = 0;
        for (const p of sources) {
          const dy = (la - p.lat) * 69.05, dx = (lo - p.lon) * milesPerLon, d2 = dx * dx + dy * dy;
          if (d2 < 9 * p.sigma * p.sigma) v += p.w * Math.exp(-d2 / (2 * p.sigma * p.sigma));
        }
        grid.push({ lat: la, lon: lo, v });
      }
    }
    const max = grid.reduce((m, c) => Math.max(m, c.v), 0);
    if (!(max > 0)) return result;
    const round = x => Math.round(x * 1e5) / 1e5;
    result.cellMiles = Math.round(cell * 100) / 100;
    result.cells = grid.filter(c => c.v >= 0.08 * max)
      .map(c => ({ lat: round(c.lat), lon: round(c.lon), latSpan: round(dLat), lonSpan: round(dLon), value: Math.round(c.v / max * 100) / 100 }));
    // The best spots: the strongest cells at least 1.5 mi apart, with the restaurants that make them.
    for (const c of grid.slice().sort((a, b) => b.v - a.v)) {
      if (c.v < 0.35 * max || result.zones.length >= 3) break;
      if (result.zones.some(z => distanceMiles(z, c) < 1.5)) continue;
      const around = restaurants.filter(r => distanceMiles(r, c) <= 1.5);
      const goodNear = around.reduce((n, r) => n + r.good, 0), offersNear = around.reduce((n, r) => n + r.offers, 0);
      result.zones.push({ lat: round(c.lat), lon: round(c.lon), value: Math.round(c.v / max * 100) / 100,
        near: around.slice(0, 3).map(r => r.name), offers: offersNear, goodOffers: goodNear,
        goodPerHour: hours >= 1 ? Math.round(goodNear / hours * 10) / 10 : null });
    }
    return result;
  }

  // MARK: Gridwise import

  /* Gridwise's CSV reports (user, Oct 19: "build a feature to allow myself and future users to import their data from
   * gridwise"). Earnings report: Date,Category,Service,Amount,Notes — one row per day per service (daily totals, no
   * hours or miles). Expenses report: Date,Category,Amount,Notes. Both become money entries: earnings as kind
   * 'imported' (counted in earnings and the app share, not in $/hr or $/mi — there is no time or distance behind them),
   * expenses as kind 'expense'. Ids are built from the row so importing the same report again adds nothing. */
  function parseCSV(text) {
    const rows = [];
    let row = [], field = '', quoted = false;
    const s = String(text || '').replace(/^﻿/, '');
    for (let i = 0; i < s.length; i++) {
      const ch = s[i];
      if (quoted) {
        if (ch === '"') { if (s[i + 1] === '"') { field += '"'; i++; } else quoted = false; } else field += ch;
      } else if (ch === '"') quoted = true;
      else if (ch === ',') { row.push(field); field = ''; }
      else if (ch === '\n' || ch === '\r') {
        if (ch === '\r' && s[i + 1] === '\n') i++;
        row.push(field); field = '';
        if (row.some(c => c.trim() !== '')) rows.push(row);
        row = [];
      } else field += ch;
    }
    row.push(field);
    if (row.some(c => c.trim() !== '')) rows.push(row);
    return rows;
  }

  /* "2026-10-14" or "10/14/2026" → { y, m, d } (null when not a date). */
  function parseDay(text) {
    const t = String(text || '').trim();
    let m = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(t);
    let y, mo, d;
    if (m) { y = +m[1]; mo = +m[2]; d = +m[3]; } else if ((m = /^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/.exec(t))) {
      mo = +m[1]; d = +m[2]; y = +m[3] < 100 ? 2000 + +m[3] : +m[3];
    } else return null;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return { y, m: mo, d, key: y + '-' + String(mo).padStart(2, '0') + '-' + String(d).padStart(2, '0') };
  }
  /* "$1,234.50", "(12.00)", "-12" → cents (absolute), or null. */
  function parseMoney(text) {
    const t = String(text || '').trim().replace(/[$,\s]/g, '').replace(/^\((.*)\)$/, '$1');
    if (!/^-?\d+(\.\d{1,2})?$/.test(t)) return null;
    return Math.round(Math.abs(parseFloat(t)) * 100);
  }
  const GRIDWISE_SERVICES = { doordash: 'doordash', ubereats: 'uber_eats', grubhub: 'grubhub', instacart: 'instacart', uber: 'uber',
    lyft: 'lyft', spark: 'spark', shipt: 'shipt', amazonflex: 'amazon_flex', roadie: 'roadie', waitr: 'waitr', postmates: 'postmates' };
  function gridwiseService(name) {
    const key = String(name || '').toLowerCase().replace(/[^a-z0-9]/g, '');
    return GRIDWISE_SERVICES[key] || (key ? String(name).trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '') : null);
  }
  const GRIDWISE_EXPENSES = { gas: 'Gas', fuel: 'Gas', charging: 'Charging', carwash: 'Car wash', maintenance: 'Maintenance',
    parkingtolls: 'Parking & tolls', parking: 'Parking & tolls', tolls: 'Parking & tolls', phone: 'Phone', foodanddrink: 'Food & drinks',
    foodanddrinks: 'Food & drinks', foodanddrinksandmeals: 'Food & drinks', other: 'Other' };
  function gridwiseExpenseCategory(name) {
    const raw = String(name || '').trim();
    if (!raw) return 'Other';
    const key = raw.toLowerCase().replace(/&/g, 'and').replace(/[^a-z0-9]/g, '');
    return GRIDWISE_EXPENSES[key] || raw;
  }

  /* text: the CSV; options.offsetMinutes: the phone's offset (each day is stored at local noon so it stays on its day).
   * → { kind: 'earnings' | 'expenses' | null, entries, skipped: [{ line, reason }], from, to, totals } */
  /* Gridwise's Mileage report: Date,Hours,Miles,Deduction Rate Cents/Mi,Deduction — one row per day (hours worked, miles
   * driven, and the deduction Gridwise worked out at that day's rate). Becomes one 'mileage' entry per day: milliMiles,
   * seconds, and amountCents = Gridwise's deduction (their rate changes during the year; it is kept as they computed it). */
  function parseGridwiseMileage(rows, cols, offset, out) {
    out.kind = 'mileage';
    out.totals.miles = 0; out.totals.seconds = 0; out.totals.deductionCents = 0;
    const seen = {};
    rows.slice(1).forEach((r, index) => {
      const line = index + 2;
      const day = parseDay(r[cols.iDate]);
      const hours = parseFloat(String(r[cols.iHours]).replace(/,/g, '')), miles = parseFloat(String(r[cols.iMiles]).replace(/,/g, ''));
      if (!day) { out.skipped.push({ line, reason: 'no date' }); return; }
      if (!valid(hours) || !valid(miles) || hours < 0 || miles < 0) { out.skipped.push({ line, reason: 'no miles' }); return; }
      if (hours === 0 && miles === 0) { out.skipped.push({ line, reason: 'zero' }); return; }
      const rate = cols.iRate >= 0 ? parseFloat(r[cols.iRate]) : NaN;
      let deduction = cols.iDeduction >= 0 ? parseMoney(r[cols.iDeduction]) : null;
      if (deduction === null) deduction = valid(rate) ? Math.round(miles * rate) : 0;
      const milli = Math.round(miles * 1000), seconds = Math.round(hours * 3600);
      const base = 'gw|m|' + day.key;
      seen[base] = (seen[base] || 0) + 1;
      const at = new Date(Date.UTC(day.y, day.m - 1, day.d, 12, 0) - offset * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
      out.entries.push({ id: base + '|' + seen[base], kind: 'mileage', at, amountCents: deduction, milliMiles: milli, seconds,
        category: 'Mileage', platform: null, note: valid(rate) ? 'Gridwise · ' + rate + '¢/mi' : 'Gridwise' });
      if (!out.from || day.key < out.from) out.from = day.key;
      if (!out.to || day.key > out.to) out.to = day.key;
      out.totals.miles += miles; out.totals.seconds += seconds; out.totals.deductionCents += deduction;
    });
    out.totals.miles = Math.round(out.totals.miles * 10) / 10;
    return out;
  }

  function parseGridwise(text, options) {
    const offset = (options && options.offsetMinutes) || 0;
    const rows = parseCSV(text);
    const out = { kind: null, entries: [], skipped: [], from: null, to: null,
      totals: { earningsCents: 0, expensesCents: 0, byPlatform: {}, byCategory: {} } };
    if (!rows.length) return out;
    const header = rows[0].map(h => h.trim().toLowerCase());
    const col = name => header.indexOf(name);
    const iDate = col('date'), iAmount = col('amount'), iCategory = col('category'), iNotes = col('notes'), iService = col('service');
    const iHours = col('hours'), iMiles = col('miles'), iDeduction = col('deduction'), iRate = header.findIndex(h => h.indexOf('deduction rate') === 0);
    if (iDate >= 0 && iHours >= 0 && iMiles >= 0 && iService < 0) return parseGridwiseMileage(rows, { iDate, iHours, iMiles, iDeduction, iRate }, offset, out);
    if (iDate < 0 || iAmount < 0) return out;
    out.kind = iService >= 0 ? 'earnings' : 'expenses';
    const seen = {};
    rows.slice(1).forEach((r, index) => {
      const line = index + 2;
      const day = parseDay(r[iDate]), cents = parseMoney(r[iAmount]);
      if (!day) { out.skipped.push({ line, reason: 'no date' }); return; }
      if (cents === null) { out.skipped.push({ line, reason: 'no amount' }); return; }
      if (cents === 0) { out.skipped.push({ line, reason: 'zero' }); return; }
      const platform = out.kind === 'earnings' ? gridwiseService(r[iService]) : null;
      if (out.kind === 'earnings' && !platform) { out.skipped.push({ line, reason: 'no service' }); return; }
      const category = out.kind === 'expenses' ? gridwiseExpenseCategory(iCategory >= 0 ? r[iCategory] : '')
        : (iCategory >= 0 && r[iCategory].trim() ? r[iCategory].trim() : 'Earnings');
      const note = [out.kind === 'earnings' ? 'Gridwise' : null, iNotes >= 0 ? r[iNotes].trim() : ''].filter(Boolean).join(' · ') || null;
      const base = 'gw|' + (out.kind === 'earnings' ? 'e' : 'x') + '|' + day.key + '|' + (platform || category) + '|' + cents;
      seen[base] = (seen[base] || 0) + 1; // The same amount twice in a day stays two entries.
      const at = new Date(Date.UTC(day.y, day.m - 1, day.d, 12, 0) - offset * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
      out.entries.push({ id: base + '|' + seen[base], kind: out.kind === 'earnings' ? 'imported' : 'expense', at, amountCents: cents,
        category, platform, note });
      if (!out.from || day.key < out.from) out.from = day.key;
      if (!out.to || day.key > out.to) out.to = day.key;
      if (out.kind === 'earnings') {
        out.totals.earningsCents += cents;
        out.totals.byPlatform[platform] = (out.totals.byPlatform[platform] || 0) + cents;
      } else {
        out.totals.expensesCents += cents;
        out.totals.byCategory[category] = (out.totals.byCategory[category] || 0) + cents;
      }
    });
    return out;
  }

  // MARK: Goals

  /* Daily and weekly earnings goals (user, Oct 19), next to the per-shift goal. status of one period's earnings against its
   * goal: progress, what's left, and what it takes — for a day, the minutes still needed at today's pace; for a week, the
   * days left (counting today) and the dollars a day that needs. */
  function goalStatus(m, goalCents, kind, now, rangeEnd) {
    if (!(valid(goalCents) && goalCents > 0)) return null;
    const earned = m.earningsCents, remaining = Math.max(0, goalCents - earned);
    const out = { goalCents, earningsCents: earned, progress: Math.min(1, earned / goalCents), remainingCents: remaining, reached: earned >= goalCents };
    if (!out.reached) {
      if (kind === 'day' && valid(m.perOnlineHourCents) && m.perOnlineHourCents > 0) out.minutesAtPace = Math.round(remaining / m.perOnlineHourCents * 60);
      if (kind === 'week') {
        out.daysLeft = Math.max(1, Math.ceil((rangeEnd - now) / 86400000));
        out.perDayCents = Math.ceil(remaining / out.daysLeft);
      }
    }
    return out;
  }
  /* input: the week view's input ({ shifts, trips, entries, now, offsetMinutes }) plus day: { start, end }, week: { start, end },
   * goals: { dailyCents, weeklyCents }. */
  function goals(input) {
    const g = input.goals || {}, now = ms(input.now);
    const day = input.day ? rangeMetrics(input, input.day.start, input.day.end) : null;
    const week = input.week ? rangeMetrics(input, input.week.start, input.week.end) : null;
    return {
      daily: day ? goalStatus(day, g.dailyCents, 'day', now, ms(input.day.end)) : null,
      weekly: week ? goalStatus(week, g.weeklyCents, 'week', now, ms(input.week.end)) : null,
      todayCents: day ? day.earningsCents : 0, weekCents: week ? week.earningsCents : 0
    };
  }

  // MARK: Reader health

  /* How well the reader is doing, per app, from real use (user, Oct 21: method 6, learn from real trips). Over the last
   * 14 days and the last 2: offers read, how many got a sure verdict (Accept/Decline) vs unsure ("Accept if return",
   * "Check", "time unknown"), why unsure (the map / return couldn't be worked out, or the card's numbers didn't fit), and
   * how often the pay of an order you took had to be corrected. `redesign`: unsure readings jumped (≥ 10 recent offers,
   * unsure share ≥ 35% and at least twice the 14-day share) — the app may have changed its screens. */
  function readerHealth(input) {
    const now = valid(ms(input.now)) ? ms(input.now) : Date.now();
    const day = 86400000;
    const sure = o => /·\s*(Accept|Decline)$/i.test(String(o.notice || '')) && !/time unknown/i.test(String(o.notice || ''));
    const check = o => /^Check\b/.test(String(o.notice || ''));
    const stats = list => {
      const unsure = list.filter(o => !sure(o));
      return { offers: list.length, sure: list.length - unsure.length, unsure: unsure.length,
        unsureMap: unsure.filter(o => !check(o) && !['map', 'dropoff', 'dropoff_town'].includes(o.returnKind)).length,
        unsureNumbers: unsure.filter(check).length,
        unsureShare: list.length ? Math.round(unsure.length / list.length * 100) / 100 : null };
    };
    const orders = ordersOf(input.trips).filter(o => o.ended === 'completed' && ms(o.acceptedAt) >= now - 14 * day);
    const out = {};
    for (const platform of ['doordash', 'uber_eats', 'grubhub']) {
      const offers = (input.offers || []).filter(o => o.platform === platform && valid(ms(o.seenAt)));
      const recent = stats(offers.filter(o => ms(o.seenAt) >= now - 2 * day));
      const fortnight = stats(offers.filter(o => ms(o.seenAt) >= now - 14 * day));
      const taken = orders.filter(o => o.platform === platform);
      const payFixed = taken.filter(o => Number.isSafeInteger(o.offerPayCents) && o.offerPayCents !== o.payCents).length;
      const redesign = recent.offers >= 10 && recent.unsureShare >= 0.35 && fortnight.unsureShare !== null &&
        recent.unsureShare >= 2 * fortnight.unsureShare;
      out[platform] = { recent, fortnight, orders: taken.length, payFixed, redesign };
    }
    return out;
  }

  /* The Breakdown page (user, Oct 23): every offer ever, filtered by time of day, day of week and app.
   * input: { offers, trips, restaurants (db), filters: { part: 'all' | DAY_PARTS key, weekdays: [0-6] (0 = Sunday, empty or
   * missing = all), platform: 'all' | app }, offsetMinutes, centsPerMile }
   * Returns:
   *   mix: { accept, maybe, decline, unread, total } — the verdict each offer got (maybe = "Accept if…", close call, check).
   *   grid: 7 × 24 cells { weekday, hour, offers, good } — when offers come and how many were worth it (app filter only:
   *         the grid is itself the time view).
   *   perMile: { buckets: [{ from, to, count }] in $0.10 steps from $0 to $2+, median, atOrAbove, total } — each offer's
   *         $/mi counting the drive back, against the driver's rate.
   *   payoff: { orders, predicted, actual, followed: {orders, actual}, against: {orders, actual} } — accepted orders that
   *         finished: average predicted vs actual $/hr; "against" = taken although the verdict said Decline.
   *   restaurants: { best, worst } — up to 5 each with 3+ offers: { name, offers, good, rate, waitMinutes }. */
  function verdictOf(notice) {
    const n = String(notice || '');
    if (/· Accept( \(time unknown\))?$/.test(n)) return 'accept';
    if (/· Decline$/.test(n)) return 'decline';
    if (/^Accept if\b|· Close call$|^Check\b|Likely Accept/.test(n)) return 'maybe';
    return 'unread';
  }
  function breakdown(input) {
    const f = input.filters || {}, off = input.offsetMinutes || 0, rate = input.centsPerMile || 100;
    const part = f.part || 'all', days = Array.isArray(f.weekdays) && f.weekdays.length ? f.weekdays : null;
    const appOk = o => !f.platform || f.platform === 'all' || o.platform === f.platform;
    const timeOk = o => {
      const local = localMinute(o.seenAt, off);
      if (!local) return false;
      if (days && !days.includes(local.weekday)) return false;
      return part === 'all' || dayPart(local.minuteOfDay).key === part;
    };
    const offers = (input.offers || []).filter(o => valid(o.payCents));
    const chosen = offers.filter(o => appOk(o) && timeOk(o));

    const mix = { accept: 0, maybe: 0, decline: 0, unread: 0, total: chosen.length };
    for (const o of chosen) mix[verdictOf(o.notice)]++;

    const grid = [];
    for (let d = 0; d < 7; d++) for (let h = 0; h < 24; h++) grid.push({ weekday: d, hour: h, offers: 0, good: 0 });
    for (const o of offers) {
      if (!appOk(o)) continue;
      const local = localMinute(o.seenAt, off);
      if (!local) continue;
      const cell = grid[local.weekday * 24 + Math.floor(local.minuteOfDay / 60)];
      cell.offers++; if (verdictOf(o.notice) === 'accept') cell.good++;
    }

    const rates = [];
    for (const o of chosen) {
      const miles = valid(o.effectiveMilliMiles) ? o.effectiveMilliMiles
        : valid(o.outboundMilliMiles) ? o.outboundMilliMiles + (valid(o.returnMilliMiles) ? o.returnMilliMiles : 0) : null;
      if (miles && miles >= 500) rates.push(o.payCents * 1000 / miles);
    }
    rates.sort((a, b) => a - b);
    const buckets = [];
    for (let c = 0; c < 200; c += 10) buckets.push({ from: c, to: c + 10, count: 0 });
    buckets.push({ from: 200, to: null, count: 0 });
    for (const r of rates) buckets[Math.min(20, Math.floor(r / 10))].count++;
    const perMile = { buckets, total: rates.length, atOrAbove: rates.filter(r => r >= rate).length,
      median: rates.length ? Math.round(rates[Math.floor(rates.length / 2)]) : null };

    const byOffer = {};
    for (const o of offers) byOffer[o.offerId || o.id] = o;
    const avg = list => (list.length ? Math.round(list.reduce((a, b) => a + b, 0) / list.length) : null);
    // Predicted vs actual on the same footing (user, Oct 23: "make sure all the logic is sound"): the verdict's $/hr counts
    // the drive back (minus the part you were driving anyway), so the actual adds the same drive back to the order's time.
    // Only orders with a prediction count, so both averages cover the same orders.
    const pred = [], act = [], followed = [], against = [];
    for (const trip of input.trips || []) for (const order of trip.orders || []) {
      const offer = byOffer[order.offerId];
      if (!offer || !appOk(offer) || !timeOk(offer) || order.ended !== 'completed' || !order.endedAt || !valid(offer.hourlyCents)) continue;
      const back = Math.max(0, (valid(offer.returnMinutes) ? offer.returnMinutes : 0) - (valid(offer.creditMinutes) ? offer.creditMinutes : 0));
      const seconds = (ms(order.endedAt) - ms(order.acceptedAt)) / 1000 + back * 60;
      if (!(seconds >= 300)) continue;
      const actual = order.payCents * 3600 / seconds;
      act.push(actual); pred.push(offer.hourlyCents);
      (verdictOf(offer.notice) === 'decline' ? against : followed).push(actual);
    }
    const payoff = { orders: act.length, predicted: avg(pred), actual: avg(act),
      followed: { orders: followed.length, actual: avg(followed) }, against: { orders: against.length, actual: avg(against) } };

    // Am I too picky? (user, Oct 23). While you wait, an offer is worth taking when it pays more per hour than you actually
    // average online (all earnings ÷ all online hours, waiting included): it raises the average. Count the offers you
    // passed that beat that average, and which of your rules turned them down.
    const takenIds = new Set(ordersOf(input.trips).map(o => o.offerId));
    const span = chosen.length ? [Math.min.apply(null, chosen.map(o => ms(o.seenAt))), Date.now()] : null;
    const online = span ? rangeMetrics(Object.assign({ now: new Date().toISOString() }, input), new Date(span[0] - 86400000).toISOString(), new Date().toISOString()) : null;
    const average = online && online.onlineSeconds >= 3600 ? Math.round(online.earningsCents * 3600 / online.onlineSeconds) : null;
    let picky = { averageHourlyCents: average, passed: 0, beatAverage: 0, failedPerMile: 0, failedHourly: 0, verdict: null };
    if (average !== null) {
      const passed = chosen.filter(o => !takenIds.has(o.offerId || o.id) && valid(o.hourlyCents));
      const beat = passed.filter(o => o.hourlyCents > average);
      const perMileOk = o => valid(o.effectiveMilliMiles) && o.payCents * 1000 >= rate * o.effectiveMilliMiles;
      const share = passed.length ? beat.length / passed.length : 0;
      picky = { averageHourlyCents: average, passed: passed.length, beatAverage: beat.length,
        failedPerMile: beat.filter(o => !perMileOk(o)).length, failedHourly: beat.filter(perMileOk).length,
        verdict: passed.length < 20 ? null : share >= 0.25 ? 'too_picky' : share >= 0.1 ? 'a_little' : 'fine' };
    }

    // Time estimates per app (user, Oct 23: Grubhub shows no time until you accept): __APP_NAME__'s trip time, the app's ETA
    // you entered, and how long the order really took (accept → last drop-off), on the same orders.
    const times = {};
    for (const trip of input.trips || []) for (const order of trip.orders || []) {
      if (order.ended !== 'completed' || !order.endedAt || !appOk(order)) continue;
      const took = (ms(order.endedAt) - ms(order.acceptedAt)) / 60000;
      if (!(took >= 3)) continue;
      const t = times[order.platform] = times[order.platform] || { orders: 0, actual: 0, guessed: 0, guessedOrders: 0, eta: 0, etaOrders: 0 };
      t.orders++; t.actual += took;
      if (valid(order.predictedTripMinutes)) { t.guessed += order.predictedTripMinutes; t.guessedOrders++; }
      if (valid(order.appEtaMinutes)) { t.eta += order.appEtaMinutes; t.etaOrders++; }
    }
    for (const t of Object.values(times)) {
      t.actual = Math.round(t.actual / t.orders);
      t.guessed = t.guessedOrders ? Math.round(t.guessed / t.guessedOrders) : null;
      t.eta = t.etaOrders ? Math.round(t.eta / t.etaOrders) : null;
    }

    const db = input.restaurants && input.restaurants.restaurants ? input.restaurants : null;
    let restaurants = { best: [], worst: [] };
    if (db) {
      const waits = restaurantStats(db, input.trips || [], off);
      const per = {};
      for (const o of chosen) {
        const names = (o.merchants && o.merchants.length ? o.merchants : o.merchant ? [o.merchant] : []);
        for (const name of names) {
          const id = matchRestaurant(db, name, null);
          if (!id) continue;
          const r = per[id] = per[id] || { id, offers: 0, good: 0 };
          r.offers++; if (verdictOf(o.notice) === 'accept') r.good++;
        }
      }
      const names = {};
      for (const r of db.restaurants) names[r.id] = r.name;
      const rows = Object.values(per).filter(r => r.offers >= 3).map(r => ({ name: names[r.id] || r.id, offers: r.offers, good: r.good,
        rate: Math.round(r.good / r.offers * 100), waitMinutes: waits[r.id] ? waits[r.id].averageMinutes : null }));
      const best = rows.slice().sort((a, b) => b.rate - a.rate || b.offers - a.offers).slice(0, 5);
      const worst = rows.slice().sort((a, b) => a.rate - b.rate || b.offers - a.offers).filter(r => !best.includes(r)).slice(0, 5);
      restaurants = { best, worst };
    }
    // How accurate the drive-back estimates are (reader upgrade 1, Oct 23): the return the verdict used vs the real
    // drive back from where you delivered (Apple Maps at the last drop-off), per way the return was worked out.
    const accuracy = {};
    for (const order of ordersOf(input.trips)) {
      const offer = byOffer[order.offerId];
      if (!offer || !appOk(offer) || !valid(order.actualReturnMilliMiles) || !valid(offer.returnMilliMiles)) continue;
      const a = accuracy[offer.returnKind || 'other'] = accuracy[offer.returnKind || 'other'] || { orders: 0, off: 0, bias: 0, within1: 0 };
      const diff = (offer.returnMilliMiles - order.actualReturnMilliMiles) / 1000;
      a.orders++; a.off += Math.abs(diff); a.bias += diff; if (Math.abs(diff) <= 1) a.within1++;
    }
    for (const a of Object.values(accuracy)) {
      a.off = Math.round(a.off / a.orders * 10) / 10; a.bias = Math.round(a.bias / a.orders * 10) / 10;
      a.within1 = Math.round(a.within1 / a.orders * 100);
    }
    return { mix, grid, perMile, payoff, picky, times, accuracy, restaurants };
  }

  /* Shift planner (user, Oct 23): "To make $X this week, work these hours." Each weekday-hour's $/hr from history (pay of
   * orders accepted in that hour ÷ online hours in it, pulled toward the overall $/hr until there are a few hours of
   * history), then the best hours left this week — only hours of the day the driver has worked before — until the expected
   * pay covers what's left of the target, grouped into blocks.
   * input: { trips, shifts, entries, offsetMinutes, now, week: { start, end }, targetCents }
   * Returns { targetCents, earnedCents, remainingCents, hours, expectedCents, reachable, historyHours, overallHourlyCents,
   *           blocks: [{ start, end, hours, expectedCents, hourlyCents }] } */
  function shiftPlan(input) {
    const off = input.offsetMinutes || 0, now = valid(ms(input.now)) ? ms(input.now) : Date.now();
    const hourMs = 3600000, cellOf = t => { const l = localMinute(new Date(t).toISOString(), off); return l.weekday * 24 + Math.floor(l.minuteOfDay / 60); };
    const pay = new Array(168).fill(0), minutes = new Array(168).fill(0), hourWorked = new Array(24).fill(0);
    for (const sh of input.shifts || []) {
      const a = ms(sh.startedAt), b = valid(ms(sh.endedAt)) ? ms(sh.endedAt) : now;
      if (!valid(a) || b <= a || b - a > 24 * hourMs) continue;
      for (let t = a; t < b; t += 5 * 60000) { const c = cellOf(t); minutes[c] += 5; hourWorked[c % 24] += 5; }
    }
    for (const o of ordersOf(input.trips)) {
      if (o.ended !== 'completed' || !valid(ms(o.acceptedAt))) continue;
      pay[cellOf(ms(o.acceptedAt))] += o.payCents || 0;
    }
    const totalMinutes = minutes.reduce((a, b) => a + b, 0), totalPay = pay.reduce((a, b) => a + b, 0);
    const overall = totalMinutes >= 60 ? totalPay * 60 / totalMinutes : null;
    const week = input.week || {}, ws = ms(week.start), we = ms(week.end);
    const earned = valid(ws) ? rangeMetrics(input, week.start, new Date(Math.min(now, we)).toISOString()).earningsCents : 0;
    const target = valid(input.targetCents) && input.targetCents > 0 ? input.targetCents : null;
    const out = { targetCents: target, earnedCents: earned, remainingCents: target === null ? null : Math.max(0, target - earned),
      hours: 0, expectedCents: 0, reachable: true, historyHours: Math.round(totalMinutes / 6) / 10,
      overallHourlyCents: overall === null ? null : Math.round(overall), blocks: [] };
    if (target === null || overall === null || !valid(we) || out.remainingCents === 0) return out;
    // Expected $/hr per cell, with one hour at the overall rate mixed in so a single lucky hour doesn't dominate.
    const rate = c => (pay[c] + overall) / (minutes[c] / 60 + 1);
    const candidates = [];
    for (let t = Math.ceil(now / hourMs) * hourMs; t + hourMs <= we; t += hourMs) {
      const c = cellOf(t);
      if (hourWorked[c % 24] < 60) continue; // Never suggest an hour of the day you've never driven.
      candidates.push({ t, rate: rate(c) });
    }
    candidates.sort((a, b) => b.rate - a.rate || a.t - b.t);
    const chosen = [];
    let expected = 0;
    for (const x of candidates) {
      if (expected >= out.remainingCents || chosen.length >= 70) break;
      chosen.push(x); expected += x.rate;
    }
    out.reachable = expected >= out.remainingCents;
    out.hours = chosen.length; out.expectedCents = Math.round(expected);
    chosen.sort((a, b) => a.t - b.t);
    for (const x of chosen) {
      const last = out.blocks[out.blocks.length - 1];
      if (last && ms(last.end) === x.t) { last.end = new Date(x.t + hourMs).toISOString(); last.hours++; last.expectedCents += x.rate; }
      else out.blocks.push({ start: new Date(x.t).toISOString(), end: new Date(x.t + hourMs).toISOString(), hours: 1, expectedCents: x.rate });
    }
    for (const b of out.blocks) { b.expectedCents = Math.round(b.expectedCents); b.hourlyCents = Math.round(b.expectedCents / b.hours); }
    return out;
  }

  /* How much longer (or shorter) orders really take than __APP_NAME__'s estimated trip time, per app, for offers that showed
   * no time (Grubhub, user Oct 23). From finished orders whose offer had an estimated time: the median of real minutes
   * (accept → last drop-off, or the app's ETA you entered when there's no finish) ÷ the estimate. Needs 3 orders;
   * kept between 0.7 and 2. Returns { grubhub: 1.25, … } — the reader multiplies its estimate by it. */
  function timeFactors(input) {
    const byOffer = {};
    for (const o of input.offers || []) byOffer[o.offerId || o.id] = o;
    const ratios = {};
    for (const order of ordersOf(input.trips)) {
      const offer = byOffer[order.offerId];
      // Estimated: the offer showed no time (the reader left a note on how it worked one out).
      if (!offer || !(offer.tripMinutesEstimated || offer.tripTimeNote) || !valid(offer.tripMinutes) || offer.tripMinutes < 3) continue;
      const took = order.ended === 'completed' && order.endedAt ? (ms(order.endedAt) - ms(order.acceptedAt)) / 60000
        : valid(order.appEtaMinutes) ? order.appEtaMinutes : null;
      if (!(took >= 3)) continue;
      (ratios[order.platform] = ratios[order.platform] || []).push(took / offer.tripMinutes);
    }
    const out = {};
    for (const [platform, list] of Object.entries(ratios)) {
      if (list.length < 3) continue;
      list.sort((a, b) => a - b);
      out[platform] = Math.round(Math.min(2, Math.max(0.7, list[Math.floor(list.length / 2)])) * 100) / 100;
    }
    return out;
  }

  const json = f => (...args) => JSON.stringify(f(...args.map(a => (typeof a === 'string' ? JSON.parse(a) : a))));
  const api = { METERS_PER_MILE, SAME_PLACE_MILES, normalizeName, similarity, distanceMiles, emptyDb, matchRestaurant, updateRestaurants,
    mergeRestaurants, renameRestaurant, mergeSuggestions, storeVisits, restaurantStats, mealPeriod, shiftMetrics, toCSV, exportTables,
    rangeMetrics, weekStats, dayPart, dominantPart, DAY_PARTS, zoneHeat, offerWorth, parseGridwise, parseCSV, goalStatus, goals, readerHealth, breakdown, verdictOf, shiftPlan, timeFactors,
    // JSON bridges for the iPhone (every argument is JSON text).
    updateRestaurantsJSON: json(updateRestaurants), mergeRestaurantsJSON: json(mergeRestaurants), renameRestaurantJSON: json(renameRestaurant),
    mergeSuggestionsJSON: json(mergeSuggestions), restaurantStatsJSON: json(restaurantStats), shiftMetricsJSON: json(shiftMetrics),
    exportTablesJSON: json(exportTables), weekStatsJSON: json(weekStats), zoneHeatJSON: json(zoneHeat), parseGridwiseJSON: json(parseGridwise), goalsJSON: json(goals), readerHealthJSON: json(readerHealth),
    breakdownJSON: json(breakdown), shiftPlanJSON: json(shiftPlan), timeFactorsJSON: json(timeFactors) };
  root.Shift = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
