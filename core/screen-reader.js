/* Shared verbatim by Node and iOS JavaScriptCore. No network, filesystem, or DOM.
 * Turns OCR lines from one screen into an offer reading, and a time-ordered sequence of readings into
 * offer sightings. Raw text is used transiently; outputs contain only offer fields, never customer details. */
(function (root) {
  'use strict';
  const READER_VERSION = 1;
  /* Logic versions stamped on every journaled prediction (addendum §9). Bump the matching string whenever that logic
   * changes, so a past prediction stays attributable to the code that made it. */
  const VERSIONS = {
    reader: 'reader-2026-10-14b',          // build 23: retail pickup labels, counts stripped from names
    rules: 'rules-1',                      // $/effective mile incl. return − drive-back credit; hourly target; map uncertainty
    waitModel: 'static-8pickup-3dropoff',  // assumed stop minutes (PICKUP_STOP_MINUTES / DROPOFF_STOP_MINUTES)
    tripModel: 'card-else-applemaps-1',    // card time, else Apple Maps drive + assumed stops
    marketModel: null,
    evModel: null
  };
  // Layouts checked against real offer-card screenshots (October 12, 2026). Other screens are not read yet.
  const VERIFIED_LAYOUTS = ['uber_eats.offer_card', 'uber_eats.early_look', 'doordash.offer_card', 'doordash.offer_card_stops', 'grubhub.offer_card'];
  const MARKERS = {
    uber_eats: [/Guaranteed \(incl\. tip\)/i, /\bmin\s*\(\s*[\d.]+\s*mi\)\s*total/i, /Boost\+/i, /^Delivery(\s*\(\d+\))?$/i, /^Exclusive$/i, /expected tip/i, /Customer verification/i],
    // "Pick up 3 orders" / "Multiple dropoffs (3 stops)": DoorDash's multi-order card (food bank retail pickup, Oct 15
    // 2026), whose top ("Decline") is outside the part of the screen that is read.
    doordash: [/incl\. tips/i, /^Deliver by\b/i, /Customer dropoff/i, /^((Retail|Grocery|Shop|Store)\s+)?Pickup$/i, /\bstops?\s*\(\s*[\d.]+\s*mi\)/i, /^Decline$/i,
      /Multiple dropoffs\s*\(\d+/i, /^Pick up \d+ (orders?|items?)$/i],
    // Grubhub's "orders" stat label, but not DoorDash's "Pick up 3 orders" (that made a DoorDash card a tie, unread).
    grubhub: [/Delivery pay \+ tip/i, /(^|\s)miles(\s|$)/i, /^(?!Pick up\b)(.*\s)?orders?(\s|$)/i, /(^|\s)minutes(\s|$)/i, /\bReject$/i, /^Food delivery$/i, /^Bundle$/i]
  };
  const PAY = /^\$\s?(\d{1,3})\.(\d{2})(?!\d)/;

  // Strip a stray icon glyph that OCR reads as a one-character token ("o Olive Garden", "0 56 min").
  function clean(text) {
    return String(text).replace(/\s+/g, ' ').trim().replace(/^(?:[^A-Za-z0-9$(\s]{1,2}|[a-z0-9@])\s+(?=[A-Z0-9$(])/, '');
  }
  function slug(text) {
    return text.toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/['’]/g, '')
      .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 80);
  }
  function milli(text) {
    const m = /^(\d{1,3})(?:\.(\d{1,2}))?$/.exec(text);
    return m ? Number(m[1]) * 1000 + (m[2] ? Number(m[2].padEnd(3, '0')) : 0) : null;
  }
  function normalizeLines(lines) {
    if (!Array.isArray(lines)) throw new Error('OCR lines must be an array');
    return lines.filter(l => l && typeof l.text === 'string' && [l.x, l.y, l.w, l.h].every(Number.isFinite))
      .map(l => ({ text: clean(l.text), raw: String(l.text), x: l.x, y: l.y, w: l.w, h: l.h }))
      .filter(l => l.text.length > 0).sort((a, b) => a.y - b.y || a.x - b.x);
  }
  function detectPlatform(lines) {
    let best = null, bestScore = 0, second = 0;
    Object.keys(MARKERS).forEach(platform => {
      const score = MARKERS[platform].filter(re => lines.some(l => re.test(l.text))).length;
      if (score > bestScore) { second = bestScore; bestScore = score; best = platform; } else if (score > second) second = score;
    });
    return { platform: bestScore >= 2 && bestScore > second ? best : null, score: bestScore, runnerUp: second };
  }
  function findPay(lines) {
    const candidates = lines.filter(l => PAY.test(l.text) && !/boost|promo|bonus|peak|surge/i.test(l.text) && l.y > 0.25);
    if (!candidates.length) return null;
    const line = candidates.reduce((a, b) => (b.h > a.h ? b : a));
    const m = PAY.exec(line.text);
    return { line, cents: Number(m[1]) * 100 + Number(m[2]) };
  }
  const below = (lines, ref) => lines.filter(l => l.y > ref.y + ref.h * 0.5);
  const isAddress = text => /\d/.test(text) && /,/.test(text);
  // Words of a line with an approximate x center each (proportional to character position).
  function words(line) {
    const out = [], re = /\S+/g, n = line.text.length || 1;
    let m;
    while ((m = re.exec(line.text))) out.push({ text: m[0], x: line.x + line.w * (m.index + m[0].length / 2) / n, line });
    return out;
  }
  /* Grubhub stats: values printed above small labels ("10.2  1" over "miles  order"). Text recognizers may return each
   * row as one line, so rows are split into words and each label takes the nearest unused number above it. */
  function statColumns(lines) {
    const LABELS = { miles: /^(miles?|mi)$/i, minutes: /^(minutes?|mins?)$/i, orders: /^orders?$/i };
    const result = {}, used = new Set();
    lines.forEach(l => words(l).forEach(t => {
      const key = Object.keys(LABELS).find(k => LABELS[k].test(t.text));
      if (!key || result[key] !== undefined) return;
      const numbers = [];
      lines.filter(v => v !== l && v.y < l.y && l.y - v.y < 0.1)
        .forEach(v => words(v).forEach(w => { if (/^\d{1,3}(?:[.,]\d{1,2})?$/.test(w.text) && !used.has(w)) numbers.push(w); }));
      const best = numbers.filter(w => Math.abs(w.x - t.x) < 0.07)
        .sort((a, b) => Math.abs(a.x - t.x) - Math.abs(b.x - t.x) || b.line.y - a.line.y)[0];
      if (best) { used.add(best); result[key] = best.text.replace(',', '.'); }
    }));
    return result;
  }
  function readUber(lines, pay, f, problems) {
    const total = lines.find(l => /(\d{1,3})\s*min\s*\(\s*([\d.]+)\s*mi\)\s*total/i.test(l.text));
    if (total) {
      const m = /(\d{1,3})\s*min\s*\(\s*([\d.]+)\s*mi\)\s*total/i.exec(total.text);
      f.appMinutes = Number(m[1]); f.milesText = m[2];
      const next = below(lines, total);
      if (next[0] && !isAddress(next[0].text)) f.merchants.push(next[0].text);
      const area = next[1] && /,\s*([A-Za-z][A-Za-z .'-]{2,30})$/.exec(next[1].text);
      if (area) { f.dropoffArea = area[1].trim(); f.routing.dropoffQuery = next[1].text; }
    } else {
      // "Early look" offer during a delivery (Oct 15 2026): "Est. delivery 7:00 PM • 11.2 mi", restaurant, then the
      // drop-off cross-streets and town. The time is a clock time, turned into minutes like DoorDash's "Deliver by".
      const est = lines.find(l => /Est\.?\s*delivery\s+\d{1,2}:\d{2}\s*[AP]\.?M\s*\S\s*[\d.]+\s*mi/i.test(l.text));
      if (est) {
        const m = /Est\.?\s*delivery\s+(\d{1,2}):(\d{2})\s*([AP])\.?M\s*\S\s*([\d.]+)\s*mi/i.exec(est.text);
        f.milesText = m[4];
        f.deliverByMinutes = (Number(m[1]) % 12 + (/p/i.test(m[3]) ? 12 : 0)) * 60 + Number(m[2]);
        const next = below(lines, est);
        if (next[0] && !isAddress(next[0].text)) f.merchants.push(next[0].text.replace(/^[a-z]\s+(?=[A-Z])/, ''));
        const area = next[1] && /,\s*([A-Za-z][A-Za-z .'-]{2,30})$/.exec(next[1].text);
        if (area) { f.dropoffArea = area[1].trim(); f.routing.dropoffQuery = next[1].text; }
        f.earlyLook = true;
      } else problems.push('Uber Eats total time/mileage line not found');
    }
    const deliveries = lines.find(l => /^Delivery\s*\((\d+)\)$/i.test(l.text));
    f.orderCount = deliveries ? Number(/\((\d+)\)/.exec(deliveries.text)[1]) : (lines.some(l => /^Delivery$/i.test(l.text)) ? 1 : null);
    const boost = lines.find(l => /^\$(\d{1,3})\.(\d{2})\s*Boost\+?\s*included/i.test(l.text));
    if (boost) { const b = /^\$(\d{1,3})\.(\d{2})/.exec(boost.text); f.includedBoostCents = Number(b[1]) * 100 + Number(b[2]); }
    f.exclusive = lines.some(l => /^Exclusive$/i.test(l.text));
    f.layout = f.earlyLook ? 'uber_eats.early_look' : 'uber_eats.offer_card';
  }
  function readDoorDash(lines, pay, f, problems) {
    const stops = lines.find(l => /(\d{1,2})\s*stops?\s*\(\s*([\d.]+)\s*mi\)/i.test(l.text));
    const plain = lines.find(l => /^([\d.]+)\s*mi\b/i.test(l.text) && l.y > pay.line.y);
    let anchor = null;
    if (stops) {
      const m = /(\d{1,2})\s*stops?\s*\(\s*([\d.]+)\s*mi\)(?:\s*\S\s*(\d{1,3})\s*min)?/i.exec(stops.text);
      f.milesText = m[2]; if (m[3]) f.appMinutes = Number(m[3]); f.stopCount = Number(m[1]); anchor = stops;
      f.layout = 'doordash.offer_card_stops';
    } else if (plain) {
      f.milesText = /^([\d.]+)/.exec(plain.text)[1]; anchor = plain; f.layout = 'doordash.offer_card';
      const by = lines.find(l => /^Deliver by\b/i.test(l.text)); if (by) anchor = by;
      // "Deliver by 12:48 PM": the caller turns this into minutes using the phone's clock.
      const t = by && /Deliver by\s+(\d{1,2}):(\d{2})\s*([AP])\.?M/i.exec(by.text);
      if (t) f.deliverByMinutes = (Number(t[1]) % 12 + (/p/i.test(t[3]) ? 12 : 0)) * 60 + Number(t[2]);
    } else problems.push('DoorDash mileage line not found');
    // "Pickup", or "Retail pickup" for shop orders (Oct 14 2026 card).
    const pickups = lines.filter(l => /^((Retail|Grocery|Shop|Store)\s+)?Pickup$/i.test(l.text));
    if (stops && !pickups.length) {
      // Stacked/multi-stop card (Oct 15 2026): each store's name above its street address, until the drop-off note.
      for (const l of below(lines, stops)) {
        if (/Multiple dropoffs|Customer dropoff|Guaranteed|^Accept/i.test(l.text)) break;
        const after = below(lines, l)[0];
        if (!isAddress(l.text) && after && isAddress(after.text)) {
          f.merchants.push(l.text);
          if (!f.routing.pickupQuery) f.routing.pickupQuery = after.text;
        }
      }
    }
    if (f.merchants.length) {
      // Stores already read from the stacked layout.
    } else if (pickups.length) {
      pickups.forEach(p => { const n = below(lines, p)[0]; if (n && !/^((Retail|Grocery|Shop|Store)\s+)?Pickup$/i.test(n.text) && !/^Customer dropoff$/i.test(n.text)) f.merchants.push(n.text); });
    } else if (anchor) {
      const n = below(lines, anchor).find(l => !/^Customer dropoff$/i.test(l.text) && !isAddress(l.text) && !/^Accept/i.test(l.text));
      if (n) {
        f.merchants.push(n.text);
        // The restaurant's own street address, shown under its name.
        const address = below(lines, n)[0];
        if (address && isAddress(address.text)) f.routing.pickupQuery = address.text;
      }
    }
    const drops = lines.filter(l => /Customer dropoff/i.test(l.text)).length;
    const multiple = lines.map(l => /Multiple dropoffs\s*\((\d+)\s*stops?\)/i.exec(l.text)).find(Boolean);
    f.orderCount = multiple ? Number(multiple[1]) : drops || null;
  }
  function readGrubhub(lines, pay, f, problems) {
    // Number over label ("21.9" / "miles"), or both on one line as some text recognizers return them.
    const inline = re => { const l = lines.find(x => re.test(x.text)); return l ? re.exec(l.text)[1].replace(',', '.') : null; };
    const columns = statColumns(lines);
    f.milesText = columns.miles || inline(/^(\d{1,3}(?:[.,]\d{1,2})?)\s*(?:miles?|mi)$/i) || null;
    if (f.milesText === null) problems.push('Grubhub mileage value not found');
    const minutes = columns.minutes || inline(/^(\d{1,3})\s*(?:minutes?|mins?)$/i);
    if (minutes && /^\d+$/.test(minutes)) f.appMinutes = Number(minutes);
    const orders = columns.orders || inline(/^(\d{1,2})\s*orders?$/i);
    if (orders && /^\d+$/.test(orders)) f.orderCount = Number(orders);
    // Grubhub centers the merchant above the pay; map labels cut off at the screen edge are not candidates.
    const center = pay.line.x + pay.line.w / 2;
    const name = lines.filter(l => l.y < pay.line.y && pay.line.y - l.y < 0.08 && !/^(Food delivery|Bundle|\d+)$/i.test(l.text) &&
      Math.abs(l.x + l.w / 2 - center) < 0.2 && /[A-Za-z].*[A-Za-z]/.test(l.text) && l.x > 0.02 && l.x + l.w < 0.98)
      .sort((a, b) => b.y - a.y)[0];
    if (name) f.merchants.push(name.text);
    f.layout = 'grubhub.offer_card';
  }

  /* `options.withRouting` adds `routing` queries for a live return estimate: the Uber drop-off cross-street and town
   * and the restaurant address or name. They exist only for an immediate map lookup and must never be stored. */
  function readScreen(rawLines, options) {
    const lines = normalizeLines(rawLines);
    const detected = detectPlatform(lines), pay = findPay(lines);
    if (!detected.platform || !pay) return { readerVersion: READER_VERSION, kind: 'unrecognized', platform: detected.platform };
    const card = lines.filter(l => l.y >= pay.line.y - 0.1);
    const f = { payCents: pay.cents, milesText: null, appMinutes: null, merchants: [], dropoffArea: null, orderCount: null,
      stopCount: null, includedBoostCents: null, exclusive: false, layout: null, routing: { dropoffQuery: null, pickupQuery: null } };
    const problems = [];
    ({ uber_eats: readUber, doordash: readDoorDash, grubhub: readGrubhub })[detected.platform](card, pay, f, problems);
    const text = card.map(l => l.text).join('\n');
    const payBasis = /Guaranteed/i.test(text) ? 'guaranteed' : 'displayed_estimate';
    const orderType = /\b(Shop(ping)?|Shop & Pay|Grocer(y|ies)|Retail)\b/i.test(text) ? 'shop' : /\b(Package|Parcel|Courier)\b/i.test(text) ? 'other' : 'food';
    const outboundMilliMiles = f.milesText === null ? null : milli(f.milesText);
    if (f.milesText !== null && outboundMilliMiles === null) problems.push('Mileage text is not a plain number');
    if (f.milesText !== null && f.milesText.indexOf('.') < 0 && Number(f.milesText) >= 20) problems.push('Mileage has no decimal point; OCR may have dropped it');
    if (pay.cents < 100 || pay.cents > 50000) problems.push('Pay is outside the plausible range');
    // "Five Guys (2 orders)", "Petsmart (77 items)": the count is not part of the name.
    const merchants = f.merchants.map(m => m.replace(/\s+/g, ' ').replace(/\s*\(\d+\s+(orders?|items?)\)\s*$/i, '').trim()).filter(m => slug(m).length > 1);
    if (!merchants.length) problems.push('Merchant name not found');
    let confidence = 0.97 - 0.15 * problems.length - (detected.score - detected.runnerUp < 2 ? 0.05 : 0);
    if (outboundMilliMiles === null) confidence = Math.min(confidence, 0.5);
    confidence = Math.max(0, Math.round(confidence * 100) / 100);
    const reading = { readerVersion: READER_VERSION, kind: 'offer', platform: detected.platform, layout: f.layout,
      layoutVerified: VERIFIED_LAYOUTS.includes(f.layout),
      payCents: pay.cents, payBasis, outboundMilliMiles, distanceBasis: 'platform_total',
      appMinutes: f.appMinutes, deliverByMinutes: f.deliverByMinutes === undefined ? null : f.deliverByMinutes,
      merchants, merchantKey: merchants.length ? slug(merchants[0]) : null,
      dropoffArea: f.dropoffArea, orderCount: f.orderCount, stopCount: f.stopCount,
      includedBoostCents: f.includedBoostCents, exclusive: f.exclusive, orderType, confidence, problems };
    if (outboundMilliMiles === null && options && options.withRouting) {
      // What the phone read on a card whose miles could not be found, for diagnosis. Address-like lines are dropped.
      reading.cardText = card.filter(l => !(isAddress(l.text))).slice(0, 14).map(l => l.text).join(' | ').slice(0, 300);
    }
    if (options && options.withRouting) {
      // On stacked Uber cards the drop-off line is taken as the final stop (assumption from the card layout:
      // the square marker ends the route). A pickup is used only with a street number: a bare name could match
      // the wrong branch of a chain, and the worst-case return bound is only safe for a restaurant on the route.
      const pickup = f.routing.pickupQuery || merchants[0] || null;
      // The offer map ends where the card begins; map reading must not pick up card text.
      const cardTop = Math.min.apply(null, lines.filter(l => l.y >= pay.line.y - 0.12).map(l => l.y));
      // pickupName: searched near the driver's position when there is no address (the nearest branch is the offer's).
      reading.routing = { dropoffQuery: f.routing.dropoffQuery, pickupQuery: pickup && /\d/.test(pickup) ? pickup : null,
        pickupName: merchants[0] || null, dropoffCount: reading.orderCount || 1,
        pickupCount: Math.max(1, merchants.length), mapBottom: Math.round(Math.max(0.2, Math.min(0.53, cardTop - 0.01)) * 1000) / 1000 };
    }
    return reading;
  }

  const PREFIX = { doordash: 'dd', uber_eats: 'ue', grubhub: 'gh' };
  // FNV-1a; stable across Node and JavaScriptCore for deterministic offer IDs.
  function hash(text) {
    let h = 0x811c9dc5;
    for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
    return ('0000000' + h.toString(16)).slice(-8);
  }
  function compatible(a, b) {
    if (a.platform !== b.platform) return false;
    const same = ['payCents', 'outboundMilliMiles', 'merchantKey'].filter(k => a[k] !== null && a[k] === b[k]).length;
    return same >= 2 || (same === 1 && a.payCents === b.payCents);
  }
  function mode(values) {
    const counts = new Map();
    values.forEach(v => { if (v !== null && v !== undefined) { const k = JSON.stringify(v); counts.set(k, (counts.get(k) || 0) + 1); } });
    let best = null, n = 0; counts.forEach((c, k) => { if (c > n) { n = c; best = k; } });
    return { value: best === null ? null : JSON.parse(best), agreement: values.length ? n / values.length : 0 };
  }
  /* frames: [{ at: ISO string, reading }] in time order, each reading from readScreen. A frame's state lasts until the
   * next frame (decimated video drops unchanged frames). maxGapMs closes a sighting when frames are missing. */
  function trackSightings(frames, options) {
    const maxGapMs = (options && options.maxGapMs) || 15000;
    const sightings = []; let open = null;
    function close(endMs) {
      if (!open) return;
      const r = open.readings, pick = k => mode(r.map(x => x[k]));
      const pay = pick('payCents'), miles = pick('outboundMilliMiles'), merchant = pick('merchantKey');
      const best = r.filter(x => x.payCents === pay.value && x.outboundMilliMiles === miles.value)
        .sort((a, b) => b.confidence - a.confidence)[0] || r[0];
      const agreement = Math.min(pay.agreement, miles.value === null ? 1 : miles.agreement);
      const problems = best.problems.slice();
      if (agreement < 1) problems.push('Frames disagreed on pay or mileage; majority reading used');
      sightings.push(Object.assign({}, best, { payCents: pay.value, outboundMilliMiles: miles.value, merchantKey: merchant.value,
        firstAt: new Date(open.firstMs).toISOString(), lastAt: new Date(endMs).toISOString(), frameCount: r.length,
        confidence: Math.round(Math.min(best.confidence, best.confidence * (0.5 + agreement / 2)) * 100) / 100, problems }));
      open = null;
    }
    let previousMs = null;
    frames.forEach(frame => {
      const ms = Date.parse(frame.at);
      if (!Number.isFinite(ms) || (previousMs !== null && ms < previousMs)) throw new Error('Frames must be time-ordered with valid timestamps');
      if (open && ms - open.lastMs > maxGapMs) close(open.lastMs);
      const reading = frame.reading;
      if (reading && reading.kind === 'offer') {
        if (open && compatible(open.readings[open.readings.length - 1], reading)) { open.readings.push(reading); open.lastMs = ms; }
        else { close(ms); open = { firstMs: ms, lastMs: ms, readings: [reading] }; }
      } else if (open) close(ms);
      previousMs = ms;
    });
    if (open) close(open.lastMs);
    return sightings.map(s => Object.assign(s, { offerId: PREFIX[s.platform] + ':' + hash([s.firstAt, s.payCents, s.outboundMilliMiles, s.merchantKey].join('|')) }));
  }
  // Event-contract offer object. Platform mileage is one inclusive figure from the current location.
  function toOffer(sighting) {
    return { offerId: sighting.offerId, platform: sighting.platform, merchantKey: sighting.merchantKey || 'unknown-merchant',
      orderType: sighting.orderType, payCents: sighting.payCents, payBasis: sighting.payBasis,
      source: 'unverified_adapter', confidence: sighting.confidence,
      route: { toPickupMilliMiles: null, deliveryMilliMiles: null, outboundMilliMiles: sighting.outboundMilliMiles,
        returnMilliMiles: null, minutesLow: null, minutesHigh: null, source: 'unavailable', conflicts: false } };
  }

  const APP_NAMES = { doordash: 'DoorDash', uber_eats: 'Uber Eats', grubhub: 'Grubhub' };
  const miles1 = mm => (mm / 1000).toFixed(1);
  /* One wording for the desktop report and the iPhone notification. Without a return route, the verdict is the
   * longest return to __HOME_NAME__ that still meets the per-mile target. `copilot` is the shared engine. */
  function verdict(sighting, copilot, settings) {
    const a = copilot.evaluateOffer(toOffer(Object.assign({ offerId: sighting.offerId || 'live:0' }, sighting)), settings || {});
    const s = copilot.settings(settings || {}), max = a.maxReturnMilliMilesForTarget;
    const target = '$' + (s.centsPerMile / 100).toFixed(2).replace(/\.00$/, '') + '/mi';
    let tone, text;
    if (max === null) { tone = 'unknown'; text = 'Mileage not read'; }
    else if (max < 0) { tone = 'bad'; text = 'Below ' + target + ' before the return trip'; }
    else { tone = max >= 5000 ? 'good' : 'tight'; text = 'Meets ' + target + ' if return ≤ ' + miles1(max) + ' mi'; }
    return { tone, text, maxReturnMilliMiles: max, dollarsPerOutboundMile: a.dollarsPerOutboundMile, assessment: a };
  }
  // Rounded down for display, so a failing $0.9999/mi never shows as $1.00.
  const perMile = (payCents, milliMiles) => '$' + (Math.floor(payCents * 1000 / milliMiles) / 100).toFixed(2) + '/mi';
  /* The notification's second line, as the user asked: dollars per mile and Accept/Decline when decidable.
   * Without a return estimate it states the condition instead of guessing. */
  function breakEvenNotice(summary) {
    const max = summary.maxReturnMilliMiles;
    if (max === null || summary.outboundMilliMiles === null || summary.outboundMilliMiles === 0) return 'Check offer';
    if (max < 0) return perMile(summary.payCents, summary.outboundMilliMiles) + ' · Decline';
    return 'Accept if return ≤ ' + miles1(max) + ' mi';
  }
  /* Live summary of one screen for the iPhone extension: offer fields and verdict, never raw text. `routing` holds the
   * transient map-lookup queries; the caller strips it before storing or displaying anything. */
  function summarize(lines, copilot, settings, options) {
    const r = readScreen(lines, { withRouting: true });
    if (r.kind !== 'offer') return null;
    // DoorDash "Deliver by" → minutes from now. The clock on the screen (status bar, 12-hour, no AM/PM) is preferred:
    // it is the time the card was shown, even for a screenshot viewed later. Else the phone's clock.
    let needsClock = false;
    if (r.appMinutes === null && r.deliverByMinutes !== null) {
      const until = now => (r.deliverByMinutes - now + 1440) % 1440;
      const shown = options && /(\d{1,2}):(\d{2})/.exec(options.clockText || '');
      const candidates = shown ? [0, 12].map(add => (Number(shown[1]) % 12 + add) * 60 + Number(shown[2])) : [];
      if (!shown && options && Number.isFinite(options.localMinutes)) candidates.push(options.localMinutes);
      const best = candidates.map(until).filter(m => m >= 1 && m <= 240).sort((a, b) => a - b)[0];
      if (best !== undefined) r.appMinutes = best;
      needsClock = !shown;
    }
    const v = verdict(r, copilot, settings);
    const pay = '$' + (r.payCents / 100).toFixed(2);
    const summary = { platform: r.platform, payCents: r.payCents, outboundMilliMiles: r.outboundMilliMiles, appMinutes: r.appMinutes,
      merchant: r.merchants.join(' + ') || null, dropoffArea: r.dropoffArea, orderCount: r.orderCount, confidence: r.confidence,
      tone: v.tone, maxReturnMilliMiles: v.maxReturnMilliMiles, returnMilliMiles: null, returnKind: null,
      headline: APP_NAMES[r.platform] + ' ' + pay + (r.outboundMilliMiles === null ? '' : ' · ' + miles1(r.outboundMilliMiles) + ' mi'),
      detail: v.text, notice: null, fingerprint: [r.platform, r.payCents, r.outboundMilliMiles].join('|'), routing: r.routing,
      readerDebug: r.cardText ? 'miles not read; card text: ' + r.cardText : null,
      // Stores and drop-offs, for the trip steps in the app (multi-pickup and multi-drop-off offers).
      merchants: r.merchants.slice(0, 6), pickupCount: Math.max(1, (r.routing && r.routing.pickupCount) || r.merchants.length || 1),
      dropoffCount: Math.max(1, (r.routing && r.routing.dropoffCount) || r.orderCount || 1),
      // Ask the caller to read the status-bar clock and summarize again.
      needsClock };
    summary.notice = breakEvenNotice(summary);
    return summary;
  }

  /* Adds a mapped return to __HOME_NAME__. route.kind:
   *   'dropoff'      — road route from the shown drop-off street (an estimate: cross-street, not the door)
   *   'dropoff_town' — road route from the drop-off town's center (rougher estimate)
   *   'map'          — drop-off pins read off the offer map; route.uncertaintyMilliMiles bounds the position error
   *   'worst_case'   — a point on the route (restaurant, or the driver's position) → __HOME_NAME__ plus the app's whole
   *                    trip mileage: the return cannot be longer
   * `route.note` (no route) explains why for the app's offer list. */
  // Assumed stop time until restaurant waits are learned (user asked for an estimate when the card shows no time).
  const PICKUP_STOP_MINUTES = 8, DROPOFF_STOP_MINUTES = 3;
  /* Minutes from now to the last drop-off. The card's own time when shown; else an Apple Maps drive time for the trip
   * (route.tripDriveMinutes: here → pickup → drop-offs) plus assumed stop time; else the trip's miles at the average
   * speed of the return or drive-back route plus stop time. */
  function tripMinutes(summary, route, ret, credit) {
    if (summary.appMinutes !== null) return { minutes: summary.appMinutes, estimated: false, note: null };
    const valid = v => Number.isSafeInteger(v) && v >= 0;
    const pickups = (summary.routing && summary.routing.pickupCount) || 1, drops = summary.orderCount || 1;
    const stops = PICKUP_STOP_MINUTES * pickups + DROPOFF_STOP_MINUTES * drops;
    let drive = null, how = null;
    if (route && valid(route.tripDriveMinutes)) { drive = route.tripDriveMinutes; how = 'Apple Maps drive'; }
    else if (route && valid(route.returnMinutes) && ret > 0 && route.kind !== 'worst_case') {
      drive = Math.round(summary.outboundMilliMiles * route.returnMinutes / ret); how = 'app miles at the return route’s speed';
    } else if (route && valid(route.creditMinutes) && credit > 0) {
      drive = Math.round(summary.outboundMilliMiles * route.creditMinutes / credit); how = 'app miles at the drive-back route’s speed';
    }
    if (drive === null) return { minutes: null, estimated: true, note: null };
    return { minutes: drive + stops, estimated: true,
      note: 'Trip time estimated: ' + how + ' ' + drive + ' min + ' + stops + ' min for stops (assumed ' + PICKUP_STOP_MINUTES +
        ' per pickup, ' + DROPOFF_STOP_MINUTES + ' per drop-off)' };
  }

  /* route.creditMilliMiles / creditMinutes: the drive from the driver's position back to __HOME_NAME__. The user always
   * returns there, and that drive was already counted against the previous order, so an offer is charged only the
   * miles and minutes it adds: here→pickup→drop-offs→__HOME_NAME__ minus here→__HOME_NAME__ (user's rule, Oct 14 2026).
   * route.returnMinutes: Apple Maps drive time for the return. Hourly uses the app's time estimate plus that. */
  function withReturn(summary, route, copilot, settings) {
    const out = Object.assign({}, summary, { returnNote: route && route.note ? String(route.note) : null,
      returnDebug: [summary.readerDebug, route && route.debug].filter(Boolean).join(' · ').slice(0, 400) || null,
      creditMilliMiles: null, effectiveMilliMiles: null, hourlyCents: null, tripTimeNote: null,
      uncertaintyMilliMiles: null, returnMinutes: null, creditMinutes: null, tripMinutes: null, tripMinutesEstimated: null });
    delete out.routing; delete out.readerDebug; delete out.needsClock;
    if (!out.notice) out.notice = breakEvenNotice(summary);
    const s = copilot.settings(settings || {}), pay = summary.payCents, outbound = summary.outboundMilliMiles;
    if (outbound === null || pay === null || summary.maxReturnMilliMiles === null) return out;
    const valid = v => Number.isSafeInteger(v) && v >= 0;
    const target = '$' + (s.centsPerMile / 100).toFixed(2).replace(/\.00$/, '') + '/mi';
    const ret = route && valid(route.returnMilliMiles) ? route.returnMilliMiles : null;
    let credit = route && valid(route.creditMilliMiles) && route.creditMilliMiles >= 300 ? route.creditMilliMiles : 0;
    if (ret !== null) credit = Math.min(credit, outbound + ret - 500);
    credit = Math.max(0, credit);
    if (credit) out.creditMilliMiles = credit;
    const creditText = credit ? ' (minus ' + miles1(credit) + ' mi you were driving back anyway)' : '';
    if (ret === null) {
      // No return: say how long a return the offer can afford, counting the drive back already planned.
      if (credit) {
        const max = Math.floor(pay * 1000 / s.centsPerMile) - (outbound - credit);
        out.notice = max < 0 ? perMile(pay, Math.max(500, outbound - credit)) + ' · Decline' : 'Accept if return ≤ ' + miles1(max) + ' mi';
        out.detail = (max < 0 ? 'Below ' + target + ' before the return trip' : 'Meets ' + target + ' if return ≤ ' + miles1(max) + ' mi') + creditText;
      }
      return out;
    }
    out.returnMilliMiles = ret; out.returnKind = route.kind;
    if (pay * 1000 < s.centsPerMile * Math.max(500, outbound - credit)) {
      // Below target before any return driving.
      out.tone = 'bad';
      out.detail = 'Below ' + target + ' before the return trip' + creditText;
      out.notice = perMile(pay, Math.max(500, outbound - credit)) + ' · Decline';
      return out;
    }
    const effective = Math.max(500, outbound + ret - credit);
    out.effectiveMilliMiles = effective;
    let surely, surelyNot, prefix = '';
    if (route.kind === 'map') {
      // Drop-off read from the map pins: decide only if the answer holds across the stated uncertainty.
      const u = valid(route.uncertaintyMilliMiles) && route.uncertaintyMilliMiles > 0 ? route.uncertaintyMilliMiles : 1000;
      out.uncertaintyMilliMiles = u;
      surely = pay * 1000 >= s.centsPerMile * (effective + u);
      surelyNot = pay * 1000 < s.centsPerMile * Math.max(500, outbound - credit, effective - u);
      prefix = '≈';
    } else if (route.kind === 'worst_case') {
      // An upper bound on the return: passing proves it; failing proves nothing.
      surely = pay * 1000 >= s.centsPerMile * effective; surelyNot = pay * 1000 < s.centsPerMile * Math.max(500, outbound - credit);
      prefix = surely ? '≥' : '';
    } else {
      surely = pay * 1000 >= s.centsPerMile * effective; surelyNot = !surely;
    }
    // Hourly: time to the last drop-off + return drive − the drive back already planned.
    const creditMinutes = credit && route && valid(route.creditMinutes) ? route.creditMinutes : 0;
    const trip = tripMinutes(summary, route, ret, credit);
    if (trip.note) out.tripTimeNote = trip.note;
    out.tripMinutes = trip.minutes; out.tripMinutesEstimated = trip.minutes === null ? null : trip.estimated;
    if (valid(route.returnMinutes)) out.returnMinutes = route.returnMinutes;
    if (creditMinutes) out.creditMinutes = creditMinutes;
    const minutes = trip.minutes !== null && route && valid(route.returnMinutes) ? trip.minutes + route.returnMinutes - creditMinutes : null;
    const hourly = minutes !== null && minutes >= 5 ? pay * 60 / minutes : null;
    if (hourly !== null) out.hourlyCents = Math.round(hourly);
    const hourlyOk = s.hourlyTargetCents === null ? true : hourly === null ? null : hourly >= s.hourlyTargetCents;
    const hourText = hourly !== null ? ' · ' + (trip.estimated ? '~' : '') + '$' + Math.floor(hourly / 100) + '/hr' : '';
    let verdictWord;
    if (surelyNot || hourlyOk === false) verdictWord = 'Decline';
    else if (surely) verdictWord = hourlyOk === null ? 'Accept (time unknown)' : 'Accept';
    else if (route.kind === 'worst_case') verdictWord = null;
    else verdictWord = 'Close call';
    // "Accept" with under 2 miles of slack is shown as tight.
    const slack = Math.floor(pay * 1000 / s.centsPerMile) - effective;
    // A pass against the longest possible return has more real slack than shown.
    out.tone = verdictWord === 'Decline' ? 'bad' : verdictWord === 'Accept' && (slack >= 2000 || route.kind === 'worst_case') ? 'good' : 'tight';
    const why = hourlyOk === false && !surelyNot ? ' — below $' + (s.hourlyTargetCents / 100).toFixed(0) + '/hr' : '';
    const kindText = route.kind === 'map' ? ' (map estimate ±' + miles1(valid(route.uncertaintyMilliMiles) ? route.uncertaintyMilliMiles : 1000) + ' mi)'
      : route.kind === 'dropoff_town' ? ' (from town center)' : route.kind === 'worst_case' ? ' (longest possible)' : '';
    if (verdictWord === null) {
      out.tone = summary.tone;
      out.detail = summary.detail + '; return could be up to ' + miles1(ret) + ' mi' + creditText;
      out.notice = summary.notice;
      return out;
    }
    const lead = surely ? 'Meets ' : surelyNot ? 'Below ' : 'Close to ';
    out.detail = lead + target + ' · ' + prefix + perMile(pay, effective) + hourText + ' with ~' + miles1(ret) + ' mi return' + kindText + creditText + why;
    out.notice = prefix + perMile(pay, effective) + hourText + ' · ' + verdictWord;
    return out;
  }

  /* Stage 1 of the two-stage verdict (roadmap §3): an immediate answer from what is already known, before any
   * routing. context.creditMilliMiles / creditMinutes: a recent drive-back measurement (0 = at __HOME_NAME__), or
   * absent when the position is unknown. When it is known, the return can be at most (here→__HOME_NAME__) + the trip's
   * miles, so the effective miles are at most 2 × app miles — a safe bound for a quick "Likely Accept".
   * Returns { word: 'Decline' | 'LikelyAccept' | 'Conditional' | 'Unreadable', notice }. */
  function preliminary(summary, context, copilot, settings) {
    const s = copilot.settings(settings || {}), pay = summary.payCents, outbound = summary.outboundMilliMiles;
    if (pay === null || outbound === null || outbound === 0 || summary.maxReturnMilliMiles === null) return { word: 'Unreadable', notice: 'Check offer' };
    const valid = v => Number.isSafeInteger(v) && v >= 0;
    const known = context && valid(context.creditMilliMiles);
    const credit = known && context.creditMilliMiles >= 300 ? context.creditMilliMiles : 0;
    const creditMinutes = known && credit && valid(context.creditMinutes) ? context.creditMinutes : 0;
    // Certain mileage failure: below target even with no return driving at all.
    if (pay * 1000 < s.centsPerMile * Math.max(500, outbound - credit)) {
      return { word: 'Decline', notice: perMile(pay, Math.max(500, outbound - credit)) + ' · Decline' };
    }
    // Certain hourly failure: even the card's own time (no return, minus the drive back already planned) is too slow.
    if (s.hourlyTargetCents !== null && summary.appMinutes !== null && summary.appMinutes - creditMinutes >= 5 &&
        pay * 60 / (summary.appMinutes - creditMinutes) < s.hourlyTargetCents) {
      return { word: 'Decline', notice: '≤$' + Math.floor(pay * 60 / (summary.appMinutes - creditMinutes) / 100) + '/hr · Decline' };
    }
    if (known && pay * 1000 >= s.centsPerMile * 2 * outbound) {
      // No number here: the worst-case floor (pay ÷ 2 × app miles) read as the real rate and confused the user (Oct 14).
      return { word: 'LikelyAccept', notice: 'Likely Accept · checking return' };
    }
    const max = Math.floor(pay * 1000 / s.centsPerMile) - outbound + credit;
    return { word: 'Conditional', notice: 'Accept if return ≤ ' + miles1(max) + ' mi' };
  }
  /* Stage 2: send a second notification only when the refined verdict changes the recommendation (roadmap §3). */
  function shouldUpdate(prelimWord, refinedNotice) {
    const word = /· Decline$/.test(refinedNotice) ? 'Decline' : /· Close call$/.test(refinedNotice) ? 'Close call'
      : /· Accept( \(time unknown\))?$/.test(refinedNotice) ? 'Accept' : 'Conditional';
    if (prelimWord === 'Decline') return false; // Already certain.
    if (prelimWord === 'LikelyAccept') return word === 'Decline' || word === 'Close call';
    return word !== 'Conditional'; // The preliminary had no verdict; the refined one does.
  }

  /* What a delivery app's screen shows about the order (user's labeled screenshots, Oct 15 2026):
   * 'available' (waiting for offers), 'offer', 'heading_to_store', 'at_store', 'heading_to_customer', 'at_customer',
   * 'delivered', or 'navigating' (turn-by-turn map: store or customer can't be told apart). Null when the screen isn't
   * recognized (cameras, other apps). Returns only the app, the state, and — where the screen names it — the store;
   * never customer names or addresses. Rules are checked in order; the first match wins. */
  const STATUS_RULES = [
    // DoorDash
    { platform: 'doordash', state: 'delivered', all: [/This dash so far|Continue dashing/i] },
    { platform: 'doordash', state: 'available', all: [/Finding offers|Zone offer wait|Move toward a hotspot/i] },
    { platform: 'doordash', state: 'at_customer', all: [/^Drop off order$|Take dropoff photo|Handed to customer|order before drop-off/i] },
    { platform: 'doordash', state: 'at_store', all: [/^Pick up order$|^Scan receipt$|Scan customer name|^Verify items$|Report lon[gq][- ]?wait|^Start scanning$|^Start pickup$/i] },
    { platform: 'doordash', state: 'heading_to_customer', all: [/^Deliver by\b/i, /^(Navigate|Arrived)$/i] },
    { platform: 'doordash', state: 'heading_to_store', all: [/^Pick up by\b/i, /^Navigate$/i] },
    // Retail / multi-order pickup card (Oct 15 2026): "Pick up by", the store, its address, "Continue".
    { platform: 'doordash', state: 'heading_to_store', all: [/^Pick up by\b/i, /^Continue$/i] },
    { platform: 'doordash', state: 'navigating', all: [/^Exit$/i, /Arriving soon|^Resume$|\bmi\s*•\s*\d{1,2}:\d{2}/i] },
    // Grubhub
    { platform: 'grubhub', state: 'delivered', all: [/marked as delivered/i] },
    { platform: 'grubhub', state: 'at_customer', all: [/^Drop off photo$|^Mark delivered$|^Take drop-off photo$/i] },
    { platform: 'grubhub', state: 'at_store', all: [/Confirm correct order|Upload receipt photo|^Confirm order photo$|^Get orders$|^Leaving$/i] },
    { platform: 'grubhub', state: 'at_store', all: [/^Pick up$/i, /^Standard Order$/i] },
    { platform: 'grubhub', state: 'heading_to_customer', any: [[/^Next Task$/i, /^Dropoff$/i], [/^\d{1,2}:\d{2}\s*[ap]m dropoff$/i],
      [/^Arrived$/i, /Contact-free|Driving Navigation/i]] },
    { platform: 'grubhub', state: 'heading_to_store', any: [[/^Next Task$/i, /^Pickup$/i], [/^\d{1,2}:\d{2}\s*[ap]m pickup$/i],
      [/^Pick up (by|at)\b/i, /^Arriving at$/i]] },
    { platform: 'grubhub', state: 'available', all: [/No upcoming tasks|hot spot - more red/i] },
    { platform: 'grubhub', state: 'navigating', all: [/^Arriving at$/i] },
    // Uber Eats (more screens from the user's Oct 16 shift: receipt photo, "Complete pickup", "I delivered the order",
    // and the navigation bar "5 min · 2.2 mi / <store>" on the way to the store — the evidence of an accept).
    { platform: 'uber_eats', state: 'at_customer', all: [/Info to share with|Where did you leave the order|^I delivered the order$/i] },
    { platform: 'uber_eats', state: 'at_store', all: [/^Take receipt photo$|^Take photo of receipt$|^Complete pickup$/i] },
    { platform: 'uber_eats', state: 'at_store', all: [/^Not a receipt$/i, /Retake/i] },
    { platform: 'uber_eats', state: 'heading_to_customer', all: [/^Deliver to\b/i] },
    { platform: 'uber_eats', state: 'heading_to_store', test: lines => uberNavStore(lines) !== null },
    { platform: 'uber_eats', state: 'available', all: [/^Hello, /i, /Gold|Platinum|Diamond|Uber Pro/i] }
  ];

  function readStatus(rawLines) {
    const lines = normalizeLines(rawLines);
    const offer = readScreen(rawLines);
    if (offer.kind === 'offer') return { platform: offer.platform, state: 'offer', store: null };
    if (lines.some(l => /^Early look\b|Early look • Order in progress/i.test(l.text))) return { platform: 'uber_eats', state: 'offer', store: null };
    const has = re => lines.some(l => re.test(l.text));
    const rule = STATUS_RULES.find(r => (r.test ? r.test(lines) : r.all ? r.all.every(has) : r.any.some(group => group.every(has))));
    if (!rule) return null;
    return { platform: rule.platform, state: rule.state, store: statusStore(lines, rule) };
  }

  /* Uber's navigation bar at the bottom: "5 min" and "2.2 mi" side by side, then where to. Returns that line when it's
   * a store (not "Deliver to …"), else null. OCR may read the digits as I/O ("IO min") or add an icon glyph ("0 1.4 mi"). */
  function uberNavStore(lines) {
    const minutes = lines.find(l => l.y > 0.75 && /^[\dIOl]{1,3} ?min$/.test(l.text));
    if (!minutes) return null;
    const miles = lines.find(l => Math.abs(l.y - minutes.y) < 0.02 && l !== minutes && /(^|\s)\d{1,3}(\.\d)? ?mi$/.test(l.text));
    if (!miles) return null;
    const next = lines.filter(l => l.y > minutes.y + 0.01 && l.y < minutes.y + 0.08).sort((a, b) => a.y - b.y)[0];
    if (!next || /^Deliver to\b/i.test(next.text) || !/[A-Za-z]{2}/.test(next.text)) return null;
    return next.text;
  }

  /* The store's name where the screen shows it as a business: Grubhub's "Pick up from/at <store>" (or "Pick up" above
   * it), and DoorDash's heading-to-store card (store under "Pick up by"). Never taken where a customer name could be. */
  function statusStore(lines, rule) {
    // "Name1000034024 R" is DoorDash's customer/order label on multi-order pickups: never a store.
    const store = text => (text && !isAddress(text) && /[A-Za-z]{2}/.test(text) && !/^(Pick up|Instructions|There are|Driving)/i.test(text)
      && !/[A-Za-z]\d{5,}/.test(text) ? text.slice(0, 80) : null);
    // Grubhub names the store only on pickup screens; on the drop-off screen "Pick up from" is followed by other
    // labels ("Order placed", Oct 16 screenshots), so nothing is taken there.
    if (rule.platform === 'grubhub' && rule.state !== 'at_store' && rule.state !== 'heading_to_store') return null;
    if (rule.platform === 'grubhub') {
      const inline = lines.map(l => /^Pick up (?:from|at) (.+)$/i.exec(l.text)).find(m => m && !/^\d/.test(m[1]));
      if (inline) return store(inline[1]);
      const label = lines.find(l => /^Pick up(?: from)?$/i.test(l.text));
      return label ? store(below(lines, label)[0] && below(lines, label)[0].text) : null;
    }
    if (rule.platform === 'uber_eats' && rule.state === 'heading_to_store') return store(uberNavStore(lines));
    if (rule.platform === 'uber_eats' && rule.state === 'at_store') {
      // "Arriving soon" / <store> on the pickup sheet; the receipt screen leads with the customer, so no store there.
      const arriving = lines.find(l => /^Arriving soon$/i.test(l.text));
      const next = arriving && below(lines, arriving)[0];
      return next ? store(next.text) : null;
    }
    if (rule.platform === 'doordash' && rule.state === 'heading_to_store') {
      const by = lines.find(l => /^Pick up by\b/i.test(l.text));
      const next = by && below(lines, by);
      if (!next || !next[0]) return null;
      // Long names wrap: "Shake Shack (Main" / "Street 12)".
      let joined = next[1] && /\($/.test(next[0].text.replace(/\([^)]*$/, '(')) && /\)$/.test(next[1].text) ? next[0].text + ' ' + next[1].text : next[0].text;
      // The retail card's large title wraps over up to four lines ("Community" / "Food Bank" / …)
      // until the street address; only on that card ("Continue"), so nothing else is swallowed.
      if (lines.some(l => /^Continue$/i.test(l.text))) {
        const parts = [next[0]];
        for (const l of next.slice(1, 4)) {
          const prev = parts[parts.length - 1];
          if (/^\d/.test(l.text) || /^Continue$/i.test(l.text) || l.y - prev.y > Math.max(0.07, prev.h * 3)) break;
          parts.push(l);
        }
        joined = parts.map(l => l.text).join(' ');
      }
      return store(joined);
    }
    return null;
  }

  const api = { READER_VERSION, VERSIONS, VERIFIED_LAYOUTS, readScreen, readStatus, trackSightings, toOffer, verdict, summarize, withReturn, preliminary, shouldUpdate, slug, hash,
    preliminaryJSON: (summaryJSON, contextJSON, settingsJSON) =>
      JSON.stringify(preliminary(JSON.parse(summaryJSON), JSON.parse(contextJSON || '{}'), root.Copilot, JSON.parse(settingsJSON || '{}'))),
    readStatusJSON: linesJSON => JSON.stringify(readStatus(JSON.parse(linesJSON))),
    summarizeJSON: (linesJSON, settingsJSON, optionsJSON) => JSON.stringify(summarize(JSON.parse(linesJSON), root.Copilot,
      JSON.parse(settingsJSON || '{}'), optionsJSON ? JSON.parse(optionsJSON) : {})),
    withReturnJSON: (summaryJSON, routeJSON, settingsJSON) =>
      JSON.stringify(withReturn(JSON.parse(summaryJSON), JSON.parse(routeJSON), root.Copilot, JSON.parse(settingsJSON || '{}'))) };
  root.ScreenReader = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
