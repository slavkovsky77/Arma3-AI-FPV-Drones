"""Downloads an Arma 3 Workshop mod through the running Steam client WITHOUT subscribing to it,
and copies it to a folder of its own - for testing other mods' drones (run_tests.py --compat).

    python -I tests/fetch_workshop_mod.py <steam_api64.dll> <item id> <out folder>
    python -I tests/fetch_workshop_mod.py "E:/SteamLibrary/steamapps/common/Arma 3/steam_api64.dll" 3475006113 D:/testmods/@ukrfpv

Steam keeps an unsubscribed download only temporarily, hence the copy. Steam must be running and
logged in to an account that owns Arma 3.
"""
import ctypes
import os
import shutil
import sys
import tempfile
import time
from ctypes import byref, c_bool, c_char_p, c_int, c_uint32, c_uint64, c_void_p

APP_ID = 107410   # Arma 3
STATE_INSTALLED, STATE_NEEDS_UPDATE, STATE_DOWNLOADING, STATE_PENDING = 4, 8, 16, 32

dll_src, item, out = sys.argv[1], int(sys.argv[2]), os.path.abspath(sys.argv[3])
if os.path.exists(out):
    sys.exit(f"{out} already exists - pick a new, empty folder")
# Steam needs steam_api64.dll + steam_appid.txt in the working directory; keep them out of the repo.
work = tempfile.mkdtemp(prefix="fpv_wsdl_")
shutil.copy(dll_src, os.path.join(work, "steam_api64.dll"))
with open(os.path.join(work, "steam_appid.txt"), "w") as f:
    f.write(str(APP_ID))
os.chdir(work)

api = ctypes.CDLL(os.path.join(work, "steam_api64.dll"))
api.SteamAPI_InitFlat.argtypes = [c_char_p]; api.SteamAPI_InitFlat.restype = c_int
api.SteamAPI_SteamUGC_v020.restype = c_void_p
api.SteamAPI_ISteamUGC_DownloadItem.argtypes = [c_void_p, c_uint64, c_bool]
api.SteamAPI_ISteamUGC_DownloadItem.restype = c_bool
api.SteamAPI_ISteamUGC_GetItemState.argtypes = [c_void_p, c_uint64]
api.SteamAPI_ISteamUGC_GetItemState.restype = c_uint32
api.SteamAPI_ISteamUGC_GetItemDownloadInfo.argtypes = [c_void_p, c_uint64, ctypes.POINTER(c_uint64), ctypes.POINTER(c_uint64)]
api.SteamAPI_ISteamUGC_GetItemDownloadInfo.restype = c_bool
api.SteamAPI_ISteamUGC_GetItemInstallInfo.argtypes = [c_void_p, c_uint64, ctypes.POINTER(c_uint64), c_char_p, c_uint32, ctypes.POINTER(c_uint32)]
api.SteamAPI_ISteamUGC_GetItemInstallInfo.restype = c_bool

err = ctypes.create_string_buffer(1024)
if api.SteamAPI_InitFlat(err) != 0:
    sys.exit(f"Steam init failed: {err.value.decode(errors='replace')} - is Steam running and logged in?")
try:
    ugc = api.SteamAPI_SteamUGC_v020()
    if not api.SteamAPI_ISteamUGC_DownloadItem(ugc, item, True):
        sys.exit("DownloadItem refused - wrong item id?")
    deadline, last = time.time() + 1800, None
    while time.time() < deadline:
        api.SteamAPI_RunCallbacks()
        state = api.SteamAPI_ISteamUGC_GetItemState(ugc, item)
        done, total = c_uint64(), c_uint64()
        api.SteamAPI_ISteamUGC_GetItemDownloadInfo(ugc, item, byref(done), byref(total))
        msg = f"{done.value >> 20}/{total.value >> 20} MB"
        if msg != last:
            print(msg, flush=True)
            last = msg
        if state & STATE_INSTALLED and not state & (STATE_NEEDS_UPDATE | STATE_DOWNLOADING | STATE_PENDING):
            break
        time.sleep(1)
    else:
        sys.exit("timed out waiting for the download")
    size, stamp = c_uint64(), c_uint32()
    folder = ctypes.create_string_buffer(1024)
    if not api.SteamAPI_ISteamUGC_GetItemInstallInfo(ugc, item, byref(size), folder, 1024, byref(stamp)):
        sys.exit("downloaded, but Steam gives no install folder")
    src = folder.value.decode(errors="replace")
finally:
    api.SteamAPI_Shutdown()

shutil.copytree(src, out)
print(f"copied {src} -> {out} ({size.value >> 20} MB). Load it with: run_tests.py --extra-mods \"{out}\"")
