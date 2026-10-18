"""Builds and signs the FPV AI Drones addon.

    python build.py                    # build + sign with the current key
    python build.py --key-name v1_2    # start a new key version for a new release
    python build.py --no-release       # build + sign only; leave x\FPV_AI_Drones_release alone (test runs)

Re-sign after EVERY rebuild: the signature is over the built PBO, so a stale
.bisign fails verification exactly as hard as no signature at all.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys


def tool(exe, args, cwd=None):
    # The Arma tools write banners to stderr on success; judge them by the exit code.
    r = subprocess.run([exe] + args, cwd=cwd, capture_output=True, text=True, errors="replace")
    for line in (r.stdout + r.stderr).splitlines():
        print(f"  {line}")
    if r.returncode != 0:
        sys.exit(f"{os.path.basename(exe)} failed with exit code {r.returncode}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--key-name", default="fpv_ai_drones_v1_1")
    p.add_argument("--tools-dir", default=r"E:\SteamLibrary\steamapps\common\Arma 3 Tools")
    # The release folder is loaded by other tools (the ac-lab matches use it as the published
    # build), so only a release should replace it - not every test build.
    p.add_argument("--no-release", action="store_true", help="don't re-stage the release folder")
    a = p.parse_args()

    src = os.path.dirname(os.path.abspath(__file__))                   # ...\FPV_AI_Drones\addons\fpv_ai_drones
    addons = os.path.dirname(src)                                       # ...\FPV_AI_Drones\addons
    mod = os.path.dirname(addons)                                       # ...\FPV_AI_Drones
    keys = os.path.join(mod, "keys")                                    # shipped public key
    private = os.path.join(os.path.dirname(mod), "fpv_ai_drones_private")   # OUTSIDE mod: Publisher uploads the whole mod folder
    pbo = os.path.join(addons, "fpv_ai_drones.pbo")

    addon_builder = os.path.join(a.tools_dir, r"AddonBuilder\AddonBuilder.exe")
    create_key = os.path.join(a.tools_dir, r"DSSignFile\DSCreateKey.exe")
    sign_file = os.path.join(a.tools_dir, r"DSSignFile\DSSignFile.exe")
    for exe in (addon_builder, create_key, sign_file):
        if not os.path.exists(exe):
            sys.exit(f"Missing Arma 3 Tools component: {exe}")
    for d in (keys, private):
        os.makedirs(d, exist_ok=True)

    # --- key -------------------------------------------------------------------
    private_key = os.path.join(private, f"{a.key_name}.biprivatekey")
    public_key = os.path.join(keys, f"{a.key_name}.bikey")
    if not os.path.exists(private_key):
        print(f"Creating signing key '{a.key_name}'...")
        tool(create_key, [a.key_name], cwd=private)
        # DSCreateKey drops both halves next to each other; the public half ships.
        made_public = os.path.join(private, f"{a.key_name}.bikey")
        if os.path.exists(made_public):
            shutil.move(made_public, public_key)
    else:
        print(f"Reusing existing key '{a.key_name}'.")

    # --- build -----------------------------------------------------------------
    print(f"Building {pbo} ...")
    for old in glob.glob(os.path.join(addons, "fpv_ai_drones.pbo.*.bisign")):
        os.remove(old)   # signatures belonging to the previous build
    tool(addon_builder, [src, addons, "-clear", "-packonly", f"-exclude={os.path.join(src, 'build_exclude.txt')}"])
    if not os.path.exists(pbo):
        sys.exit(f"AddonBuilder did not produce {pbo}")

    # --- mod root metadata -----------------------------------------------------
    # mod.cpp is kept in source control alongside the addon, but Arma only reads it
    # from the mod ROOT. It is excluded from the PBO (build_exclude.txt) because a
    # copy packed inside the archive is inert.
    shutil.copy(os.path.join(src, "mod.cpp"), os.path.join(mod, "mod.cpp"))
    print("Copied mod.cpp to mod root.")

    # The example scenarios are packed into the PBO (playable from Scenarios), but a
    # packed mission can't be opened in the editor - so also ship plain copies that
    # mission makers can drop into Documents\Arma 3\missions.
    examples = os.path.join(mod, "examples")
    if os.path.isdir(examples):
        shutil.rmtree(examples)
    shutil.copytree(os.path.join(src, "missions"), examples)
    print(f"Copied editable example missions to {examples}.")

    # meta.cpp carries the Workshop publishedid. Without it the Publisher uploads a
    # NEW Workshop item instead of updating the existing one.
    if not os.path.exists(os.path.join(mod, "meta.cpp")):
        print(f"WARNING: No meta.cpp at {mod} - publishing from here would create a DUPLICATE Workshop item.\n"
              "WARNING: Create it with the publishedid from your Workshop URL before uploading:\n"
              "WARNING:     protocol = 1;\n"
              "WARNING:     publishedid = <id from ...?id=NNNNNNNNNN>;\n"
              'WARNING:     name = "FPV AI Drones";')

    # --- sign ------------------------------------------------------------------
    print(f"Signing with {a.key_name} ...")
    tool(sign_file, [private_key, pbo])

    # --- release folder --------------------------------------------------------
    # The mod folder also holds this source checkout (addons\fpv_ai_drones, including
    # .git, tests and notes). Never upload it: stage exactly what players need in a
    # separate folder and publish that.
    release = os.path.join(os.path.dirname(mod), "FPV_AI_Drones_release")
    if a.no_release:
        print(f"Built and signed {pbo} (release folder left as it is)")
        return
    if os.path.isdir(release):
        shutil.rmtree(release)
    os.makedirs(os.path.join(release, "addons"))
    os.makedirs(os.path.join(release, "keys"))
    shutil.copy(pbo, os.path.join(release, "addons"))
    for sig in glob.glob(os.path.join(addons, "fpv_ai_drones.pbo.*.bisign")):
        shutil.copy(sig, os.path.join(release, "addons"))
    shutil.copy(public_key, os.path.join(release, "keys"))
    shutil.copytree(examples, os.path.join(release, "examples"))
    for f in ("mod.cpp", "meta.cpp"):
        if os.path.exists(os.path.join(mod, f)):
            shutil.copy(os.path.join(mod, f), release)
    print(f"Release folder (upload THIS one): {release}")

    print("\nDone. Ship these:")
    print(f"  {pbo}")
    for sig in glob.glob(os.path.join(addons, "*.bisign")):
        print(f"  {sig}")
    print(f"  {public_key}")
    print(f"\nPrivate key (never distribute, never commit): {private}")


if __name__ == "__main__":
    main()
