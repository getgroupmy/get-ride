"""Fetches the two opencv_zoo models at image build time and checks each
one's sha256; any difference stops the build.

    python fetch_models.py <opencv_zoo models URL at a commit> <dir>
"""

import hashlib
import os
import sys
import urllib.request

MODELS = {
    "face_detection_yunet/face_detection_yunet_2023mar.onnx":
        "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
    "face_recognition_sface/face_recognition_sface_2021dec.onnx":
        "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
}


def main(base: str, out: str) -> None:
    os.makedirs(out, exist_ok=True)
    for path, want in MODELS.items():
        with urllib.request.urlopen(f"{base}/{path}", timeout=120) as r:
            data = r.read()
        got = hashlib.sha256(data).hexdigest()
        if got != want:
            sys.exit(f"{path}: sha256 {got}, expected {want}")
        target = os.path.join(out, os.path.basename(path))
        with open(target, "wb") as f:
            f.write(data)
        os.chmod(target, 0o444)
        print(f"{os.path.basename(path)}: ok ({len(data)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
