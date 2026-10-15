"""
Sets the Workshop description and adds gallery images for an item, through the
running Steam client (Steamworks ISteamUGC). Used for FPV AI Drones v1.1.0.

    python -I workshop_update.py <steam_api64.dll> <description file> [image ...]
"""
import ctypes, os, shutil, struct, sys, time
from ctypes import c_bool, c_char_p, c_int, c_uint32, c_uint64, c_void_p, byref

APP_ID = 107410            # Arma 3
ITEM_ID = 3380337397       # FPV AI Drones
CB_SUBMIT_ITEM_UPDATE = 3404   # k_iSteamUGCCallbacks (3400) + 4 -> SubmitItemUpdateResult_t

dll_src, desc_file, images = sys.argv[1], sys.argv[2], sys.argv[3:]
work = os.path.dirname(os.path.abspath(__file__))
shutil.copy(dll_src, os.path.join(work, "steam_api64.dll"))
with open(os.path.join(work, "steam_appid.txt"), "w") as f:
    f.write(str(APP_ID))
os.chdir(work)   # SteamAPI reads steam_appid.txt from the working directory

api = ctypes.CDLL(os.path.join(work, "steam_api64.dll"))
api.SteamAPI_InitFlat.argtypes = [ctypes.c_char_p]; api.SteamAPI_InitFlat.restype = c_int
api.SteamAPI_SteamUGC_v020.restype = c_void_p
api.SteamAPI_SteamUtils_v010.restype = c_void_p
api.SteamAPI_ISteamUGC_StartItemUpdate.argtypes = [c_void_p, c_uint32, c_uint64]
api.SteamAPI_ISteamUGC_StartItemUpdate.restype = c_uint64
api.SteamAPI_ISteamUGC_SetItemDescription.argtypes = [c_void_p, c_uint64, c_char_p]
api.SteamAPI_ISteamUGC_SetItemDescription.restype = c_bool
api.SteamAPI_ISteamUGC_AddItemPreviewFile.argtypes = [c_void_p, c_uint64, c_char_p, c_int]
api.SteamAPI_ISteamUGC_AddItemPreviewFile.restype = c_bool
api.SteamAPI_ISteamUGC_SubmitItemUpdate.argtypes = [c_void_p, c_uint64, c_char_p]
api.SteamAPI_ISteamUGC_SubmitItemUpdate.restype = c_uint64
api.SteamAPI_ISteamUGC_GetItemUpdateProgress.argtypes = [c_void_p, c_uint64, ctypes.POINTER(c_uint64), ctypes.POINTER(c_uint64)]
api.SteamAPI_ISteamUGC_GetItemUpdateProgress.restype = c_int
api.SteamAPI_ISteamUtils_IsAPICallCompleted.argtypes = [c_void_p, c_uint64, ctypes.POINTER(c_bool)]
api.SteamAPI_ISteamUtils_IsAPICallCompleted.restype = c_bool
api.SteamAPI_ISteamUtils_GetAPICallResult.argtypes = [c_void_p, c_uint64, c_void_p, c_int, c_int, ctypes.POINTER(c_bool)]
api.SteamAPI_ISteamUtils_GetAPICallResult.restype = c_bool

err = ctypes.create_string_buffer(1024)
rc = api.SteamAPI_InitFlat(err)
if rc != 0:
    sys.exit(f"Steam init failed ({rc}): {err.value.decode(errors='replace')} - is Steam running and logged in?")
print("Steam initialized")
try:
    ugc, utils = api.SteamAPI_SteamUGC_v020(), api.SteamAPI_SteamUtils_v010()
    handle = api.SteamAPI_ISteamUGC_StartItemUpdate(ugc, APP_ID, ITEM_ID)

    desc = open(desc_file, encoding="utf-8").read().replace("\r\n", "\n").strip()
    print(f"description: {len(desc)} chars ->", api.SteamAPI_ISteamUGC_SetItemDescription(ugc, handle, desc.encode("utf-8")))
    for img in images:
        ok = api.SteamAPI_ISteamUGC_AddItemPreviewFile(ugc, handle, os.path.abspath(img).encode("utf-8"), 0)  # 0 = image
        print(f"image {os.path.basename(img)} ->", ok)

    call = api.SteamAPI_ISteamUGC_SubmitItemUpdate(ugc, handle, None)   # None: no new change-note entry
    print("submitted, waiting for Steam...")
    failed = c_bool(False)
    deadline = time.time() + 300
    while not api.SteamAPI_ISteamUtils_IsAPICallCompleted(utils, call, byref(failed)):
        api.SteamAPI_RunCallbacks()
        done, total = c_uint64(), c_uint64()
        status = api.SteamAPI_ISteamUGC_GetItemUpdateProgress(ugc, handle, byref(done), byref(total))
        if time.time() > deadline:
            sys.exit("timed out waiting for Steam")
        time.sleep(0.5)

    buf = ctypes.create_string_buffer(16)   # SubmitItemUpdateResult_t: EResult, bool, PublishedFileId_t
    got = api.SteamAPI_ISteamUtils_GetAPICallResult(utils, call, buf, 16, CB_SUBMIT_ITEM_UPDATE, byref(failed))
    eresult, needs_legal, item = struct.unpack_from("<i?3xQ", buf.raw)
    print(f"result: got={got} ioFailed={failed.value} EResult={eresult} (1 = OK) "
          f"needsLegalAgreement={needs_legal} item={item}")
    sys.exit(0 if (got and eresult == 1) else 1)
finally:
    api.SteamAPI_Shutdown()
