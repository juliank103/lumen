"""Pin detector: data, model, decoding — shared by train.py and export.

Input: the offer map exactly as the phone crops it (from the top of the map to where the card starts), resized to fit
IN_W x IN_H and padded at the bottom/right. Output: heatmaps at stride 4 for store, customer and the driver's dot, plus
sub-cell offsets (CenterNet). Marks come from the pin labeler (labels.json, screen-normalized head centers).
"""
import json, os, random
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

DATA = Path(os.environ.get('MELLODY_PINS', Path.home() / '__APP_NAME__ pin training'))
KINDS = ['store', 'customer', 'you']
IN_W, IN_H, STRIDE = 320, 384, 4
OUT_W, OUT_H = IN_W // STRIDE, IN_H // STRIDE
MAP_TOP = 0.055
PAD = (40, 44, 56)
# Pin head radius (fraction of screen width) and how far the pointer reaches below the head (in radii), per app —
# the same numbers as core/map-reader.js.
HEAD_RADIUS = {'doordash': 0.0525, 'uber_eats': 0.039, 'grubhub': 0.0325}
ANCHOR_BELOW = {'doordash': 1.45, 'uber_eats': 2.2, 'grubhub': 0}


def examples():
    meta = json.loads((DATA / 'meta.json').read_text(encoding='utf-8'))
    labels = json.loads((DATA / 'labels.json').read_text(encoding='utf-8'))
    out = []
    for id, label in sorted(labels.items()):
        if label.get('status') != 'marked' or id not in meta:
            continue
        out.append({'id': id, 'path': DATA / 'shots' / meta[id]['file'], 'app': label['app'], 'bottom': label['mapBottom'],
                    'pins': [(p['x'], p['y'], KINDS.index(p['kind'])) for p in label['pins'] if p['kind'] in KINDS],
                    'meta': meta[id]})
    return out


_cache = {}


def _image(ex):
    """The screenshot at 720 px wide (the model sees 320), kept in memory between epochs."""
    if ex['id'] not in _cache:
        image = Image.open(ex['path']).convert('RGB')
        _cache[ex['id']] = image.resize((720, round(720 * image.height / image.width)), Image.LANCZOS)
    return _cache[ex['id']]


def merge_stacked(pins, aspect, width_frac=0.012):
    """Two marks almost on top of each other are one icon marked twice (labeler guidance): keep one."""
    kept = []
    for p in pins:
        if not any(q[2] == p[2] and abs(q[0] - p[0]) < width_frac and abs(q[1] - p[1]) * aspect < width_frac for q in kept):
            kept.append(p)
    return kept


def crop_map(image, top, bottom):
    """Screen image -> (model input image, transform from screen-normalized coords to input pixels)."""
    W, H = image.size
    region = image.crop((0, int(H * top), W, int(H * bottom)))
    scale = min(IN_W / region.width, IN_H / region.height)
    w, h = max(1, round(region.width * scale)), max(1, round(region.height * scale))
    canvas = Image.new('RGB', (IN_W, IN_H), PAD)
    canvas.paste(region.resize((w, h), Image.BILINEAR), (0, 0))
    to_input = lambda x, y: (x * W * scale, (y * H - int(H * top)) * scale)
    return canvas, to_input, (w, h)


def build_sprites(items):
    """Practice-map pieces: every marked store/customer pin cut out of its screenshot (head disc + pointer, soft edge),
    by app. Pins with a neighbour too close are skipped so a piece never carries a second, unmarked pin."""
    sprites = {}
    for ex in items:
        image = _image(ex)
        W, H = image.size
        r = HEAD_RADIUS.get(ex['app'], 0.04) * W
        below = ANCHOR_BELOW.get(ex['app'], 0) * r
        for x, y, k in ex['pins']:
            if k == 2:
                continue
            cx, cy = x * W, y * H
            if any((ox, oy, ok) != (x, y, k) and abs(ox * W - cx) < 2.4 * r and -2.4 * r - below < oy * H - cy < 2.4 * r + below
                   for ox, oy, ok in ex['pins']):
                continue
            box = (int(cx - 1.25 * r), int(cy - 1.25 * r), int(cx + 1.25 * r) + 1, int(cy + 1.1 * r + below) + 1)
            if box[0] < 0 or box[1] < 0 or box[2] > W or box[3] > H:
                continue
            piece = image.crop(box).convert('RGBA')
            mask = Image.new('L', piece.size, 0)
            draw = ImageDraw.Draw(mask)
            ox, oy = cx - box[0], cy - box[1]
            draw.ellipse([ox - 1.12 * r, oy - 1.12 * r, ox + 1.12 * r, oy + 1.12 * r], fill=255)
            if below > 0:
                draw.polygon([(ox - 0.55 * r, oy + 0.6 * r), (ox + 0.55 * r, oy + 0.6 * r), (ox, oy + below + 0.35 * r)], fill=255)
            piece.putalpha(mask.filter(ImageFilter.GaussianBlur(1.0)))
            sprites.setdefault(ex['app'], []).append((piece, k, (ox, oy)))
    return sprites


def add_practice_pins(image, ex, top, bottom, rng, sprites):
    """Paste 1–3 real pins of the same app onto the map: anywhere, or overlapping a pin already there (the case that
    reads worst on zoomed-out maps). Returns the new image and the full mark list (screen-normalized)."""
    pool = sprites.get(ex['app']) or []
    pins = list(ex['pins'])
    if not pool:
        return image, pins
    image = image.copy()
    W, H = image.size
    r = HEAD_RADIUS.get(ex['app'], 0.04)
    for _ in range(rng.randint(1, 3)):
        piece, k, (ox, oy) = rng.choice(pool)
        targets = [p for p in pins if p[2] != 2]
        if targets and rng.random() < 0.45:  # overlap a pin: 0.6–1.3 head radii away, any direction
            tx, ty, _ = rng.choice(targets)
            angle, dist = rng.uniform(0, 6.283), rng.uniform(0.6, 1.3) * r
            x, y = tx + dist * np.cos(angle), ty + dist * np.sin(angle) * W / H
        else:
            x, y = rng.uniform(0.06, 0.94), rng.uniform(top + 0.03, bottom - 0.04)
        if not (0.03 < x < 0.97 and top + 0.02 < y < bottom - 0.03):
            continue
        if any(abs(px - x) < 0.5 * r and abs(py - y) * H / W < 0.5 * r for px, py, _ in pins):
            continue  # on top of another pin: one icon, ambiguous
        image.paste(piece, (int(x * W - ox), int(y * H - oy)), piece)
        pins.append((x, y, k))
    return image, pins


def sample(ex, rng=None, sprites=None):
    """Training view (rng) or the plain phone view (no rng). Returns float tensor 3xHxW (0-255), pins in input pixels."""
    if rng is None:
        image = _image(ex)
        W, H = image.size
        canvas, to_input, (w, h) = crop_map(image, MAP_TOP, ex['bottom'])
        pins = [(*to_input(x, y), k) for x, y, k in merge_stacked(ex['pins'], H / W)]
        pins = [p for p in pins if 0 <= p[0] < w and 0 <= p[1] < h]
    else:
        canvas, pins = _train_view(ex, rng, sprites)
    array = torch.from_numpy(np.asarray(canvas, dtype=np.float32).copy()).permute(2, 0, 1)
    return array, pins


def _train_view(ex, rng, sprites=None):
    image = _image(ex)
    W, H = image.size
    top = rng.uniform(0.03, 0.12) if rng.random() < 0.85 else rng.uniform(0.12, 0.2)
    bottom = min(0.8, max(top + 0.2, ex['bottom'] + rng.uniform(-0.05, 0.015)))
    marks = ex['pins']
    if sprites and rng.random() < 0.5:
        image, marks = add_practice_pins(image, ex, top, min(bottom, ex['bottom']), rng, sprites)
    zoom = rng.uniform(0.75, 1.0) if rng.random() < 0.5 else 1.0
    x0 = rng.uniform(0, 1 - zoom)
    sub = image.crop((int(W * x0), 0, int(W * (x0 + zoom)), H))
    canvas, to_input, (w, h) = crop_map(sub, top, bottom)
    pins = []
    for x, y, k in merge_stacked(marks, H / W):
        ix, iy = to_input((x - x0) / zoom, y)
        if 0 <= ix < w and 0 <= iy < h:
            pins.append((ix, iy, k))
    if rng.random() < 0.8:
        canvas = ImageEnhance.Brightness(canvas).enhance(rng.uniform(0.8, 1.2))
        canvas = ImageEnhance.Contrast(canvas).enhance(rng.uniform(0.8, 1.2))
        canvas = ImageEnhance.Color(canvas).enhance(rng.uniform(0.85, 1.15))
    if rng.random() < 0.3:
        canvas = canvas.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.0)))
    if rng.random() < 0.3:
        import io
        buffer = io.BytesIO()
        canvas.save(buffer, 'JPEG', quality=rng.randint(35, 80))
        canvas = Image.open(buffer).convert('RGB')
    flip = rng.random() < 0.5
    if flip:  # mirror only the map area; the padding stays at the right/bottom
        region = canvas.crop((0, 0, w, h)).transpose(Image.FLIP_LEFT_RIGHT)
        canvas.paste(region, (0, 0))
        pins = [(w - 1 - x, y, k) for x, y, k in pins]
    return canvas, pins


def targets(pins):
    heat = np.zeros((len(KINDS), OUT_H, OUT_W), np.float32)
    offset = np.zeros((2, OUT_H, OUT_W), np.float32)
    mask = np.zeros((OUT_H, OUT_W), np.float32)
    ys, xs = np.mgrid[0:OUT_H, 0:OUT_W]
    sigma = 1.6
    for x, y, k in pins:
        cx, cy = x / STRIDE, y / STRIDE
        ix, iy = min(OUT_W - 1, int(cx)), min(OUT_H - 1, int(cy))
        g = np.exp(-((xs - ix) ** 2 + (ys - iy) ** 2) / (2 * sigma ** 2))
        heat[k] = np.maximum(heat[k], g)
        offset[:, iy, ix] = (cx - ix, cy - iy)
        mask[iy, ix] = 1
    return torch.from_numpy(heat), torch.from_numpy(offset), torch.from_numpy(mask)


class PinNet(nn.Module):
    """MobileNetV3-small features (ImageNet-pretrained) + a small top-down path to stride 4."""

    def __init__(self, pretrained=True):
        super().__init__()
        from torchvision.models import mobilenet_v3_small, MobileNet_V3_Small_Weights
        f = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.IMAGENET1K_V1 if pretrained else None).features
        self.s4, self.s8, self.s16 = f[0:2], f[2:4], f[4:9]      # 16, 24, 48 channels
        self.l16, self.l8, self.l4 = nn.Conv2d(48, 64, 1), nn.Conv2d(24, 64, 1), nn.Conv2d(16, 64, 1)
        self.head = nn.Sequential(nn.Conv2d(64, 64, 3, padding=1), nn.ReLU(inplace=True))
        self.heat = nn.Conv2d(64, len(KINDS), 1)
        self.offset = nn.Conv2d(64, 2, 1)
        self.heat.bias.data.fill_(-2.2)
        self.register_buffer('mean', torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1) * 255)
        self.register_buffer('std', torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1) * 255)

    def forward(self, x):  # x: N x 3 x IN_H x IN_W, RGB 0-255
        x = (x - self.mean) / self.std
        a = self.s4(x); b = self.s8(a); c = self.s16(b)
        p = self.l16(c)
        p = F.interpolate(p, size=b.shape[-2:], mode='nearest') + self.l8(b)
        p = F.interpolate(p, size=a.shape[-2:], mode='nearest') + self.l4(a)
        p = self.head(p)
        return torch.sigmoid(self.heat(p)), self.offset(p)


def focal_loss(pred, gt):
    pred = pred.clamp(1e-4, 1 - 1e-4)
    pos = gt.eq(1).float()
    neg = 1 - pos
    pos_loss = torch.log(pred) * (1 - pred) ** 2 * pos
    neg_loss = torch.log(1 - pred) * pred ** 2 * (1 - gt) ** 4 * neg
    n = pos.sum().clamp(min=1)
    return -(pos_loss.sum() + neg_loss.sum()) / n


def decode(heat, offset, threshold=0.3):
    """Peaks -> [(x, y, kind, score)] in input pixels."""
    peaks = heat * (F.max_pool2d(heat, 3, 1, 1) == heat).float()
    out = []
    k, ys, xs = torch.nonzero(peaks[0] >= threshold, as_tuple=True)
    for kk, yy, xx in zip(k.tolist(), ys.tolist(), xs.tolist()):
        out.append(((xx + offset[0, 0, yy, xx].item()) * STRIDE, (yy + offset[0, 1, yy, xx].item()) * STRIDE, kk,
                    heat[0, kk, yy, xx].item()))
    # One icon, one pin: drop weaker peaks of another kind on the same spot.
    out.sort(key=lambda p: -p[3])
    kept = []
    for p in out:
        if not any(abs(p[0] - q[0]) < 8 and abs(p[1] - q[1]) < 8 for q in kept):
            kept.append(p)
    return kept


def predict(model, image, top, bottom, device='cpu'):
    """The model on one screenshot (any size): detections in screen-normalized coords [(x, y, kind, score)] and how
    unsure it is (sum over every peak above 0.1 of 1 − |2·score − 1|; high = worth marking first)."""
    W, H = image.size
    small = image.convert('RGB').resize((720, round(720 * H / W)), Image.LANCZOS)
    canvas, _, (w, h) = crop_map(small, top, bottom)
    region_h = int(small.height * bottom) - int(small.height * top)
    scale = min(IN_W / small.width, IN_H / region_h)
    x = torch.from_numpy(np.asarray(canvas, dtype=np.float32).copy()).permute(2, 0, 1).unsqueeze(0).to(device)
    with torch.no_grad():
        heat, offset = model(x)
    heat, offset = heat.cpu(), offset.cpu()
    loose = decode(heat, offset, threshold=0.1)
    hard = sum(1 - abs(2 * s - 1) for *_, s in loose) + (0 if any(k == 1 and s >= 0.3 for _, _, k, s in loose) else 1)
    found = [(px / scale / small.width, top + py / scale / small.height, KINDS[k], round(s, 3))
             for px, py, k, s in loose if s >= 0.3 and px < w and py < h]
    return found, round(hard, 3)

