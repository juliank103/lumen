"""Convert the trained pin model to Core ML and compile it for the screen reader (runs on the macOS build machine).

    python tools/pin-model/convert.py tools/pin-model/pins.pt ios/Capture/PinDetector.mlmodelc

Input "map": 320x384 RGB image, 0-255 (the map crop, top-left aligned, padded). Outputs "heat" (1x3x96x80: store,
customer, you) and "offset" (1x2x96x80), decoded in PinDetector.swift.
"""
import shutil, subprocess, sys, tempfile
from pathlib import Path

import coremltools as ct
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pins as P


class Named(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, map):
        heat, offset = self.net(map)
        return heat, offset


def main(weights, out):
    net = P.PinNet(pretrained=False)
    net.load_state_dict(torch.load(weights, map_location='cpu'))
    model = Named(net).eval()
    example = torch.zeros(1, 3, P.IN_H, P.IN_W)
    traced = torch.jit.trace(model, example)
    ml = ct.convert(traced, inputs=[ct.ImageType(name='map', shape=example.shape, color_layout=ct.colorlayout.RGB, scale=1.0)],
                    outputs=[ct.TensorType(name='heat'), ct.TensorType(name='offset')],
                    minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
    ml.short_description = 'Finds store, customer and driver pins on delivery offer maps'
    with tempfile.TemporaryDirectory() as tmp:
        package = Path(tmp) / 'PinDetector.mlpackage'
        ml.save(str(package))
        subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(package), tmp], check=True)
        out = Path(out)
        shutil.rmtree(out, ignore_errors=True)
        shutil.copytree(Path(tmp) / 'PinDetector.mlmodelc', out)
    print('compiled', out)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
