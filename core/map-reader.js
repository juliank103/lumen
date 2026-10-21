/* Shared verbatim by Node and iOS JavaScriptCore. No network, filesystem, or DOM.
 * Reads the offer card's map when the card shows no drop-off address: finds the drop-off pins in the map pixels,
 * lines the map up with the real world using town names printed on it (looked up by the caller), and converts the
 * pins to coordinates. Pixels and coordinates are used transiently and never stored. */
(function (root) {
  'use strict';
  const MILES_PER_RADIAN = 3958.8;
  // Stamped on journaled predictions (addendum §9); bump when pin/label/fit logic changes.
  const VERSION = 'map-2026-10-21'; // build 23: phone-anchored dot, geographic pickup pin, route-scaled fit

  // Pin styles seen in the user's screenshots (October 2026). anchorBelow: pin tip/anchor below the disc center, in radii.
  const STYLES = {
    doordash: { anchorBelow: 1.45, disc: (r, g, b) => r >= 225 && g >= 225 && b >= 225 },
    grubhub: { anchorBelow: 0, disc: (r, g, b) => r >= 215 && g >= 215 && b >= 215 },
    uber_eats_dark: { anchorBelow: 2.2, disc: (r, g, b) => r >= 165 && r <= 238 && Math.max(r, g, b) - Math.min(r, g, b) <= 20 },
    uber_eats_light: { anchorBelow: 2.2, disc: (r, g, b) => Math.max(r, g, b) <= 50 }
  };
  const isBlueDot = (r, g, b) => b >= 200 && r <= 110 && g >= 90 && g <= 180;

  function decodeBase64(text) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const lookup = new Uint8Array(128);
    for (let i = 0; i < alphabet.length; i++) lookup[alphabet.charCodeAt(i)] = i;
    const clean = text.replace(/[^A-Za-z0-9+/]/g, '');
    const out = new Uint8Array(Math.floor(clean.length * 3 / 4));
    let o = 0;
    for (let i = 0; i + 1 < clean.length; i += 4) {
      const a = lookup[clean.charCodeAt(i)], b = lookup[clean.charCodeAt(i + 1)];
      const c = i + 2 < clean.length ? lookup[clean.charCodeAt(i + 2)] : 0, d = i + 3 < clean.length ? lookup[clean.charCodeAt(i + 3)] : 0;
      const n = (a << 18) | (b << 12) | (c << 6) | d;
      if (o < out.length) out[o++] = (n >> 16) & 255;
      if (o < out.length && i + 2 < clean.length) out[o++] = (n >> 8) & 255;
      if (o < out.length && i + 3 < clean.length) out[o++] = n & 255;
    }
    return out;
  }

  /* image: { width, height, data: RGBA bytes } of the map region; region: { top, height } as fractions of the screen;
   * aspect = screen height / width. Returns pins in screen-normalized coordinates (same as OCR lines). */
  function findPins(image, platform, region, aspect) {
    const W = image.width, H = image.height, px = image.data;
    if (!(W > 10 && H > 10 && px.length >= W * H * 4)) throw new Error('Invalid map image');
    let luminance = 0;
    for (let i = 0; i < W * H; i += 7) luminance += 0.299 * px[i * 4] + 0.587 * px[i * 4 + 1] + 0.114 * px[i * 4 + 2];
    const dark = luminance / Math.ceil(W * H / 7) < 128;
    const styleName = platform === 'uber_eats' ? (dark ? 'uber_eats_dark' : 'uber_eats_light') : platform;
    const style = STYLES[styleName];
    if (!style) return { pins: [], currentLocation: null, styleName };
    const mask = new Uint8Array(W * H), green = new Uint8Array(W * H), blue = new Uint8Array(W * H);
    for (let i = 0; i < W * H; i++) {
      const r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
      if (style.disc(r, g, b)) mask[i] = 1;
      if (isUberGreen(r, g, b)) green[i] = 1;
      if (isBlueDot(r, g, b)) blue[i] = 1;
    }
    const dot = currentLocationDot(blue, W, H);
    const toScreen = (x, y) => ({ x: x / W, y: region.top + (y / H) * region.height });
    const asPins = discs => discs.map(d => {
      const center = toScreen(d.x, d.y), anchor = toScreen(d.x, Math.min(H - 1, d.y + style.anchorBelow * d.r));
      const pin = { x: anchor.x, y: anchor.y, centerX: center.x, centerY: center.y, radius: d.r / W };
      if (platform === 'doordash') { pin.kind = iconKind(px, W, H, d); if (d.iconRatio !== undefined) pin.iconRatio = d.iconRatio; }
      return pin;
    });
    const pins = asPins(detectDiscs(mask, W, H));
    // Uber pickups are green pins; they are not drop-offs, but they anchor the map when the address is known.
    const pickupPins = platform === 'uber_eats' ? asPins(detectDiscs(green, W, H)) : [];
    const currentLocation = dot ? toScreen(dot.x, dot.y) : null;
    return { pins, pickupPins, currentLocation, styleName, aspect };
  }

  /* DoorDash draws a storefront in store pins and a person in drop-off pins (Oct 21 screenshots, maps read at 400 px):
   * the person icon is taller than wide (0.71–0.80), the storefront about square (1.00–1.08). 'store', 'customer', or
   * null when unclear, so a pin is never guessed. */
  function iconKind(px, W, H, d) {
    let minX = Infinity, maxX = -1, minY = Infinity, maxY = -1, n = 0;
    const r = d.r * 0.72;
    for (let y = Math.floor(d.y - r); y <= d.y + r; y++) {
      for (let x = Math.floor(d.x - r); x <= d.x + r; x++) {
        if (x < 0 || y < 0 || x >= W || y >= H || (x - d.x) * (x - d.x) + (y - d.y) * (y - d.y) > r * r) continue;
        const i = (y * W + x) * 4;
        if (0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2] >= 110) continue;
        n++; if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y;
      }
    }
    if (n < 12 || d.r < 9) return null; // Too small to see (a coarse map image).
    const ratio = (maxX - minX + 1) / (maxY - minY + 1);
    d.iconRatio = Math.round(ratio * 100) / 100; // Kept with the pin for the collected reading data.
    return ratio >= 0.92 ? 'store' : ratio <= 0.85 ? 'customer' : null;
  }

  /* The driver's blue dot: a filled, roughly round blue blob. Outlined blue icons (Mapbox's "i") and thin blue
   * shapes are rejected by how much of their bounding box they fill. */
  function currentLocationDot(blue, W, H) {
    const seen = new Uint8Array(W * H), stack = [];
    let best = null;
    for (let start = 0; start < W * H; start++) {
      if (!blue[start] || seen[start]) continue;
      let n = 0, sx = 0, sy = 0, minX = W, maxX = 0, minY = H, maxY = 0;
      stack.push(start); seen[start] = 1;
      while (stack.length) {
        const i = stack.pop(), x = i % W, y = (i / W) | 0;
        n++; sx += x; sy += y; if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y;
        for (const j of [i - 1, i + 1, i - W, i + W]) if (j >= 0 && j < W * H && blue[j] && !seen[j] && Math.abs((j % W) - x) <= 1) { seen[j] = 1; stack.push(j); }
      }
      const bw = maxX - minX + 1, bh = maxY - minY + 1, size = Math.max(bw, bh);
      const fill = n / (bw * bh), round = Math.min(bw, bh) / size;
      if (size < 0.012 * W || size > 0.06 * W || fill < 0.55 || round < 0.7) continue;
      if (!best || n > best.n) best = { n, x: sx / n, y: sy / n };
    }
    return best;
  }
  const isUberGreen = (r, g, b) => g >= 90 && g <= 170 && g - r >= 50 && g - b >= 25;

  // Round blobs of the mask (icons inside them filled first), largest first, as { x, y, r } in pixels.
  function detectDiscs(mask, W, H) {
    fillSmallHoles(mask, W, H, Math.PI * Math.pow(0.07 * W, 2));
    const dist = chamfer(mask, W, H);
    const rMin = 0.022 * W, rMax = 0.075 * W;
    const candidates = [];
    for (let y = 1; y < H - 1; y++) for (let x = 1; x < W - 1; x++) {
      const d = dist[y * W + x] / 3;
      if (d < rMin || d > rMax) continue;
      let peak = true;
      for (let dy = -1; dy <= 1 && peak; dy++) for (let dx = -1; dx <= 1; dx++) if (dist[(y + dy) * W + x + dx] > dist[y * W + x]) { peak = false; break; }
      if (peak) candidates.push({ x, y, r: d });
    }
    candidates.sort((a, b) => b.r - a.r);
    const discs = [];
    for (const c of candidates) {
      if (discs.some(d => Math.hypot(d.x - c.x, d.y - c.y) < 1.5 * Math.max(d.r, c.r))) continue;
      if (c.x - c.r < 1 || c.x + c.r > W - 2 || c.y - c.r < 1) continue; // Cut off by the edge.
      // Round: inside filled, and mostly background just outside (a stem, tip, or route may touch one side).
      let inside = 0, outside = 0;
      for (let k = 0; k < 16; k++) {
        const t = k * Math.PI / 8, cx = Math.cos(t), cy = Math.sin(t);
        const ix = Math.round(c.x + cx * c.r * 0.8), iy = Math.round(c.y + cy * c.r * 0.8);
        const ox = Math.round(c.x + cx * c.r * 1.35), oy = Math.round(c.y + cy * c.r * 1.35);
        if (ix >= 0 && iy >= 0 && ix < W && iy < H && mask[iy * W + ix]) inside++;
        if (ox < 0 || oy < 0 || ox >= W || oy >= H || !mask[oy * W + ox]) outside++;
      }
      // A map button may cover part of a pin's edge, so a few inside samples may miss.
      if (inside >= 13 && outside >= 9) discs.push(c);
    }
    return discs;
  }

  // Marks enclosed background regions smaller than maxArea (pin icons) as part of the mask.
  function fillSmallHoles(mask, W, H, maxArea) {
    const seen = new Uint8Array(W * H), stack = [];
    for (let start = 0; start < W * H; start++) {
      if (mask[start] || seen[start]) continue;
      const region = []; let touchesEdge = false;
      stack.push(start); seen[start] = 1;
      while (stack.length) {
        const i = stack.pop(); region.push(i);
        const x = i % W, y = (i / W) | 0;
        if (x === 0 || y === 0 || x === W - 1 || y === H - 1) touchesEdge = true;
        if (x > 0 && !mask[i - 1] && !seen[i - 1]) { seen[i - 1] = 1; stack.push(i - 1); }
        if (x < W - 1 && !mask[i + 1] && !seen[i + 1]) { seen[i + 1] = 1; stack.push(i + 1); }
        if (y > 0 && !mask[i - W] && !seen[i - W]) { seen[i - W] = 1; stack.push(i - W); }
        if (y < H - 1 && !mask[i + W] && !seen[i + W]) { seen[i + W] = 1; stack.push(i + W); }
      }
      if (!touchesEdge && region.length <= maxArea) region.forEach(i => { mask[i] = 1; });
    }
  }

  // 3-4 chamfer distance (×3) from each mask pixel to the nearest non-mask pixel.
  function chamfer(mask, W, H) {
    const big = 1 << 20, d = new Int32Array(W * H);
    for (let i = 0; i < W * H; i++) d[i] = mask[i] ? big : 0;
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const i = y * W + x; if (!d[i]) continue;
      if (x > 0) d[i] = Math.min(d[i], d[i - 1] + 3);
      if (y > 0) {
        d[i] = Math.min(d[i], d[i - W] + 3);
        if (x > 0) d[i] = Math.min(d[i], d[i - W - 1] + 4);
        if (x < W - 1) d[i] = Math.min(d[i], d[i - W + 1] + 4);
      }
      if (x === 0 || y === 0 || x === W - 1 || y === H - 1) d[i] = Math.min(d[i], 3);
    }
    for (let y = H - 1; y >= 0; y--) for (let x = W - 1; x >= 0; x--) {
      const i = y * W + x; if (!d[i]) continue;
      if (x < W - 1) d[i] = Math.min(d[i], d[i + 1] + 3);
      if (y < H - 1) {
        d[i] = Math.min(d[i], d[i + W] + 3);
        if (x < W - 1) d[i] = Math.min(d[i], d[i + W + 1] + 4);
        if (x > 0) d[i] = Math.min(d[i], d[i + W - 1] + 4);
      }
    }
    return d;
  }

  const UI_WORDS = /^(Accept|Decline|Reject|Uber|Dasher|Chrome|mapbox|Delivery|Exclusive|Pickup|Route|Back)$/i;
  // Streets and a few non-place words. Lake/Woods/Park are not here: Franklin, Springfield, Salem, Oakdale
  // Woods, and Ashland are towns; the Apple Maps lookup (towns only) rejects real lakes and parks.
  const STREET = /\b(Rd|Road|Ave|Avenue|St|Street|Dr|Drive|Blvd|Ln|Lane|Ct|Hwy|Highway|Pkwy|Tollway|Expy|Way|Trl|Trail|Pl|Cir|Ter|Sq)\b\.?$|^[NSEW]\s|\b(Forest Preserve|Golf|Club|Mall|School|Airport)\b/i;
  /* Town-name labels on the map with their screen positions. Labels cut off by the screen edge are skipped. */
  function mapLabels(lines, region) {
    const inMap = lines.filter(l => l && typeof l.text === 'string' && [l.x, l.y, l.w, l.h].every(Number.isFinite) &&
      l.y >= region.top && l.y + l.h <= region.top + region.height);
    // Two-line labels ("Westfield of / Fairview", "MacArthur Woods / Forest Preserve") are neighborhoods or parks.
    const stacked = l => inMap.some(o => o !== l && Math.abs(o.y - l.y) < 1.8 * Math.max(o.h, l.h) && Math.abs(o.y - l.y) > 0.3 * l.h &&
      Math.abs((o.x + o.w / 2) - (l.x + l.w / 2)) < 0.5 * Math.max(o.w, l.w));
    // Grubhub prints town names in capitals ("NORTH BERGEN"), or with a dot marker that OCR reads as a letter or
    // symbol ("OFranklin", "•Riverside", "Milton°", "Georgetown o").
    const titleCase = t => /^[A-Z][A-Z '-]{3,}$/.test(t) ? t.toLowerCase().replace(/(^|[ '-])([a-z])/g, (m, s, c) => s + c.toUpperCase()) : t;
    const unmark = t => t.replace(/^(?:[•·°.,]\s*|[Oo0]\s?(?=[A-Z][a-z]))/, '').replace(/(?:\s*[•·°.,]|\s+[Oo0])$/, '');
    return inMap.filter(l => !stacked(l))
      .map(l => ({ text: titleCase(unmark(l.text.replace(/\s+/g, ' ').trim())), x: l.x + l.w / 2, y: l.y + l.h / 2, edge: l.x < 0.015 || l.x + l.w > 0.985 }))
      .filter(l => !l.edge && /^[A-Z][a-z]+(?:[ '-][A-Z][a-z]+){0,2}$/.test(l.text) && l.text.length >= 4 && !UI_WORDS.test(l.text) && !STREET.test(l.text))
      .filter((l, i, all) => all.findIndex(o => o.text === l.text) === i)
      .slice(0, 8).map(l => ({ text: l.text, x: l.x, y: l.y }));
  }

  const mercY = lat => Math.log(Math.tan(Math.PI / 4 + lat * Math.PI / 360));
  const latFromMercY = y => (2 * Math.atan(Math.exp(y)) - Math.PI / 2) * 180 / Math.PI;
  /* North-up Web Mercator fit: u = s·lonRad + a, v = −s·mercY + b, with u = x and v = y·aspect.
   * controls: [{ x, y, lat, lon, weight? }]. Drops the worst town label once if it disagrees. Returns null if unusable. */
  function fitMap(controls, aspect) {
    function solve(points) {
      if (points.length < 2) return null;
      let n = 0, sX = 0, sY = 0, sU = 0, sV = 0, sXX = 0, sYY = 0, sXU = 0, sYV = 0;
      points.forEach(p => {
        const w = p.weight || 1, X = p.lon * Math.PI / 180, Y = mercY(p.lat), u = p.x, v = p.y * aspect;
        n += w; sX += w * X; sY += w * Y; sU += w * u; sV += w * v; sXX += w * X * X; sYY += w * Y * Y; sXU += w * X * u; sYV += w * Y * v;
      });
      // Minimize Σw(sX+a−u)² + Σw(−sY+b−v)²; a and b eliminated analytically.
      const num = (sXU - sX * sU / n) - (sYV - sY * sV / n), den = (sXX - sX * sX / n) + (sYY - sY * sY / n);
      if (!(den > 0)) return null;
      const s = num / den, a = (sU - s * sX) / n, b = (sV + s * sY) / n;
      const residuals = points.map(p => Math.hypot(s * p.lon * Math.PI / 180 + a - p.x, -s * mercY(p.lat) + b - p.y * aspect));
      return { s, a, b, residuals, points };
    }
    let fit = solve(controls);
    if (fit && controls.length >= 3) {
      // Leave each town label out in turn (least squares spreads one bad label over all residuals); keep the
      // version that agrees clearly better. The restaurant anchor is never dropped.
      const worstOf = f => Math.max.apply(null, f.residuals);
      let best = null;
      controls.forEach((c, i) => {
        if ((c.weight || 1) > 1) return;
        const trial = solve(controls.filter((_, j) => j !== i));
        if (trial && trial.s > 0 && (!best || worstOf(trial) < worstOf(best))) best = trial;
      });
      if (best && worstOf(best) < worstOf(fit) / 3) fit = best;
    }
    if (!fit || !(fit.s > 0)) return null;
    const lat0 = fit.points.reduce((n, p) => n + p.lat, 0) / fit.points.length;
    const milesPerUnit = MILES_PER_RADIAN * Math.cos(lat0 * Math.PI / 180) / fit.s;
    const screenWidthMiles = milesPerUnit;
    if (screenWidthMiles < 1 || screenWidthMiles > 120) return null; // Not a plausible offer-map zoom.
    const rms = Math.sqrt(fit.residuals.reduce((n, r) => n + r * r, 0) / fit.residuals.length);
    return { s: fit.s, a: fit.a, b: fit.b, aspect, milesPerUnit, screenWidthMiles,
      residualMiles: rms * milesPerUnit, controlCount: fit.points.length };
  }
  function toLatLon(fit, point) {
    const lon = (point.x - fit.a) / fit.s * 180 / Math.PI;
    const lat = latFromMercY((fit.b - point.y * fit.aspect) / fit.s);
    return { lat, lon };
  }

  /* Drop-off pins: for DoorDash/Grubhub every white pin except the pickups, which are the ones whose anchors lie
   * nearest the driver's blue dot; for Uber, pickups are green and never detected. Returns screen points. */
  function dropoffPins(found, platform, pickupCount, dropoffCount) {
    let pins = found.pins.slice(), pickups = (found.pickupPins || []).slice();
    if (platform !== 'uber_eats' && pins.length > 1) {
      const from = found.currentLocation;
      // Pickups at one plaza can share a pin, so the card's drop-off count is the better guide when known.
      const fromDrops = Number.isSafeInteger(dropoffCount) && dropoffCount > 0 ? pins.length - dropoffCount : null;
      const count = Math.max(1, Math.min(fromDrops !== null && fromDrops >= 1 ? fromDrops : (pickupCount || 1), pins.length - 1));
      if (from) pins.sort((p, q) => Math.hypot(p.x - from.x, p.y - from.y) - Math.hypot(q.x - from.x, q.y - from.y));
      else return { pins: [], pickups: [], reason: 'Pickup and drop-off pins look alike and no current-location dot was found' };
      pickups = pins.slice(0, count);
      pins = pins.slice(count);
    }
    if (!pins.length) return { pins: [], pickups, reason: 'No drop-off pin found on the map' };
    return { pins: pins.map(p => ({ x: p.x, y: p.y })), pickups: pickups.map(p => ({ x: p.x, y: p.y })), reason: null };
  }

  const validPlace = p => !!p && Number.isFinite(p.lat) && Number.isFinite(p.lon);
  const nearestFirst = (start, points) => {
    const left = points.slice(), out = [];
    let at = start;
    while (left.length) {
      left.sort((p, q) => Math.hypot(p.x - at.x, p.y - at.y) - Math.hypot(q.x - at.x, q.y - at.y));
      at = left.shift(); out.push(at);
    }
    return out;
  };

  /* Which white pin is the restaurant (DoorDash/Grubhub pins look alike)? With the driver's dot anchored to the phone's
   * position and the restaurant's real coordinate, the true pickup pin is the one whose direction and distance from the
   * dot agree with the real geography: try each pin and keep the clearly best fit (oct 14: nearest-to-the-dot was wrong
   * when the driver passed the drop-offs on the way). Returns { index, fit } or null. */
  function choosePickupPin(found, controls, pickupPlace, outboundMilliMiles) {
    const out = Number.isSafeInteger(outboundMilliMiles) ? outboundMilliMiles / 1000 : null;
    const tries = found.pins.map((pin, index) => {
      const fit = fitMap(controls.concat([{ x: pin.x, y: pin.y, lat: pickupPlace.lat, lon: pickupPlace.lon, weight: 4 }]), found.aspect);
      if (!fit) return null;
      // The straight line (dot →) pickup → drop-offs cannot be much longer than the app's road miles. Without the dot
      // (hidden under a pin, Oct 21 screenshots) the pickup → drop-offs part alone still has to fit, and how well it
      // fits the miles tells two pins apart when the places alone can't (one town + the restaurant fit any pin).
      let mismatch = 0;
      if (out !== null) {
        const rest = found.pins.filter((_, j) => j !== index);
        const path = (found.currentLocation ? [found.currentLocation, pin] : [pin]).concat(nearestFirst(pin, rest));
        let units = 0;
        for (let k = 1; k < path.length; k++) units += Math.hypot(path[k].x - path[k - 1].x, (path[k].y - path[k - 1].y) * found.aspect);
        const miles = units * fit.milesPerUnit;
        if (miles > out * 1.15 + 0.3) return null;
        mismatch = Math.abs(miles * DETOUR - out) / out;
      }
      return { index, fit, mismatch };
    }).filter(Boolean).sort((p, q) => p.fit.residualMiles - q.fit.residualMiles || p.mismatch - q.mismatch);
    if (!tries.length) return null;
    const [best, second] = tries;
    if (best.fit.residualMiles > 0.6) return null;
    if (second && second.fit.residualMiles < best.fit.residualMiles * 1.6 + 0.05) {
      // The places fit both about as well: weigh in the trip miles too, and take the pin that's clearly best on both.
      if (out === null) return null;
      const score = t => t.fit.residualMiles + 0.5 * t.mismatch;
      const ranked = tries.slice().sort((p, q) => score(p) - score(q));
      if (score(ranked[1]) < score(ranked[0]) * 1.4) return null;
      return ranked[0];
    }
    return best;
  }

  /* Map scale from the trip itself when only one place is anchored (the dot): the straight path dot → pickups →
   * drop-offs is the app's road miles divided by a typical detour factor. Coarser than two anchors. */
  const DETOUR = 1.25;
  function routeScaleFit(found, anchor, pickups, drops, outboundMilliMiles) {
    if (!Number.isSafeInteger(outboundMilliMiles) || !found.currentLocation) return null;
    const path = [found.currentLocation].concat(nearestFirst(found.currentLocation, pickups)).concat(nearestFirst(pickups[pickups.length - 1] || found.currentLocation, drops));
    let units = 0;
    for (let k = 1; k < path.length; k++) units += Math.hypot(path[k].x - path[k - 1].x, (path[k].y - path[k - 1].y) * found.aspect);
    if (units < 0.05) return null;
    const milesPerUnit = outboundMilliMiles / 1000 / (units * DETOUR);
    if (milesPerUnit < 1 || milesPerUnit > 120) return null;
    const s = MILES_PER_RADIAN * Math.cos(anchor.lat * Math.PI / 180) / milesPerUnit;
    const a = anchor.x - s * anchor.lon * Math.PI / 180, b = anchor.y * found.aspect + s * mercY(anchor.lat);
    return { s, a, b, aspect: found.aspect, milesPerUnit, screenWidthMiles: milesPerUnit, residualMiles: 0, controlCount: 1, routeScaled: true };
  }

  /* End-to-end after the caller looked up the labels: labelPlaces = [{ text, lat, lon }] (unmatched labels omitted);
   * pickupPlace = { lat, lon } of the restaurant (its address, or its name searched near the driver);
   * extra = { current: phone { lat, lon }, dropoffCount, outboundMilliMiles }.
   * Returns drop-off coordinates with an uncertainty, or a reason. */
  function locateDropoffs(found, labels, labelPlaces, platform, pickupCount, pickupPlace, extra) {
    extra = extra || {};
    const controls = labels.map(l => {
      const place = labelPlaces.find(p => p.text === l.text);
      return validPlace(place) ? { x: l.x, y: l.y, lat: place.lat, lon: place.lon } : null;
    }).filter(Boolean);
    const labelCount = controls.length;
    // The driver's dot is where the phone is: a precise anchor when the phone's position is known.
    const dotAnchored = !!(found.currentLocation && validPlace(extra.current));
    if (dotAnchored) controls.push({ x: found.currentLocation.x, y: found.currentLocation.y, lat: extra.current.lat, lon: extra.current.lon, weight: 4 });
    let chosen, how;
    // DoorDash's icons say which pins are stores and which are drop-offs: no guessing (Oct 21).
    const stores = found.pins.filter(p => p.kind === 'store'), customers = found.pins.filter(p => p.kind === 'customer');
    if (platform === 'doordash' && stores.length && customers.length && stores.length + customers.length === found.pins.length) {
      const pick = stores.length > 1 && validPlace(pickupPlace) && controls.length >= 1
        ? choosePickupPin(Object.assign({}, found, { pins: stores }), controls, pickupPlace, null) : null;
      const pickup = pick ? stores[pick.index] : stores[0];
      chosen = { pins: customers.map(p => ({ x: p.x, y: p.y })), pickups: stores.map(p => ({ x: p.x, y: p.y })), reason: null };
      if (validPlace(pickupPlace) && (pick || stores.length === 1)) controls.push({ x: pickup.x, y: pickup.y, lat: pickupPlace.lat, lon: pickupPlace.lon, weight: 4 });
      how = 'pins told apart by their icons';
      return finish(found, chosen, controls, labelCount, how, dotAnchored, labels, extra);
    }
    const picked = platform !== 'uber_eats' && validPlace(pickupPlace) && found.pins.length > 1 && controls.length >= 1
      ? choosePickupPin(found, controls, pickupPlace, extra.outboundMilliMiles) : null;
    if (picked) {
      const pickup = found.pins[picked.index];
      let drops = found.pins.filter((_, j) => j !== picked.index);
      // A second pickup can show as its own pin: keep the card's drop-off count, farthest from the pickup.
      const wanted = Number.isSafeInteger(extra.dropoffCount) && extra.dropoffCount > 0 ? extra.dropoffCount : drops.length;
      drops = drops.sort((p, q) => Math.hypot(q.x - pickup.x, q.y - pickup.y) - Math.hypot(p.x - pickup.x, p.y - pickup.y)).slice(0, wanted);
      chosen = { pins: drops.map(p => ({ x: p.x, y: p.y })), pickups: [{ x: pickup.x, y: pickup.y }], reason: drops.length ? null : 'No drop-off pin found on the map' };
      controls.push({ x: pickup.x, y: pickup.y, lat: pickupPlace.lat, lon: pickupPlace.lon, weight: 4 });
      how = 'restaurant pin matched';
    } else {
      chosen = dropoffPins(found, platform, pickupCount, extra.dropoffCount);
      if (validPlace(pickupPlace) && chosen.pickups.length === 1 && platform === 'uber_eats') {
        controls.push({ x: chosen.pickups[0].x, y: chosen.pickups[0].y, lat: pickupPlace.lat, lon: pickupPlace.lon, weight: 4 });
      }
      how = 'pickup = pin nearest the dot';
    }
    return finish(found, chosen, controls, labelCount, how, dotAnchored, labels, extra);
  }

  /* Fit the map from the anchored places and turn the chosen pins into coordinates (shared by both ways of choosing). */
  function finish(found, chosen, controls, labelCount, how, dotAnchored, labels, extra) {
    // A short trace for the offer list, so a failure can be pinned to a step on the phone. Town names only.
    const debug = 'pins ' + found.pins.length + (found.currentLocation ? ', blue dot' : ', no blue dot') + (dotAnchored ? ' at phone position' : '') +
      '; labels ' + (labels.map(l => l.text).join('/') || 'none') + '; towns matched ' + labelCount + '; ' + how;
    if (!chosen.pins.length) return { dropoffs: [], reason: chosen.reason, debug };
    let fit = controls.length >= 2 ? fitMap(controls, found.aspect) : null;
    if (!fit && dotAnchored) fit = routeScaleFit(found, controls[controls.length - 1], chosen.pickups, chosen.pins, extra.outboundMilliMiles);
    if (!fit) return { dropoffs: [], reason: controls.length < 2 ? 'Fewer than two places on the map could be matched' : 'Places on the map did not line up', debug };
    // Town labels sit near, not exactly at, town centers; a trip-scaled map is coarser still.
    const uncertaintyMiles = fit.routeScaled
      ? Math.max(0.75, 0.3 * Math.max.apply(null, chosen.pins.map(p => Math.hypot(p.x - found.currentLocation.x, (p.y - found.currentLocation.y) * found.aspect))) * fit.milesPerUnit)
      : Math.max(labelCount ? 0.75 : 0.5, 2 * fit.residualMiles + 0.02 * fit.screenWidthMiles);
    // The driver's dot, when shown, gives the position for the "already driving back" credit.
    const current = found.currentLocation ? toLatLon(fit, found.currentLocation) : null;
    // Pickup pins too, so the caller can time the trip (here → pickup → drop-offs) with Apple Maps.
    return { dropoffs: chosen.pins.map(p => toLatLon(fit, p)), pickups: chosen.pickups.map(p => toLatLon(fit, p)), current,
      uncertaintyMiles, screenWidthMiles: fit.screenWidthMiles, reason: null,
      debug: debug + '; map ' + fit.screenWidthMiles.toFixed(1) + ' mi wide' + (fit.routeScaled ? ' (scaled from trip miles)' : '') };
  }

  const api = { VERSION, decodeBase64, findPins, mapLabels, fitMap, toLatLon, dropoffPins, locateDropoffs,
    // JSON bridge for the iPhone: pixels arrive as base64 RGBA.
    analyzeJSON: (pixelsBase64, width, height, platform, regionJSON, aspect, linesJSON) => {
      const region = JSON.parse(regionJSON);
      const found = findPins({ width, height, data: decodeBase64(pixelsBase64) }, platform, region, aspect);
      return JSON.stringify({ found, labels: mapLabels(JSON.parse(linesJSON), region) });
    },
    locateJSON: (analysisJSON, placesJSON, platform, pickupCount, pickupPlaceJSON, extraJSON) => {
      const analysis = JSON.parse(analysisJSON);
      return JSON.stringify(locateDropoffs(analysis.found, analysis.labels, JSON.parse(placesJSON), platform, pickupCount,
        pickupPlaceJSON ? JSON.parse(pickupPlaceJSON) : null, extraJSON ? JSON.parse(extraJSON) : {}));
    } };
  root.MapReader = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
