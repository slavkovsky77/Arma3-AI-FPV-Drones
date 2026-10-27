"""Records a scripted scene (default: the v1.2 showcase, tests/FPVShowcase.Altis) to an MP4 with game audio.

    python tests/record_showcase.py --out "D:/Recordings/FPV AI Drones"
    python tests/record_showcase.py --out "D:/Recordings/FPV AI Drones" --mission FPVOperatorZeus.Altis

Copies the mission into <Arma 3>/Missions, starts the game (same mods and profile as
run_tests.py), and records the screen (Desktop Duplication -> Media Foundation H.264)
and the default speakers (WASAPI loopback) from SHOWCASE|BEGIN to SHOWCASE|END in the
game's RPT. The SHOWCASE|SCENE times are written next to the video for cutting.

Keep the game in front and the PC alone while it runs: the capture records the
screen, and singleplayer pauses when the game loses focus.
Needs: ffmpeg on PATH, pip install PyAudioWPatch.
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import threading
import time
import wave

import pyaudiowpatch as pyaudio

ARMA = r"E:\SteamLibrary\steamapps\common\Arma 3"
MODS = r"!Workshop\@CBA_A3;x\FPV Drone Crocus With Settings;x\FPV_AI_Drones"
PROFILE = "vulcan420"
MISSION = "FPVShowcase.Altis"
HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(os.environ["LOCALAPPDATA"], "Arma 3")


def newest_rpt(since):
    files = [f for f in glob.glob(os.path.join(LOGS, "arma3_x64_*.rpt")) if os.path.getmtime(f) >= since]
    return max(files, key=os.path.getmtime) if files else None


class Audio(threading.Thread):
    """Loopback recording of the default output device into a WAV file."""

    def __init__(self, path):
        super().__init__(daemon=True)
        self.path = path
        self.stop_evt = threading.Event()
        self.started_at = None
        self.error = None

    def run(self):
        try:
            with pyaudio.PyAudio() as p:
                wasapi = p.get_host_api_info_by_type(pyaudio.paWASAPI)
                spk = p.get_device_info_by_index(wasapi["defaultOutputDevice"])
                lb = next(d for d in p.get_loopback_device_info_generator() if spk["name"] in d["name"])
                ch, rate = lb["maxInputChannels"], int(lb["defaultSampleRate"])
                # WASAPI loopback delivers nothing while the device is silent, which would
                # shift the audio against the video. Keep it busy with silence.
                keep = p.open(format=pyaudio.paInt16, channels=spk["maxOutputChannels"], rate=rate, output=True,
                              output_device_index=spk["index"])
                silence = b"\0" * (1024 * 2 * spk["maxOutputChannels"])

                def keep_alive():
                    while not self.stop_evt.is_set():
                        keep.write(silence)
                    keep.close()
                threading.Thread(target=keep_alive, daemon=True).start()
                with wave.open(self.path, "wb") as wf:
                    wf.setnchannels(ch)
                    wf.setsampwidth(2)
                    wf.setframerate(rate)
                    stream = p.open(format=pyaudio.paInt16, channels=ch, rate=rate, input=True,
                                    input_device_index=lb["index"], frames_per_buffer=1024)
                    self.started_at = time.time()
                    while not self.stop_evt.is_set():
                        wf.writeframes(stream.read(1024, exception_on_overflow=False))
                    stream.stop_stream()
                    stream.close()
                self.channels = ch
        except Exception as e:  # reported by the caller
            self.error = e


def start_video(path, fps, bitrate):
    """ffmpeg screen capture; returns (process, time of the first encoded frame)."""
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-stats", "-stats_period", "0.1",
           "-f", "lavfi", "-i", f"ddagrab=output_idx=0:framerate={fps}",
           "-vf", "hwdownload,format=bgra,format=nv12",
           "-c:v", "h264_mf", "-hw_encoding", "1", "-b:v", bitrate, "-g", str(fps * 2), "-y", path]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    first = {}

    def watch():
        buf = b""
        while True:
            c = proc.stderr.read(1)
            if not c:
                break
            buf = (buf + c)[-200:]
            if "t" not in first and b"frame=" in buf:
                first["t"] = time.time()
    threading.Thread(target=watch, daemon=True).start()
    deadline = time.time() + 15
    while "t" not in first and time.time() < deadline and proc.poll() is None:
        time.sleep(0.01)
    return proc, first.get("t")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="folder for the recording")
    ap.add_argument("--fps", type=int, default=60)
    ap.add_argument("--bitrate", default="45M")
    ap.add_argument("--keep-game", action="store_true", help="leave the game running afterwards")
    ap.add_argument("--mission", default=MISSION, help="scene folder in tests/, e.g. FPVOperatorZeus.Altis")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    video, audio_wav = os.path.join(args.out, f"raw_{stamp}.mp4"), os.path.join(args.out, f"raw_{stamp}.wav")
    mission = args.mission
    final = os.path.join(args.out, f"{mission.split('.')[0]}_{stamp}.mp4")

    dst = os.path.join(ARMA, "Missions", mission)
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, mission), dst)

    launched = time.time()
    game = subprocess.Popen([os.path.join(ARMA, "arma3_x64.exe"), f"-name={PROFILE}", f"-mod={MODS}", "-skipIntro",
                      "-noSplash", "-world=empty", f"-init=playMission['','{mission}',true]"], cwd=ARMA)
    print("game started, waiting for SHOWCASE|BEGIN ...", flush=True)

    rpt, pos, markers = None, 0, []
    proc = vstart = aud = None
    deadline = time.time() + 300
    while time.time() < deadline:
        rpt = rpt or newest_rpt(launched)
        if rpt:
            with open(rpt, "r", encoding="utf-8", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            for line in chunk.splitlines():
                if "SHOWCASE|" not in line and "Error in expression" not in line and "Warning Message:" not in line:
                    continue   # a "Warning Message" is a box on screen that pauses singleplayer
                print(line.strip(), flush=True)
                if "Error in expression" in line and proc is None:
                    # A broken scenario never reaches BEGIN - don't sit there for 5 minutes.
                    game.kill()
                    print("script error before recording started - stopped (see the RPT)")
                    return 1
                if "SHOWCASE|BEGIN" in line and proc is None:
                    aud = Audio(audio_wav)
                    aud.start()
                    proc, vstart = start_video(video, args.fps, args.bitrate)
                    print(f"recording (first frame {'ok' if vstart else 'NOT SEEN'})", flush=True)
                    deadline = time.time() + 300
                elif "SHOWCASE|SCENE|" in line and vstart:
                    markers.append({"scene": line.split("SHOWCASE|SCENE|")[1].split("|")[0], "t": round(time.time() - vstart, 2)})
                elif "SHOWCASE|END" in line and proc is not None:
                    deadline = 0
        time.sleep(0.05)

    if proc is None:
        print("never saw SHOWCASE|BEGIN - nothing recorded")
        if not args.keep_game:
            game.kill()
        return 1
    proc.stdin.write(b"q")
    proc.stdin.flush()
    proc.wait(timeout=60)
    aud.stop_evt.set()
    aud.join(timeout=10)
    if not args.keep_game:
        game.kill()   # only our game: other sessions may have Arma open too
    if aud.error or aud.started_at is None:
        print(f"audio failed: {aud.error} - keeping the silent video")
        shutil.copy(video, final)
    else:
        offset = vstart - aud.started_at   # > 0: audio started first, skip that much of it
        ch = getattr(aud, "channels", 2)
        pan = "pan=stereo|c0=c0|c1=c1" if ch > 2 else "anull"
        audio_in = ["-ss", f"{offset:.3f}", "-i", audio_wav] if offset >= 0 else ["-itsoffset", f"{-offset:.3f}", "-i", audio_wav]
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", video] + audio_in +
                       ["-map", "0:v", "-map", "1:a", "-c:v", "copy", "-af", pan, "-c:a", "aac", "-b:a", "256k",
                        "-shortest", "-y", final], check=True)
        print(f"audio offset {offset:+.3f}s")
    with open(os.path.splitext(final)[0] + "_scenes.json", "w") as f:
        json.dump(markers, f, indent=1)
    print("saved", final)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
