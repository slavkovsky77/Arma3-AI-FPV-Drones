"""Automated, watchable test runs for FPV AI Drones - singleplayer and multiplayer.

    python tests/run_tests.py                    # build, then singleplayer run, then multiplayer run
    python tests/run_tests.py --mode MP          # just multiplayer (local dedicated server + your client)
    python tests/run_tests.py --mode SP          # just singleplayer
    python tests/run_tests.py --keep-open        # leave the game running after the last run (e.g. to try Zeus)
    python tests/run_tests.py --no-build         # skip rebuilding the PBO
    python tests/run_tests.py --bench 3          # attack-speed bench only: parked tank + crossing car, 3 rounds (MP)
    python tests/run_tests.py --quick            # the attack-run stages 1, 2, 7, 10, 11
    python tests/run_tests.py --compat B_UAFPV B_UAFPV:PG7VL --extra-mods <path to @mod>
                                                 # another mod's drones: MOVE, MOVE, CYCLE loop, then an enemy car

Both modes play the same mission (tests/FPVTest.VR) with a chase camera, and
write results as FPV_TEST lines to the RPT, which this script follows. They
differ in where the drone AI runs relative to you: in SP your machine is the
server; in MP the drones live on a dedicated server and you are a client -
which is where locality bugs (Zeus placement, duplicated explosives) show up.

Only the mod's hard dependencies are loaded - no AI mods, which change how
drones behave and would muddy the results. --extra-mods adds others on purpose.
"""
import argparse
import ctypes
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
from ctypes import wintypes

user32 = ctypes.windll.user32

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
MISSION_SRC = os.path.join(HERE, "FPVTest.VR")
# CBA is required by the Crocus drone mod (ArmaFPV_Data -> cba_settings), not by FPV AI Drones itself.
MODS = [r"!Workshop\@CBA_A3", r"x\FPV Drone Crocus With Settings", r"x\FPV_AI_Drones"]   # relative to the game folder
WORK_DIR = os.path.join(os.environ["TEMP"], "fpv_ai_drones_test")   # server profile, config and RPT
CLIENT_LOGS = os.path.join(os.environ["LOCALAPPDATA"], "Arma 3")
PASSWORD = "fpvtest"
PORT = 2402   # off the default 2302
INTERESTING = re.compile(r"FPV_TEST\||FPV_AI_Drones:|Error in expression|Error position|Error Undefined|Error Type|Error Missing|Error Generic")

GREEN, RED, CYAN, GRAY, RESET = "\033[32m", "\033[31m", "\033[36m", "\033[90m", "\033[0m"
os.system("")   # turns on ANSI colours in the Windows console


def say(text, colour=""):
    print(f"{colour}{text}{RESET if colour else ''}", flush=True)


def running(image):
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {image}", "/NH", "/FO", "CSV"],
                         capture_output=True, text=True).stdout
    return image.lower() in out.lower()


def processes(image):
    """[(pid, command line)] for every process with this executable name."""
    ps = (f"Get-CimInstance Win32_Process -Filter \"Name = '{image}'\" | "
          "Select-Object ProcessId, CommandLine | ConvertTo-Json -Compress")
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout.strip()
    if not out:
        return []
    rows = json.loads(out)
    rows = rows if isinstance(rows, list) else [rows]
    return [(r["ProcessId"], r["CommandLine"] or "") for r in rows]


def kill(pid):
    subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    # taskkill returns before the process is gone; a back-to-back run then saw it
    # still alive and refused to start ("a server that isn't a test server").
    deadline = time.time() + 30
    while time.time() < deadline and str(pid) in subprocess.run(
            ["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True).stdout:
        time.sleep(0.5)


def stop_test_server():
    # Closing the game doesn't close the server console, so stop any left over -
    # but only servers running from our test profile directory.
    for pid, cmd in processes("arma3server_x64.exe"):
        if "fpv_ai_drones_test" in cmd:
            kill(pid)
            say(f"Stopped test server (pid {pid}).")


def stop_game():
    for pid, _ in processes("arma3_x64.exe"):
        kill(pid)
    time.sleep(3)


def udp_listening(port):
    out = subprocess.run(["netstat", "-ano", "-p", "UDP"], capture_output=True, text=True).stdout
    return re.search(rf":{port}\s", out) is not None


def game_window():
    """The game's main window handle, or None."""
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq arma3_x64.exe", "/NH", "/FO", "CSV"],
                         capture_output=True, text=True).stdout
    pids = {int(row.split('","')[1]) for row in out.splitlines() if row.lower().startswith('"arma3_x64.exe"')}
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def visit(hwnd, _):
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value in pids and user32.IsWindowVisible(hwnd) and user32.GetWindowTextLengthW(hwnd) > 0:
            found.append(hwnd)
        return True

    user32.EnumWindows(visit, 0)
    return found[0] if found else None


def focus_game():
    """Brings the game to the front. Singleplayer pauses while its window is in the background,
    and anything can take the focus mid-run - an editor opening a changed file, a notification."""
    hwnd = game_window()
    if not hwnd or user32.GetForegroundWindow() == hwnd:
        return
    # Windows only lets the foreground process hand the focus over; a key event makes this one count.
    user32.keybd_event(0x12, 0, 0, 0)   # Alt down
    user32.ShowWindow(hwnd, 9)          # SW_RESTORE
    user32.SetForegroundWindow(hwnd)
    user32.keybd_event(0x12, 0, 2, 0)   # Alt up


def newest(pattern, since=0.0):
    files = [f for f in glob.glob(pattern) if os.path.getmtime(f) >= since]
    return max(files, key=os.path.getmtime) if files else None


class Runner:
    def __init__(self, args):
        self.a = args
        self.mods = ";".join(MODS + args.extra_mods)
        self.mission_name = f"FPVTest.{args.map}"   # the folder suffix picks the world

    def start_game(self, extra):
        # -window: a fullscreen game that starts behind another window (the server console
        # in MP) tends to hang when you switch to it. Windowed avoids that; maximize at will.
        argv = [os.path.join(self.a.arma_dir, "arma3_x64.exe"), f"-name={self.a.profile_name}", f"-mod={self.mods}",
                "-skipIntro", "-noSplash", "-world=empty", "-showScriptErrors"] + extra
        if not self.a.fullscreen:
            argv.append("-window")
        subprocess.Popen(argv, cwd=self.a.arma_dir)

    def copy_mission(self, parent):
        dest = os.path.join(self.a.arma_dir, parent, self.mission_name)
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        shutil.copytree(MISSION_SRC, dest)
        with open(os.path.join(dest, "testconfig.sqf"), "w", encoding="ascii", newline="\r\n") as f:
            f.write(self.test_config)
        return dest

    def watch(self, label, find_rpt, still_running, keep_focus=False):
        """Follows whichever RPT find_rpt returns, printing FPV lines as they appear.
        Returns {passed, total, rpt} from the SUMMARY line, or None on timeout / no start.
        keep_focus: put the game back in front whenever something else takes the focus."""
        seen, started, focused = 0, False, False
        deadline = time.time() + self.a.timeout_minutes * 60
        start_deadline = time.time() + 5 * 60
        while time.time() < deadline:
            if not self.a.no_focus and (keep_focus or not focused) and game_window():
                focus_game()
                focused = True
            rpt = find_rpt()
            if rpt:
                try:
                    with open(rpt, encoding="utf-8", errors="replace") as f:
                        lines = [l.rstrip("\n") for l in f if INTERESTING.search(l)]
                except OSError:
                    lines = []
                for l in lines[seen:]:
                    if "FPV_TEST|START" in l:
                        started = True
                    colour = GREEN if "|PASS|" in l else RED if ("|FAIL|" in l or "Error" in l) else CYAN if "SUMMARY" in l else GRAY
                    say(f"[{label}] {l}", colour)
                    m = re.search(r"FPV_TEST\|SUMMARY\|(\d+)/(\d+)", l)
                    if m:
                        return {"passed": int(m.group(1)), "total": int(m.group(2)), "rpt": rpt}
                seen = len(lines)
            if not started and time.time() > start_deadline:
                say(f"[{label}] The test mission never started (no FPV_TEST|START within 5 minutes).", RED)
                return None
            if not still_running():
                say(f"[{label}] Game/server exited before the run finished.", RED)
                return None
            time.sleep(2)
        say(f"[{label}] Timed out after {self.a.timeout_minutes} minutes.", RED)
        return None

    def sp_run(self):
        say("== Singleplayer run ==", CYAN)
        # -init=playMission only finds missions in the GAME's Missions folder; a copy
        # in the profile's missions folder is silently ignored (the game just sits
        # at the main menu). SP also needs a real player unit (isPlayer) rather than
        # an MP slot (isPlayable).
        dest = self.copy_mission("Missions")
        sqm = os.path.join(dest, "mission.sqm")
        with open(sqm, encoding="ascii") as f:
            text = f.read()
        with open(sqm, "w", encoding="ascii", newline="") as f:
            f.write(text.replace("isPlayable=1;", "isPlayer=1;"))
        since = time.time()
        self.start_game([f"-init=playMission['','{self.mission_name}',true]"])
        # Singleplayer pauses in the background: keep the game in front for the whole run.
        return self.watch("SP", lambda: newest(os.path.join(CLIENT_LOGS, "arma3_x64_*.rpt"), since),
                          lambda: running("arma3_x64.exe"), keep_focus=True)

    def mp_run(self):
        say(f"== Multiplayer run (local dedicated server on port {PORT}) ==", CYAN)
        self.copy_mission("MPMissions")
        os.makedirs(WORK_DIR, exist_ok=True)
        for f in glob.glob(os.path.join(WORK_DIR, "*.rpt")):
            os.remove(f)
        server_cfg = os.path.join(WORK_DIR, "server.cfg")
        with open(server_cfg, "w", encoding="ascii") as f:
            f.write(f"""hostname = "FPV AI Drones test (local)";
password = "{PASSWORD}";
loopback = 1;
verifySignatures = 0;
BattlEye = 0;
persistent = 1;
kickDuplicate = 0;
class Missions
{{
    class FPVTest
    {{
        template = "{self.mission_name}";
        difficulty = "Regular";
    }};
}};
""")
        since = time.time()
        # Minimized: the console taking focus is what left the fullscreen game hanging.
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        si.wShowWindow = 7   # SW_SHOWMINNOACTIVE
        subprocess.Popen([os.path.join(self.a.arma_dir, "arma3server_x64.exe"), f"-port={PORT}", f"-config={server_cfg}",
                          f"-profiles={WORK_DIR}", "-name=fpvtest", f"-mod={self.mods}", "-autoInit"],
                         cwd=self.a.arma_dir, startupinfo=si, creationflags=subprocess.CREATE_NEW_CONSOLE)
        listen_deadline = time.time() + 120
        while not udp_listening(PORT):
            if time.time() > listen_deadline:
                sys.exit(f"Server did not open port {PORT} within 2 minutes. Check {WORK_DIR} for its RPT.")
            if not running("arma3server_x64.exe"):
                sys.exit(f"Server exited during startup. Check {WORK_DIR} for its RPT.")
            time.sleep(2)
        time.sleep(5)   # port opens slightly before the mission is ready

        if self.a.server_only:
            # Hands-on MP: the player joins from the normal Arma launcher, like real users do.
            say("\nServer is up (console minimized on the taskbar). Join it from the Arma 3 Launcher:", GREEN)
            say(r"  1. Mods: enable CBA_A3, plus the local mods x\FPV Drone Crocus With Settings and x\FPV_AI_Drones")
            say(f"  2. Play, then Multiplayer > Direct Connect: 127.0.0.1  port {PORT}  password {PASSWORD}")
            say("  3. You get Zeus ~10s after joining - press Y")
            return {"passed": 0, "total": 0, "rpt": None}
        self.start_game(["-connect=127.0.0.1", f"-port={PORT}", f"-password={PASSWORD}"])
        result = self.watch("MP", lambda: newest(os.path.join(WORK_DIR, "*.rpt")), lambda: running("arma3server_x64.exe"))

        # Detonations must happen on the server only. One in the CLIENT log means
        # explosives are being created on more than one machine again.
        client_rpt = newest(os.path.join(CLIENT_LOGS, "arma3_x64_*.rpt"), since)
        if result and client_rpt:
            with open(client_rpt, encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
            detonations = sum(1 for l in lines if re.search(r"FPV_AI_Drones: .* detonating", l))
            errors = sum(1 for l in lines if "Error in expression" in l)
            say(f"[MP] client detonations (must be 0): {detonations}", GREEN if detonations == 0 else RED)
            if errors:
                say(f"[MP] client script errors: {errors} - see {client_rpt}", RED)
            result["total"] += 1
            result["passed"] += detonations == 0
        return result

    def main(self):
        a = self.a
        if a.manual:
            # Hands-on testing: no stages, no test camera on the player's machine, the game in
            # the player's own display mode, and everything left running for them.
            a.mode = a.mode or "MP"
            if a.mode == "Both":
                sys.exit("--manual takes --mode SP or --mode MP, not Both.")
            a.start_stage, a.keep_open, a.fullscreen = 99, True, True
        if a.server_only:
            # A hands-on session: multiplayer, server stays up, straight to Zeus unless told otherwise.
            a.mode, a.keep_open = "MP", True
            if a.start_stage is None:
                a.start_stage = 99
        # Which stages the mission plays: an explicit list wins, --quick is the speed-iteration
        # set, otherwise everything from --start-stage on. Copied into each mission as testconfig.sqf.
        if a.quick and not a.stages:
            a.stages = [1, 2, 7, 10, 11]
        if a.mode is None:
            a.mode = "MP" if a.bench > 0 else "SP" if a.compat else "Both"
        compat = [(c.split(":", 1) + [""])[:2] for c in a.compat]
        self.test_config = "\n".join([
            f"FPVT_startStage = {a.start_stage or 1};",
            f"FPVT_stages = [{','.join(map(str, a.stages))}];",
            f"FPVT_bench = {a.bench};",
            "FPVT_compat = [" + ",".join(f'["{t}","{p}"]' for t, p in compat) + "];",
        ]) + "\n"
        if a.bench > 0:
            say(f"Speed bench: {a.bench} rounds", CYAN)
        elif compat:
            say("Other mods' drones: " + ", ".join(f"{t} {p}".strip() for t, p in compat), CYAN)
        elif a.stages:
            say("Stages: " + ", ".join(map(str, a.stages)), CYAN)

        if not a.server_only and running("arma3_x64.exe"):
            sys.exit("Arma 3 is already running. Close it first.")
        stop_test_server()
        if running("arma3server_x64.exe"):
            sys.exit("An Arma 3 server that isn't a test server is running. Stop it first.")

        if not a.no_build:
            say("== Building mod ==", CYAN)
            subprocess.run([sys.executable, os.path.join(REPO, "build.py")], check=True, stdout=subprocess.DEVNULL)

        modes = ["SP", "MP"] if a.mode == "Both" else [a.mode]
        results = {}
        for m in modes:
            results[m] = self.sp_run() if m == "SP" else self.mp_run()
            if m != modes[-1] or not a.keep_open:
                time.sleep(12)   # time to read the scoreboard
                stop_game()
                stop_test_server()

        print()
        all_ok = True
        for m, r in results.items():
            if not r:
                say(f"RESULT {m}: no summary - see the log above", RED)
                all_ok = False
                continue
            ok = r["passed"] == r["total"]
            say(f"RESULT {m}: {r['passed']}/{r['total']} checks passed", GREEN if ok else RED)
            all_ok = all_ok and ok
            # Time-to-kill per attack, from the harness's "ttk" lines (seconds from the drone
            # being sent until its target was finished, takeoff included).
            if r["rpt"] and os.path.exists(r["rpt"]):
                with open(r["rpt"], encoding="utf-8", errors="replace") as f:
                    ttk = [(float(mm.group(1)), mm.group(2).strip()) for mm in
                           (re.search(r"FPV_TEST\|ttk\|INFO\|([\d.]+)s\s+(.*)$", l) for l in f) if mm]
                if ttk:
                    secs = [s for s, _ in ttk]
                    say(f"  time-to-kill ({len(ttk)} kills): average {sum(secs) / len(secs):.1f}s, "
                        f"fastest {min(secs):.1f}s, slowest {max(secs):.1f}s", CYAN)
                    for s, stage in ttk:
                        print(f"    {s:6.1f}s  {stage}")
        if a.keep_open:
            print("Game left running - press Y in game for Zeus. Close it (and the server console, in MP) when done.")
        return 0 if all_ok else 1


def parse():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=["Both", "MP", "SP"], default=None,
                   help="default Both; MP with --bench / --manual, SP with --compat")
    p.add_argument("--no-build", action="store_true")
    p.add_argument("--start-stage", type=int, default=None, help="skip stages that already pass; 99 = skip all (straight to Zeus)")
    p.add_argument("--stages", type=int, nargs="+", default=[], help="run exactly these stages, e.g. --stages 1 7 11")
    p.add_argument("--quick", action="store_true", help="speed-iteration set: the attack-run stages (1, 2, 7, 10, 11)")
    p.add_argument("--bench", type=int, default=0, choices=range(0, 21), metavar="N",
                   help="just the attack-speed bench, this many rounds (default --mode MP)")
    p.add_argument("--map", default="VR", help="world to play the test mission on, e.g. Stratis (the bench then uses random real-terrain spots)")
    p.add_argument("--compat", nargs="+", default=[], metavar="CLASS[:PAYLOAD]",
                   help="another mod's drone classes: each flies a MOVE, MOVE, CYCLE loop, then must kill an enemy car (default --mode SP)")
    p.add_argument("--extra-mods", nargs="+", default=[], metavar="PATH", help="more mods to load (absolute, or relative to the game folder)")
    p.add_argument("--keep-open", action="store_true")
    p.add_argument("--fullscreen", action="store_true", help="for hands-on sessions (Zeus needs the mouse captured); default is windowed")
    p.add_argument("--no-focus", action="store_true",
                   help="don't bring the game to the front (by default once at start, and in SP whenever it loses the focus)")
    p.add_argument("--server-only", action="store_true", help="MP: start just the server; join it yourself from the normal Arma launcher")
    p.add_argument("--manual", action="store_true", help="hands-on: straight to Zeus, game in your normal display mode, left open (default --mode MP)")
    p.add_argument("--timeout-minutes", type=int, default=20)
    p.add_argument("--profile-name", default="vulcan420")
    p.add_argument("--arma-dir", default=r"E:\SteamLibrary\steamapps\common\Arma 3")
    return p.parse_args()


if __name__ == "__main__":
    sys.exit(Runner(parse()).main())
