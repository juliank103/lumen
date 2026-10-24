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
from PIL import Image, ImageEnhance, ImageFilter

DATA = Path(os.environ.get('MELLODY_PINS', Path.home() / '__APP_NAME__ pin training'))
KINDS = ['store', 'customer', 'you']
IN_W, IN_H, STRIDE = 320, 384, 4
OUT_W, OUT_H = IN_W // STRIDE, IN_H // STRIDE
MAP_TOP = 0.055
PAD = (40, 44, 56)


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


def sample(ex, rng=None):
    """Training view (rng) or the plain phone view (no rng). Returns float tensor 3xHxW (0-255), pins in input pixels."""
    if rng is None:
        image = _image(ex)
        W, H = image.size
        canvas, to_input, (w, h) = crop_map(image, MAP_TOP, ex['bottom'])
        pins = [(*to_input(x, y), k) for x, y, k in merge_stacked(ex['pins'], H / W)]
        pins = [p for p in pins if 0 <= p[0] < w and 0 <= p[1] < h]
    else:
        canvas, pins = _train_view(ex, rng)
    array = torch.from_numpy(np.asarray(canvas, dtype=np.float32).copy()).permute(2, 0, 1)
    return array, pins


def _train_view(ex, rng):
    image = _image(ex)
    W, H = image.size
    top = rng.uniform(0.03, 0.12) if rng.random() < 0.85 else rng.uniform(0.12, 0.2)
    bottom = min(0.8, max(top + 0.2, ex['bottom'] + rng.uniform(-0.05, 0.015)))
    zoom = rng.uniform(0.75, 1.0) if rng.random() < 0.5 else 1.0
    x0 = rng.uniform(0, 1 - zoom)
    sub = image.crop((int(W * x0), 0, int(W * (x0 + zoom)), H))
    canvas, to_input, (w, h) = crop_map(sub, top, bottom)
    pins = []
    for x, y, k in merge_stacked(ex['pins'], H / W):
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
