# FPV AI Drones — Improvement Plan

Written 2026-09-09, from the Steam Workshop comment backlog (Jul 2025 → Jun 2026) read against the
code at commit `6c230b0`.

Line references point at that commit. Anything I could prove by reading the code is marked
**Confirmed**; anything that fits the symptoms but that I could not verify without running the game
is marked **Hypothesis** — test those before rewriting around them.

---

## 1. What people are actually asking for

Grouping the comments by root cause rather than by author:

| # | Theme | Who | Status |
|---|-------|-----|--------|
| 6 | **Zeus support** | chorizos, stez, JaySOC, Kibbe_Surdo, БАНДИТСКИЙ КРАЙ, hexenkeit | Not started |
| 4 | **Drones do nothing / don't move / don't kill** | whiskey, gabberstabber, Fylon ×2, Headless_hashbrown | Root causes identified below |
| 2 | **No .bikey — can't run on a server** | WoLFoR, Efremio | Not started |
| 2 | **Chat spam** | Quarter, CoffeePot | ✅ **Fixed in `6c230b0`** |
| 3 | **Mod compatibility** (VCOM, Antistasi, DRO) | Redneck Wolf, shark09stormYT, eth | Needs explicit handling |

Two of these — Zeus and signing — are the difference between "a mod I can try in the editor" and "a
mod my group can actually run". They're where the leverage is.

Note on the chat complaints: Quarter and CoffeePot are already answered by the `EnableChatMessages`
checkbox, defaulting off. Worth a Workshop changelog post so they know, since neither will re-check
the code.

---

## 2. Do these in order

The ordering is deliberate — each tier unblocks the next. Fixing Zeus before fixing multiplayer
locality just means more people hitting the locality bug.

### Tier 0 — Correctness. Nothing else matters until these are done.

#### 0.1 The mod has no multiplayer locality handling at all — **Confirmed, and this is the big one**

A grep for `isServer`, `isDedicated`, `remoteExec`, `hasInterface`, or `local` across the whole addon
returns **zero hits**. Combined with [`config.cpp:46`](config.cpp) `isGlobal = 1`, this means:

- The module function runs on **every machine** — server and every client.
- Each machine spawns its own copy of the `while {true}` loop in
  [`fn_initModule.sqf:75-98`](functions/fn_initModule.sqf), and every copy issues `doMove`,
  `setBehaviour`, `forceSpeed` and `flyInHeight` at the same drone. Those commands only have effect
  where the drone is local, so clients are spamming no-ops while fighting the server's own commands.
- Worst of all, [`fn_fpvLogic.sqf:335`](functions/fn_fpvLogic.sqf) calls `createVehicle`, which has
  **global effect**. With 10 players you create 10 sets of explosives per drone, then set damage on
  all of them.

This one bug plausibly explains Efremio's multiplayer report *and* Headless_hashbrown's "they all
just explode in unison doing nothing" — simultaneous duplicate detonations from every connected
machine, at a drone that's being yanked in several directions at once.

**Fix.** Guard the entry point and keep the whole AI loop server-side:

```sqf
// top of fn_initModule.sqf, after the params line
if (!isServer) exitWith {};
```

Then in `fn_fpvLogic.sqf`, before issuing movement commands, confirm the drone is local — and if it
isn't, either skip it or take ownership:

```sqf
if (!local _uavInstance) exitWith {};
```

Keep `isGlobal = 1` (the module *object* should exist everywhere), but let only the server run the
logic. `systemChat` then needs `remoteExec` to reach players — see 0.2.

**Verify:** host a local MP session with one client, place one drone, and confirm exactly one set of
explosives is created. Check both `.rpt` files.

#### 0.2 `systemChat` from the server reaches nobody — **Confirmed**

Once 0.1 lands, every `systemChat` in the codebase runs on the server, where no player sees it. The
messages need broadcasting:

```sqf
if (_enableChat) then { ["systemChat", [_msg]] remoteExec ["BIS_fnc_call", 0]; };
// or simply: _msg remoteExec ["systemChat", 0];
```

Do this *after* 0.1, not before — right now it would make the spam worse, which is the opposite of
what Quarter and CoffeePot asked for.

#### 0.3 `continue` used outside a loop — **Confirmed**

[`fn_fpvLogic.sqf:122-125`](functions/fn_fpvLogic.sqf):

```sqf
if (isNull _nearestEnemy) then {
	continue;
};
```

This sits at top-level script scope; the `while` loop above it ended at line 120. `continue` outside
a loop throws a script error and dumps to `.rpt`. It's reachable: the search loop at line 114 exits
with a null target whenever the drone dies or is deleted mid-search.

**Fix:** `exitWith {}` instead of `continue`. Cheap, and it cleans up RPT noise that's currently
hiding real errors.

#### 0.4 Suspicious `deleteVehicleCrew` call — **Confirmed as malformed, effect needs testing**

[`fn_fpvLogic.sqf:340`](functions/fn_fpvLogic.sqf):

```sqf
_uavInstance deleteVehicleCrew driver _uavInstance;
```

`deleteVehicleCrew` is a **unary** command. Written with `_uavInstance` on the left it either throws
or silently parses as two statements. Should be:

```sqf
deleteVehicleCrew _uavInstance;
```

This runs on the detonation path, so if it's throwing, the explosion sequence may be aborting
partway — which would directly produce "the drone explodes but nothing dies".

#### 0.5 `switch` with no `default` can return `nil` — **Confirmed**

[`fn_fpvLogic.sqf:39-42`](functions/fn_fpvLogic.sqf) handles `allUnits` and `vehicles` and nothing
else. Any other value leaves `_targets` undefined and the `select` on line 44 throws. The Combo in
config only offers those two, but a mission maker calling the function directly (or a future
`targetSource`) breaks it silently. Add `default { allUnits };`.

#### 0.6 Hardcoded 200 m overrides the configurable detection range — **Confirmed**

[`fn_fpvLogic.sqf:210`](functions/fn_fpvLogic.sqf) breaks target lock at `_currentDistance > 200`,
ignoring `_targetDetectionRange` entirely. Anyone who raises Target Detection Range above 200 in the
module gets a drone that acquires a distant target and then immediately drops it — an infinite
acquire/drop cycle that looks exactly like aimless circling. Replace the literal with
`_targetDetectionRange`.

#### 0.7 Script-scope functions leak into the global namespace — **Confirmed**

`isUnitOfKind`, `findNearestEnemyOfType`, `is_dead`, `isExternallyControlled`, `isStuck` and
`handleStuckPos` are all assigned **without** `private` (lines 20, 35, 74, 80, 147, 160), so they're
global variables redefined by every drone's spawned thread. Two consequences: pointless churn with
many drones, and a genuine collision risk with any other mod that happens to define `is_dead` or
`isStuck` — which is the kind of thing that produces unexplainable cross-mod breakage.

Move them into `CfgFunctions` as `FPV_AI_Drones_fnc_*`. That also fixes the fragile bit where
`isStuck` (line 147) reads `_stuckThreshold` by scope inheritance from its caller rather than taking
it as a parameter.

---

### Tier 1 — Zeus support (the single most requested feature)

Six separate people asked for this, spread over eight months, and Kibbe_Surdo and
БАНДИТСКИЙ КРАЙ both explain why: the mod is currently only usable in prepared editor missions, which
rules out solo and dynamic play entirely.

There are two distinct pieces of work here, and the second is the one that's easy to miss.

**Piece 1 — make the modules appear in the Zeus interface.** Each module class needs curator scope:

```cpp
class FPV_AI_Drones_Module: Module_F {
    scope = 2;
    scopeCurator = 2;        // ← this is what puts it in the Zeus module tree
    curatorCanAttach = 1;    // ← lets Zeus drop it onto a specific drone
    // ...
};
```

The addon also has to be available to the curator — either the mission's Zeus module is set to "All
Addons", or you call `addCuratorAddons`. Worth documenting for users either way, because "I enabled
the mod and it's not in Zeus" will otherwise become the next wave of comments.

> **Verify before shipping:** I'm confident about `scopeCurator` / `curatorCanAttach`, but confirm the
> exact behaviour against the Biki `Module_F` page — Zeus module registration has changed across
> Arma versions and I could not check it offline.

**Piece 2 — teach `fn_initModule` how Zeus places modules.** This is the part that will silently fail
if you only do Piece 1. [`fn_initModule.sqf:28-38`](functions/fn_initModule.sqf) finds its drone by
iterating `_units`, the **editor-synced** units. Zeus doesn't sync — it attaches. So `_units` will be
empty and the module will exit at line 36 having done nothing.

Handle all three placement styles:

```sqf
private _targets = _units;
if (_targets isEqualTo []) then {
    private _attached = attachedTo _logic;                 // Zeus dropped it on a unit
    if (!isNull _attached) then { _targets = [_attached]; }
    else { _targets = (getPos _logic) nearEntities [["Air"], 50]; };  // dropped on empty ground
};
```

**Piece 3 — stop keying off `typeOf`.** [`fn_initModule.sqf:77`](functions/fn_initModule.sqf) selects
drones with `allUnitsUAV select {typeOf _x == _droneType}`. That means placing the module on *one*
Crocus quietly commandeers **every** Crocus on the map, including a player's own. In Zeus, where the
curator spawns drones ad hoc and mixes them with player assets, that will be actively disruptive.

Track the specific drone objects instead, and mark them:

```sqf
_uav setVariable ["FPV_AI_Drones_managed", true, true];
```

Then filter on that variable. This also gives you a clean opt-out for mission makers.

---

### Tier 2 — Signing, so the mod can run on servers

WoLFoR and Efremio both hit this, and it's a hard blocker: unsigned mods can't be verified, so any
server with `verifySignatures = 2` refuses them. It's also the cheapest item on this list.

Using Arma 3 Tools (from Steam → Library → Tools):

```
DSCreateKey.exe fpv_ai_drones_v1_1
DSSignFile.exe fpv_ai_drones_v1_1.biprivatekey addons\fpv_ai_drones.pbo
```

Ship this layout:

```
@FPV_AI_Drones/
  addons/fpv_ai_drones.pbo
  addons/fpv_ai_drones.pbo.fpv_ai_drones_v1_1.bisign
  keys/fpv_ai_drones_v1_1.bikey
```

Three things to get right:

1. **Never commit the `.biprivatekey`.** Anyone holding it can sign malicious PBOs that your users'
   servers will accept. The repo has no `.gitignore` at all right now — add one covering
   `*.biprivatekey` before you generate the key, not after.
2. **Version the key name** (`_v1_1`) and re-sign on every release. A stale `.bisign` fails
   verification just as hard as no signature.
3. Re-sign **after** any rebuild of the PBO — the signature is over the built file.

---

### Tier 3 — Why the drones behave badly

Four separate people report some version of "it doesn't work". These are distinct bugs, and one of
them is a documentation problem rather than a code problem.

#### 3.1 whiskey / gabberstabber: "synced Crocus with the module, drone just sits there"

**Hypothesis, but a strong one.** [`fn_initModule.sqf:30`](functions/fn_initModule.sqf) requires
`unitIsUAV _x`, and line 77 pulls from `allUnitsUAV`. A drone placed in the editor as an **empty
vehicle** — which is how most people place a Crocus — has no UAV crew, so it appears in neither. The
module then exits at line 36 with a message that is *off by default*, so the user gets total silence.
That matches whiskey's description precisely, and gabberstabber reports the same thing.

Two fixes, and you want both:

```sqf
// give it a crew if it has none
if (crew _x isEqualTo []) then { createVehicleCrew _x; };
```

…and make the "no UAV synchronized" failure visible regardless of the chat setting — a module that
silently does nothing when misconfigured is what generated these comments in the first place. Use
`diag_log` plus a one-time on-screen warning to the mission maker.

Then write the exact placement steps into the README (see Tier 5). whiskey literally asked "what are
the exact steps" and there is currently no answer anywhere.

#### 3.2 Fylon: "AT works, but AP just flies around me without doing anything"

**Hypothesis** — but the AP defaults differ from AT in a way that lines up well.

AP module: `AttackDistance = 30`, `AttackDistance2D = 8`, `AttackHeight = 8`.
AT module: `AttackDistance = 30`, `AttackDistance2D = 3`, `AttackHeight = 5`.

At [`fn_fpvLogic.sqf:267`](functions/fn_fpvLogic.sqf) the move vector is scaled to
`_predictedDistance + 1.5 * _attackDistance2D`, i.e. the drone deliberately aims *past* its target to
carry the ram through. For AT that overshoot is 4.5 m. For AP it's **12 m**. Against a slow vehicle a
12 m overshoot still clips; against infantry the drone flies well past, has to turn, overshoots
again — and reads to the player on the ground as a drone circling them harmlessly.

Try scaling the overshoot to the target rather than to `_attackDistance2D`, and drop AP's
`AttackDistance2D` toward the AT value.

#### 3.3 Headless_hashbrown: "they explode but don't kill anything"

Two candidate causes, both worth fixing:

- **The malformed `deleteVehicleCrew` in 0.4**, which sits directly on the detonation path.
- **AP detonation height.** The loop at line 195 exits once `_predictedDistance <= _attackDistance`
  *and* `_currentDistance2d <= _attackDistance2D`. With AP's `AttackHeight = 8`, the drone can satisfy
  both while hovering ~8 m above a man and then detonate `DemoCharge_Remote_Ammo` up there. Infantry
  survive that comfortably. AT gets away with it because vehicles are large and `SatchelCharge` is
  not subtle.

Add an explicit vertical check before detonating, so the drone must actually be close in **3D**:

```sqf
if ((getPosATL _uavInstance select 2) > _attackHeight + 2) then { /* keep descending */ };
```

Note that "explode in unison" is more likely the multiplayer duplication in 0.1 than a targeting
issue — fix that first, then re-test this.

---

### Tier 4 — Mod compatibility

#### VCOM AI — you've confirmed yourself that it misbehaves

VCOM continuously reasserts AI behaviour, movement and pathing. Your script sets `CARELESS`,
`forceSpeed 150` and issues `doMove` every fraction of a second; the two fight, and the drone stalls
or wanders. The fix is to exclude drones from VCOM entirely rather than to out-shout it.

VCOM exposes per-unit exclusion variables — set them on the drone and its crew at init, alongside
the `jac_bonusStealth` you already set at line 109.

> **Verify the exact names against current VCOM source before shipping** — they've changed between
> VCOM versions and I can't confirm them offline. Historically these have been of the form
> `VCM_NOPATHING` / `VCM_DISABLE` set via `setVariable` on the unit. The same applies to LAMBS
> Danger (`lambs_danger_disableAI`), which Fylon was using when they got it working via "task hunt".

That Fylon got results *only* through LAMBS task hunt is a useful signal: it suggests your own target
acquisition wasn't firing, and something else had to push the drone into contact.

#### Antistasi Ultimate / Dynamic Recon Ops

shark09stormYT and eth are really asking "does this work with dynamically spawned units?" Once you're
tracking drones by variable (Tier 1, Piece 3) instead of scanning `allUnitsUAV` by type, the honest
answer becomes "yes, if the mission spawns a drone and runs the module on it". Add a short
**Mission maker API** section to the README showing the direct call, so these frameworks can hook it
without the module at all.

---

### Tier 5 — Documentation and Workshop hygiene

Cheap, and it prevents the next round of identical comments.

- **`mod.cpp` still ships placeholders** — `author = "Your Name"` and
  `action = "https://github.com/yourusername/fpv_ai_drones"`. That's visible to every user in the
  launcher. Fix to your name and the real repo URL.
- **`logo.paa` is referenced four times in `mod.cpp` and does not exist** in the addon folder.
- **`README.md` is four lines.** It needs: exact editor placement steps (answering whiskey), the
  module parameter table, Zeus instructions once Tier 1 ships, server install + key instructions once
  Tier 2 ships, and a known-incompatibilities note.
- **`example.txt` documents an old `execVM "fpv.sqf"` API** that no longer exists in the repo. Delete
  it or rewrite it against the current function.
- **Add a `.gitignore`** — `*.biprivatekey`, `*.pbo`, build output.
- **Post a Workshop changelog** when the chat fix ships. Quarter and CoffeePot asked for exactly that
  and it's already done; there's no reason for them not to know.

One more thing worth doing: reply to STyx2909's linked mod and Jerry_Lee's "LAFS works so much
better". Not defensively — but a maintainer who's visibly active is the difference between "abandoned
mod" and "worth another try", and you have a genuine story to tell right now.

---

## 3. Suggested release split

| Release | Contents | Why |
|---------|----------|-----|
| **v1.1** | Tier 0 (all) + Tier 5 docs | Correctness + the chat fix people already asked for. Ship fast. |
| **v1.2** | Tier 2 signing + Tier 3 behaviour fixes | Makes it server-usable and actually lethal. |
| **v2.0** | Tier 1 Zeus + Tier 4 compat | The headline feature, on top of a codebase that works. |

Resisting the temptation to do Zeus first is the main judgement call here. Zeus is what people are
asking for loudest, but shipping it onto the current multiplayer duplication bug means six people
finally get Zeus support and immediately hit "the drones explode in unison and nothing dies" — which
is the complaint you're already getting.

---

## 4. Before you start: get RPT logging visible

Several bugs above (0.3, 0.4, 0.5) throw script errors that nobody has reported, because Arma hides
them by default. Launch with `-showScriptErrors` and watch:

```
%LOCALAPPDATA%\Arma 3\Arma3_x64_*.rpt
```

Fix whatever's already in there before adding features. Given 0.3 is on a reachable path, there is
almost certainly something in that log today.
