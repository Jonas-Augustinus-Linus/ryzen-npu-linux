#!/usr/bin/env python3
"""NPU camera daemon — capture video, let an XDNA1/XDNA2 NPU process every frame,
publish to the /dev/video10 virtual camera (usable by Zoom/Chrome/OBS).

Pipeline:  source -> appsink -(NPU)-> appsrc -> v4l2sink (/dev/video10)

The NPU runs a real 2D box blur per frame as two 128x128 i32 matmuls
(gray @ K, then K @ that) via libnpu.so — proving a working
camera -> NPU -> virtual-camera path at video rate. A real background blur
would swap this for a segmentation conv model (harder: shape/op constraints);
the plumbing here is identical.

Env:  CAM=/dev/video0 (real cam; default = videotestsrc),  OUT=/dev/video10,
      W, H, NPU_VMFB (i32 128x128 @matmul).
"""
import os
import sys
import time

import numpy as np

# Find the npu bridge (tools/npu-runner) relative to this file, or via env.
_RUNNER = os.environ.get(
    "NPU_RUNNER_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "npu-runner"))
sys.path.insert(0, os.path.abspath(_RUNNER))
from npu import NPU  # noqa: E402

import gi  # noqa: E402
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib  # noqa: E402

W = int(os.environ.get("W", 640))
H = int(os.environ.get("H", 480))
OUT = os.environ.get("OUT", "/dev/video10")
CAM = os.environ.get("CAM", "")
VMFB = os.environ.get("NPU_VMFB",
                      os.path.join(os.path.dirname(os.path.abspath(__file__)), "matmul.vmfb"))
NN = 128
WIN = 4  # blur half-window

# Banded averaging matrix K (128x128): K[k,j]=1 if |k-j|<=WIN. matmul with it
# blurs along one axis; doing it on both sides blurs in 2D.
_k = np.abs(np.subtract.outer(np.arange(NN), np.arange(NN))) <= WIN
K = _k.astype(np.int32)
NORM = (2 * WIN + 1) ** 2

# even sampling indices for crude (dependency-free) resize
_hd = (np.arange(NN) * H // NN)
_wd = (np.arange(NN) * W // NN)
_hu = (np.arange(H) * NN // H)
_wu = (np.arange(W) * NN // W)

npu = None
_frames = [0]
_t0 = [time.time()]
_loop = None
_fatal_error = None


def process(rgb):
    """rgb HxWx3 uint8 -> HxWx3 uint8, 2D-blurred on the NPU."""
    if npu is None:
        raise RuntimeError("NPU context is not open")
    gray = rgb.mean(2).astype(np.int32)            # HxW
    g = gray[_hd][:, _wd]                           # 128x128 (downscale)
    g = npu.matmul(g, K)                            # NPU: blur rows
    g = npu.matmul(K, g) // NORM                    # NPU: blur cols + requant
    g = np.clip(g, 0, 255).astype(np.uint8)
    up = g[_hu][:, _wu]                             # upscale to HxW
    return np.repeat(up[:, :, None], 3, axis=2)     # grayscale -> RGB


def on_sample(sink, appsrc):
    try:
        sample = sink.emit("pull-sample")
        if sample is None:
            raise RuntimeError("appsink returned no sample")
        buf = sample.get_buffer()
        ok, mi = buf.map(Gst.MapFlags.READ)
        if not ok:
            raise RuntimeError("could not map the input frame")
        try:
            frame = np.frombuffer(mi.data, np.uint8).reshape(H, W, 3).copy()
        finally:
            buf.unmap(mi)
        out = process(frame)
        flow = appsrc.emit("push-buffer", Gst.Buffer.new_wrapped(out.tobytes()))
        if flow != Gst.FlowReturn.OK:
            raise RuntimeError(f"virtual-camera output rejected a frame: {flow.value_nick}")
    except Exception as exc:
        fail_pipeline(f"frame processing failed: {exc}")
        return Gst.FlowReturn.ERROR
    _frames[0] += 1
    if _frames[0] % 60 == 0:
        dt = time.time() - _t0[0]
        print(f"[npu-camera] {_frames[0]} frames, {60/dt:.1f} fps (NPU 2 matmul/frame)", flush=True)
        _t0[0] = time.time()
    return Gst.FlowReturn.OK


def fail_pipeline(message):
    """Record the first asynchronous failure and stop the main loop."""
    global _fatal_error
    if _fatal_error is None:
        _fatal_error = message
        print(f"[npu-camera] ERROR: {message}", file=sys.stderr, flush=True)
    if _loop is not None:
        # The appsink callback runs on a streaming thread. Queue the quit on the
        # GLib context so a failure that arrives just before run() is not lost.
        GLib.idle_add(_loop.quit)


def on_bus_message(_bus, message):
    if message.type == Gst.MessageType.ERROR:
        error, debug = message.parse_error()
        detail = f": {debug}" if debug else ""
        fail_pipeline(f"GStreamer error from {message.src.get_name()}: {error}{detail}")
    elif message.type == Gst.MessageType.EOS:
        fail_pipeline(f"unexpected end of stream from {message.src.get_name()}")


def main():
    global npu, _loop, _fatal_error
    Gst.init(None)
    _fatal_error = None
    src = (f"v4l2src device={CAM}" if CAM else
           f"videotestsrc is-live=true pattern={os.environ.get('PATTERN', 'ball')}")
    inp = None
    outp = None
    try:
        npu = NPU(VMFB)
        inp = Gst.parse_launch(
            f"{src} ! videoconvert ! videoscale ! "
            f"video/x-raw,format=RGB,width={W},height={H} ! "
            f"appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false")
        outp = Gst.parse_launch(
            f"appsrc name=src is-live=true do-timestamp=true format=time "
            f"caps=video/x-raw,format=RGB,width={W},height={H},framerate=30/1 ! "
            f"videoconvert ! video/x-raw,format=YUY2 ! "
            f"v4l2sink device={OUT} sync=false")
        appsrc = outp.get_by_name("src")
        inp.get_by_name("sink").connect("new-sample", on_sample, appsrc)
        for pipeline in (inp, outp):
            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message", on_bus_message)

        _loop = GLib.MainLoop()
        if outp.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("could not start the virtual-camera output pipeline")
        if inp.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("could not start the capture pipeline")
        print(f"[npu-camera] source={'videotestsrc' if not CAM else CAM} -> NPU -> {OUT}",
              flush=True)
        _loop.run()
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        fail_pipeline(str(exc))
    finally:
        if inp is not None:
            inp.set_state(Gst.State.NULL)
        if outp is not None:
            outp.set_state(Gst.State.NULL)
        if npu is not None:
            npu.close()
            npu = None
        _loop = None
    return 1 if _fatal_error is not None else 0


if __name__ == "__main__":
    raise SystemExit(main())
