# Arma 3 — FPV AI Drones

An Arma 3 mod that adds AI-controlled FPV kamikaze drones which automatically hunt and attack enemy
vehicles or infantry.

## Features

- AI-controlled kamikaze drones, no UAV terminal needed
- Works in the **Eden editor** and in **Zeus**
- Separate Anti-Tank and Anti-Personnel presets
- Configurable target types, engagement distances, search height and payload
- Server-friendly: all AI runs server-side, and the release is signed

---

## Installation

### Singleplayer / local

Enable `@FPV_AI_Drones` in the Arma 3 launcher.

### Dedicated server

Servers running `verifySignatures = 2` need the public key:

1. Copy `@FPV_AI_Drones` into the server's mod folder.
2. Copy `keys\fpv_ai_drones_v1_1.bikey` into the server's `keys\` folder.
3. Add `@FPV_AI_Drones` to the server's `-mod=` line.

Clients need the mod enabled too. If you get a signature rejection, check the server's `keys\` folder
actually has the `.bikey` and that both sides are on the same mod version — a key from an older
release will not validate a newer PBO.

---

## Setup — Eden editor

This is the part people get wrong most often, so in order:

1. Place a drone — for example **Crocus (AT)** or **Crocus (AP)**.
2. Place the module: **Systems → Modules → Effects → FPV AI Drones** (or the Anti-Tank /
   Anti-Personnel variant).
3. **Synchronise the module to the drone** — select the module, press <kbd>F5</kbd>, drag onto the
   drone.
4. Place an enemy of the type you're targeting, at least a few hundred metres away.
5. Play.

**The drone does not need a crew.** If you place it as an empty vehicle, the module gives it a UAV
crew automatically. (Before v1.1 an empty drone was silently ignored and just sat there — that was
the single most common bug report.)

If the module can't find a drone it now says so in system chat and writes to the RPT, rather than
failing silently.

## Setup — Zeus

1. Spawn or find a drone.
2. Open the Zeus module tree: **Modules → Effects → FPV AI Drones**.
3. Either **drop the module directly onto the drone**, or place it on the ground within **100 m** of
   one — it will adopt nearby drones.

The mod's addon needs to be available to the curator: either set the Zeus module's addons to
**"All Addons"** in the mission, or call `addCuratorAddons` yourself.

---

## Module parameters

| Parameter | AT default | AP default | What it does |
|---|---|---|---|
| Target Unit Types | `LandVehicle,Car,Tank` | `Man` | Comma-separated `isKindOf` classes |
| Target Source | `vehicles` | `allUnits` | Which pool to scan. Use `allUnits` for infantry |
| Enable Chat Messages | off | off | Drone init/debug messages in system chat |
| Initial Search Height | 30 | 50 | Cruise height while hunting (m) |
| Target Detection Range | 200 | 200 | Acquisition range, and the range at which a target is dropped |
| Attack Distance | 10 | 30 | 3D distance at which the attack run begins (m) |
| Attack Distance 2D | 3 | 8 | Horizontal tolerance for the run (m) |
| Attack Height | 5 | 8 | Height held during the run; the drone dives below it before detonating |
| Allow Object Parent | true | false | Whether to target units riding inside vehicles |
| Custom Ammo | `SatchelCharge_Remote_Ammo` | `DemoCharge_Remote_Ammo` | Payload. Comma-separate for multiple charges |

Targeting uses `BIS_fnc_sideIsEnemy`, so it respects the mission's actual side relations —
independent/resistance works, not just BLUFOR vs OPFOR.

---

## Mission maker API

To drive a drone directly, without placing a module — useful for dynamically spawned drones in
frameworks like Antistasi or Dynamic Recon Ops:

```sqf
if (isServer) then {
    _drone setVariable ["FPV_AI_Drones_managed", true, true];
    [
        _drone,
        ["Man"],                    // unit kinds
        "allUnits",                 // target source
        30,                         // attack distance
        8,                          // attack distance 2D
        8,                          // attack height
        false,                      // allow object parent
        "DemoCharge_Remote_Ammo",   // ammo
        200,                        // target detection range
        0.25,                       // height adjustment delay
        15,                         // stuck check interval
        0.1,                        // stuck threshold
        5,                          // move adjustment delay
        50,                         // initial search height
        false                       // enable chat
    ] spawn FPV_AI_Drones_fnc_fpvLogic;
};
```

Call it on the **server only** — the drone AI is server-side by design.

---

## Multiplayer notes

All drone logic runs on the server. Chat messages are broadcast with `remoteExec`.

A module manages only the drones it was synchronised to (or attached to in Zeus). It no longer takes
over every drone of the same type on the map, so players' own drones are left alone.

## Known incompatibilities

- **VCOM AI** — VCOM continuously reasserts AI behaviour and pathing, and fights the drone's own
  movement orders. Not yet resolved; see `ROADMAP.md`.
- **LAMBS Danger** — generally works, but LAMBS may redirect drones via its own task system.

## Building from source

Requires **Arma 3 Tools** (Steam → Library → Tools).

```powershell
.\build.ps1                 # build + sign with the current key
.\build.ps1 -KeyName v1_2   # new key for a new release
```

Outputs the PBO and `.bisign` to `..\`, and the public `.bikey` to `..\..\keys\`.

The private key is written to `..\..\private_keys\` and is **git-ignored** — never commit or
distribute it. Anyone holding it can sign PBOs that your users' servers will trust.
