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

1. Open the Zeus module tree: **Modules → Effects → FPV AI Drones** (Anti-Tank for vehicles,
   Anti-Personnel for infantry).
2. Either **drop the module onto a drone**, or place it on the ground as a **drone station**:
   every drone within **100 m** of it is picked up - including drones you place there later.
   Place the module once, then just keep putting drones next to it.
3. With **Control All Drones Of This Type** on (the default), the module also takes over every
   other drone of the same type anywhere on the map, including ones spawned later.
4. Optional: give a drone **waypoints**. While it has no target it flies them in order, and
   attacks anything it spots on the way.

A drone is controlled by the first module that picks it up; placing a second module next to it
doesn't change it. Use the module type you want (AT / AP) first.

Works on dedicated servers: the module is placed on the Zeus player's machine and handed to the
server, where all drone AI runs.

The mod's addon needs to be available to the curator: either set the Zeus module's addons to
**"All Addons"** in the mission, or call `addCuratorAddons` yourself.

> **Why waypoints only work with the module:** a plain Crocus drone ignores waypoints - on the
> ground it never takes off, in the air it hovers in place - because the engine marks its waypoints
> complete without flying them. That's the drone mod's AI, not this one. A drone this module controls
> is flown to each waypoint explicitly.

---

## Example scenarios

Two VR scenarios ship with the mod - in game under **Play > Showcases**:

- **FPV AI Drones - Editor example**: modules synced to empty drones in the editor; enemy armour and
  infantry advance and get hit. Press Y for a Zeus camera.
- **FPV AI Drones - Zeus example**: a Zeus sandbox with live Crocus drones at marked drone stations
  and targets near and far. Also in the multiplayer mission list.

Editable copies are in the mod's `examples\` folder - copy them into `Documents\Arma 3\missions` to
open them in the editor. Sources live in `missions\` (packed into the PBO) and are copied there by
`build.py`.

---

## Module parameters

| Parameter | AT default | AP default | What it does |
|---|---|---|---|
| Target Unit Types | `LandVehicle,Car,Tank` | `Man` | Comma-separated `isKindOf` classes |
| Target Source | `vehicles` | `allUnits` | Which pool to scan. Use `allUnits` for infantry |
| Target Sides | Mission's enemies | Mission's enemies | Who to attack: the mission's side relations (default), one side only (OPFOR / BLUFOR / Independent), or everyone except its own side. Civilians are never targets |
| Enable Chat Messages | off | off | Drone init/debug messages in system chat |
| Initial Search Height | 30 | 50 | Cruise height while hunting and flying waypoints (m); also the most the attack run climbs above its target |
| Target Detection Range | 200 | 200 | Acquisition range. A target is chased until it's 1.5x this far away |
| Attack Speed | 180 | 144 | Top speed of the attack run (km/h) |
| Allow Object Parent | true | false | Whether to target units riding inside vehicles |
| Custom Ammo | `SatchelCharge_Remote_Ammo` | `DemoCharge_Remote_Ammo` | Payload. Comma-separate for multiple charges |

v1.2 removed **Attack Distance, Attack Distance 2D, Attack Height** and the delay / stuck settings
from the module: the attack run is flown by the script (see below), so they did nothing. Missions
that set them still load; `fpvLogic` still accepts them as (ignored) parameters.

### How an attack run works (v1.2)

Once a drone has a target, an `EachFrame` handler flies it - not the AI pilot, which slows down
near every move point and could not catch a moving vehicle:

- 180 km/h for anti-vehicle drones, 144 km/h for anti-personnel (module setting **Attack Speed**),
  steered every frame
- keeps 12 m clear of other drones (a bump sets a Crocus off) until the final dive
- aims where a moving target will be (lead), not where it is
- glides down at about 1:3 to a dive entry point 30 m out; if a building or trees block the
  straight line down, the entry point is raised until it doesn't (steep dive over cover)
- the charge goes off on the surface it's about to hit (or within 3 m of the target's centre)
- gives up only if the target is destroyed or no longer hostile (crew dead), is 1.5x detection
  range away, or the drone makes no progress for 12 s - then it searches again
- spreads a swarm out: each other drone already attacking a target makes it count as 150 m
  further away, so drones pick different targets

Waypoints (e.g. given in Zeus) are flown the same way at ~35 m/s while there's no target.

With the default "Mission's enemies", targeting uses `BIS_fnc_sideIsEnemy`, so it respects the mission's actual side relations —
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
        false,                      // enable chat
        "ENEMIES",                  // target sides: ENEMIES | EAST | WEST | GUER | NOTOWN (optional)
        144                         // attack speed in km/h (optional, default 180 vehicles / 144 infantry)
    ] spawn FPV_AI_Drones_fnc_fpvLogic;
};
```

Call it on the **server only** — the drone AI is server-side by design.

---

## Multiplayer notes

All drone logic runs on the server. Chat messages are broadcast with `remoteExec`.

A module manages only the drones it was synchronised to (or attached to in Zeus). It no longer takes
over every drone of the same type on the map, so players' own drones are left alone.

## Other drone mods

Any drone (`isUav = 1` in its config) can be synced to a module. Tested: **FPV Drone Crocus
Enhanced** and **Ukraine FPV Drone** (empty, PG-7VL payload, RPG-18), each flying a MOVE, MOVE,
CYCLE patrol and then attacking a car (`tests/run_tests.py --compat`).

## Known incompatibilities

- **VCOM AI** — VCOM continuously reasserts AI behaviour and pathing, and fights the drone's own
  movement orders. Not yet resolved; see `ROADMAP.md`.
- **LAMBS Danger** — generally works, but LAMBS may redirect drones via its own task system.

## Building from source

Requires **Arma 3 Tools** (Steam → Library → Tools).

```
python build.py                    # build + sign with the current key
python build.py --key-name v1_2    # new key for a new release
```

Outputs the PBO and `.bisign` to `..\`, and the public `.bikey` to `..\..\keys\`.

The private key is written to `x\fpv_ai_drones_private\`, outside the mod folder (the Workshop
Publisher uploads the whole mod folder) and outside the repo — never commit or distribute it.
Anyone holding it can sign PBOs that your users' servers will trust.

## Testing

`tests/run_tests.py` plays a scripted test mission you can watch: a chase camera follows each drone
attack, and every check is written to the RPT as `FPV_TEST|<check>|PASS/FAIL|<detail>`.

```
python tests/run_tests.py                     # build, then singleplayer, then multiplayer
python tests/run_tests.py --mode MP           # local dedicated server + your game joining it
python tests/run_tests.py --start-stage 7     # skip stages that already pass
python tests/run_tests.py --keep-open         # stay in game afterwards - press Y for Zeus
```

```
python tests/run_tests.py --bench 1                  # attack-speed bench only (MP), ~5 min
python tests/run_tests.py --bench 1 --map Stratis    # same attacks at random spots on real terrain
python tests/run_tests.py --quick                    # the attack-related stages (1, 2, 7, 10, 11)
```

```
python tests/run_tests.py --compat B_UAFPV B_UAFPV:PG7VL --extra-mods <path to the other mod>
```

`--compat` checks other mods' drones (class, optionally `:payload` for the Ukraine FPV Drone mod's
payload setting), set up as in the editor: synced to the AT module at mission start, waypoints MOVE,
MOVE, CYCLE. Each must keep going round its loop and then kill an enemy car that drives through it.

The bench is for tuning the attack run: a parked tank and a car crossing at ~70 km/h at close
(60 m), medium (150 m) and far (400 m, detection range 500) range, a tank parked behind a building,
and an AP drone vs a squad. It prints the time-to-kill per attack; the drone's own log line says how
long it took from acquiring the target. With `FPV_AI_Drones_debug = true` (set by the bench) every
attack run also writes a flight trace to the RPT.

Stages: empty Eden-placed drone (1), AP vs infantry (2), Zeus-style attached module plus a
same-class drone that must be left alone (3), module placed on the ground near a drone (4), module
with no drone (5), plain-drone waypoint baselines (6, info only), managed drone sent by waypoint (7),
module started through the Zeus code path from the player's machine (8), Independent drone (9),
Target Sides (10), tank driving past (11). An attempt that makes no progress for 30 s is stopped
early instead of running into its timeout.

Only CBA and the Crocus drones are loaded - no AI mods, which change drone behaviour. Singleplayer
pauses when the game window loses focus, so keep it in front during an SP run.
