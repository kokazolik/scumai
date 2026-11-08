import sys, os, subprocess, time
import numpy as np
from scipy.io import wavfile
import pyloudnorm as pyln
from synth import SR, master
from songs import SONGS
out_dir = sys.argv[1]
names = sys.argv[2:] or list(SONGS)
os.makedirs(out_dir, exist_ok=True)
for name in names:
    t0 = time.time()
    x, loop = SONGS[name]()
    goal = -16.0 if name != "victory" else -15.0
    raw = x; tgt = -18.0
    for _ in range(3):
        x = master(raw, loop=loop, target_rms_db=tgt)
        tgt += goal - pyln.Meter(SR).integrated_loudness(x.T)
    pk = np.max(np.abs(x)); dc = x.mean(axis=1)
    lufs = pyln.Meter(SR).integrated_loudness(x.T)
    d = np.abs(np.diff(x, axis=1)); seam = np.abs(x[:, 0] - x[:, -1]).max()
    # silence gaps: longest run of 0.5s windows below -50 dBFS
    mono = x.mean(0); w = SR // 2
    rms = np.array([np.sqrt(np.mean(mono[i:i+w]**2)) for i in range(0, len(mono)-w, w)])
    quiet = int(np.sum(20*np.log10(rms+1e-9) < -45))
    print(f"{name}: {x.shape[1]/SR:.2f}s peak={20*np.log10(pk):.2f}dB dc={dc.round(5)} lufs={lufs:.1f} "
          f"seam={seam:.4f} (p99 step={np.percentile(d,99):.4f}, max step={d.max():.3f}) quiet_windows={quiet} [{time.time()-t0:.0f}s]")
    wav = f"{out_dir}/{name}.wav"
    wavfile.write(wav, SR, (x.T * 32767).astype(np.int16))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "libvorbis", "-q:a", "1", f"{out_dir}/{name}.ogg"], check=True)
    print("   ogg", os.path.getsize(f"{out_dir}/{name}.ogg")//1024, "KB")
