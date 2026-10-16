/*
    FPV AI Drones - automated test harness (server side).

    Plays each stage in turn, far enough apart that drones can't see each
    other's targets. Every check is written to the server RPT as

        FPV_TEST|<check>|<PASS|FAIL|INFO>|<detail>

    and the run ends with FPV_TEST|SUMMARY|<passed>/<total>, which
    tests/run_tests.ps1 watches for. The watching client's camera follows
    whatever FPVT_focus / FPVT_target point at.
*/

FPVT_results = [];
FPVT_finished = false;
publicVariable "FPVT_results";
publicVariable "FPVT_finished";

FPVT_fnc_report = {
    params ["_check", "_status", "_detail"];
    diag_log text format ["FPV_TEST|%1|%2|%3", _check, _status, _detail];
    if (_status != "INFO") then {
        FPVT_results pushBack [_check, _status, _detail];
        publicVariable "FPVT_results";
    };
};

FPVT_fnc_check = {
    params ["_check", "_ok", "_detail"];
    [_check, ["FAIL", "PASS"] select _ok, _detail] call FPVT_fnc_report;
};

FPVT_fnc_show = {
    params ["_caption", ["_focus", objNull], ["_target", objNull]];
    missionNamespace setVariable ["FPVT_caption", _caption, true];
    missionNamespace setVariable ["FPVT_focus", _focus, true];
    missionNamespace setVariable ["FPVT_target", _target, true];
};

// Targets must not shoot back or wander off - the drone is what's under test.
FPVT_fnc_passive = {
    params ["_grp"];
    _grp setCombatMode "BLUE";
    {
        _x disableAI "MOVE";
        _x disableAI "PATH";
        _x disableAI "AUTOTARGET";
        _x disableAI "TARGET";
    } forEach units _grp;
};

FPVT_fnc_spawnTank = {
    params ["_pos", ["_type", "O_MBT_02_cannon_F"]];   // B_MBT_01_cannon_F / I_MBT_03_cannon_F for other sides
    private _tank = createVehicle [_type, _pos, [], 0, "NONE"];
    createVehicleCrew _tank;
    [group effectiveCommander _tank] call FPVT_fnc_passive;
    _tank
};

FPVT_fnc_spawnSquad = {
    params ["_pos", "_count"];
    private _grp = createGroup [east, true];
    for "_i" from 0 to (_count - 1) do {
        private _u = _grp createUnit ["O_Soldier_F", _pos vectorAdd [(_i - (_count - 1) / 2) * 4, 0, 0], [], 0, "CAN_COLLIDE"];
        _u setUnitPos "UP";
    };
    [_grp] call FPVT_fnc_passive;
    units _grp
};

// Empty by default, like a drone placed as an empty vehicle.
FPVT_fnc_spawnDrone = {
    params ["_pos", ["_type", "B_Crocus_AT"], ["_crewed", false], ["_flying", false]];
    private _drone = createVehicle [_type, _pos, [], 0, ["CAN_COLLIDE", "FLY"] select _flying];
    if (_crewed) then { createVehicleCrew _drone; };
    _drone
};

// Stand-in for a placed module: a plain logic carrying the same variables the
// Eden attributes would set, handed straight to the module function.
FPVT_fnc_module = {
    params ["_pos", "_settings"];
    private _logic = (createGroup sideLogic) createUnit ["Logic", _pos, [], 0, "CAN_COLLIDE"];
    { _logic setVariable [_x select 0, _x select 1, true]; } forEach _settings;
    _logic
};

FPVT_fnc_vehicleDone = {
    params ["_veh"];
    !alive _veh
    || { ({alive _x} count crew _veh) == 0 }
    || { !canMove _veh && { !canFire _veh } }
};

// Runs until _doneFn says the target is finished, the drone has been gone a few
// seconds (so its blast has registered), or the timeout. Returns whether it timed out.
// Also logs the time-to-kill: seconds from the start of the wait until the target
// was finished (the drone usually starts on the ground, so this includes takeoff).
FPVT_fnc_await = {
    params ["_drone", "_target", "_doneFn", ["_timeout", 150]];
    private _start = time;
    private _deadline = time + _timeout;
    private _droneGoneAt = -1;
    // Fail fast: if the drone hasn't got 5 m closer to its target for 30 s (after 20 s
    // for takeoff), this attempt is going nowhere - stop instead of sitting out the timeout.
    private _best = 1e9;
    private _bestAt = time;
    private _stalled = false;
    while {
        !([_target] call _doneFn)
        && { _droneGoneAt < 0 || { time < _droneGoneAt + 4 } }
        && { time < _deadline }
        && { !_stalled }
    } do {
        if (_droneGoneAt < 0 && { !alive _drone }) then { _droneGoneAt = time; };
        private _aimAt = if (_target isEqualType []) then { (_target select { alive _x }) param [0, objNull] } else { _target };
        if (alive _drone && { !isNull _aimAt }) then {
            private _d = _drone distance _aimAt;
            if (_d < _best - 5) then { _best = _d; _bestAt = time; };
            if (time - _start > 20 && { time - _bestAt > 30 }) then { _stalled = true; };
        };
        sleep 0.5;
    };
    if (_stalled) then {
        ["stalled", "INFO", format ["no progress for 30 s (closest %1 m) - stopped early: %2",
            round _best, missionNamespace getVariable ["FPVT_caption", ""]]] call FPVT_fnc_report;
    };
    if ([_target] call _doneFn) then {
        ["ttk", "INFO", format ["%1s  %2", (time - _start) toFixed 1, missionNamespace getVariable ["FPVT_caption", ""]]] call FPVT_fnc_report;
    };
    sleep 3;   // let the camera hold on the result
    (time >= _deadline) || _stalled
};

// Waits until _drone is within _radius (2D) of _pos, or the timeout. Returns whether it got there.
FPVT_fnc_reach = {
    params ["_drone", "_pos", ["_radius", 40], ["_timeout", 120]];
    private _deadline = time + _timeout;
    while { alive _drone && { _drone distance2D _pos > _radius } && { time < _deadline } } do { sleep 0.5; };
    alive _drone && { _drone distance2D _pos <= _radius }
};

// Module defaults copied from config.cpp, so the scripted stages run with what
// a user gets from an untouched module.
FPVT_AT = [
    ["UnitKinds", "LandVehicle,Car,Tank"], ["TargetSource", "vehicles"],
    ["InitialSearchHeight", 30], ["TargetDetectionRange", 200],
    ["AttackDistance", 10], ["AttackDistance2D", 3], ["AttackHeight", 5],
    ["AllowObjectParent", true], ["CustomAmmo", "SatchelCharge_Remote_Ammo"],
    ["HeightAdjustmentDelay", 0.1], ["StuckCheckInterval", 20], ["StuckThreshold", 0.05],
    ["MoveAdjustmentDelay", 5], ["EnableChatMessages", true]
];
FPVT_AP = [
    ["UnitKinds", "Man"], ["TargetSource", "allUnits"],
    ["InitialSearchHeight", 50], ["TargetDetectionRange", 200],
    ["AttackDistance", 30], ["AttackDistance2D", 8], ["AttackHeight", 8],
    ["AllowObjectParent", false], ["CustomAmmo", "DemoCharge_Remote_Ammo"],
    ["HeightAdjustmentDelay", 0.25], ["StuckCheckInterval", 15], ["StuckThreshold", 0.1],
    ["MoveAdjustmentDelay", 5], ["EnableChatMessages", true]
];

// Which stage to start from - tests\run_tests.ps1 -StartStage writes this file.
FPVT_startStage = 1;
FPVT_stages = [];   // non-empty: run exactly these stages (run_tests.ps1 -Stages / -Quick)
FPVT_bench = 0;     // > 0: only the speed bench, this many rounds (run_tests.ps1 -Bench)
if (fileExists "testconfig.sqf") then { call compile preprocessFileLineNumbers "testconfig.sqf"; };
FPVT_fnc_runStage = { params ["_n"]; if (FPVT_stages isEqualTo []) then { _n >= FPVT_startStage } else { _n in FPVT_stages } };

// ---------------------------------------------------------------------------

["Waiting for the watching client to connect..."] call FPVT_fnc_show;
// allPlayers is only populated in multiplayer; in singleplayer the player is just "player".
FPVT_fnc_humans = { if (isMultiplayer) then { allPlayers - entities "HeadlessClient_F" } else { [player] select { !isNull _x } } };
if (isMultiplayer) then {
    waitUntil { sleep 1; count (call FPVT_fnc_humans) > 0 };
    sleep 10;   // client loading screen + camera setup
} else {
    // SP: the player already exists. Waiting on it here hung after an in-game Restart.
    sleep 3;
};
private _player = (call FPVT_fnc_humans) param [0, objNull];

["START", "INFO", format ["isDedicated=%1 moduleFn=%2 crocus=%3",
    isDedicated, !isNil "FPV_AI_Drones_fnc_initModule", isClass (configFile >> "CfgVehicles" >> "B_Crocus_AT")]] call FPVT_fnc_report;

if (isNil "FPV_AI_Drones_fnc_initModule") exitWith {
    ["START", "FAIL", "FPV_AI_Drones_fnc_initModule is not defined - is the mod loaded on the server?"] call FPVT_fnc_report;
    diag_log text "FPV_TEST|SUMMARY|0/1";
    FPVT_finished = true; publicVariable "FPVT_finished";
};

// --- Speed bench (run_tests.ps1 -Bench N) -----------------------------------
// The same two attacks - a parked tank and a car crossing in front of the drone
// at ~70 km/h - at close, medium and far range, N passes. Nothing else runs.
// Drones start on the ground, like a drone placed in the editor. The far range
// is past the default 200 m detection range, so that module gets 500 m.
// Compare the ttk lines (and the drones' "s after acquiring") between changes.
if (FPVT_bench > 0) then {
    FPVT_stages = [-1];   // no regular stages
    FPV_AI_Drones_debug = true;
    private _cleanup = { params ["_veh"]; if (!isNull _veh) then { { deleteVehicle _x } forEach crew _veh; deleteVehicle _veh; }; };
    for "_pass" from 1 to FPVT_bench do {
        {
            _x params ["_label", "_x0", "_tankDist", "_crossOffset", "_range"];
            private _settings = FPVT_AT + [["TargetDetectionRange", _range]];

            // A: parked tank.
            private _d = [[_x0, 1500, 0]] call FPVT_fnc_spawnDrone;
            _d setVariable ["FPV_AI_Drones_managed", true, true];
            private _t = [[_x0, 1500 + _tankDist, 0]] call FPVT_fnc_spawnTank;
            private _l = [[_x0 + 8, 1500, 0], _settings] call FPVT_fnc_module;
            [_l, [_d], true] call FPV_AI_Drones_fnc_initModule;
            [format ["Bench %1/%2 %3 - parked tank %4 m away", _pass, FPVT_bench, _label, _tankDist], _d, _t] call FPVT_fnc_show;
            private _to = [_d, _t, FPVT_fnc_vehicleDone, 90] call FPVT_fnc_await;
            [format ["bench %1 %2 parked tank %3m", _pass, _label, _tankDist], [_t] call FPVT_fnc_vehicleDone,
                format ["damage=%1 crewAlive=%2 timedOut=%3", damage _t toFixed 2, {alive _x} count crew _t, _to]] call FPVT_fnc_check;
            [_t] call _cleanup; [_d] call _cleanup; deleteVehicle _l;

            // B: car crossing _crossOffset m in front of the drone, northbound at ~70 km/h,
            // starting 100 m before it comes into detection range so it's at speed by then.
            _d = [[_x0, 4500, 0]] call FPVT_fnc_spawnDrone;
            _d setVariable ["FPV_AI_Drones_managed", true, true];
            private _carY = 4500 - (sqrt ((_range ^ 2) - (_crossOffset ^ 2))) - 100;
            private _car = createVehicle ["O_MRAP_02_F", [_x0 + _crossOffset, _carY, 0], [], 0, "NONE"];
            _car setDir 0;
            createVehicleCrew _car;
            private _cg = group effectiveCommander _car;
            _cg setBehaviour "CARELESS";
            _cg setCombatMode "BLUE";
            _cg setSpeedMode "FULL";
            { _x disableAI "AUTOTARGET"; _x disableAI "TARGET"; } forEach units _cg;
            _car limitSpeed 70;   // km/h
            _cg addWaypoint [[_x0 + _crossOffset, 7900, 0], 0];
            _l = [[_x0 + 8, 4500, 0], _settings] call FPVT_fnc_module;
            [_l, [_d], true] call FPV_AI_Drones_fnc_initModule;
            [format ["Bench %1/%2 %3 - car crossing %4 m out at ~70 km/h", _pass, FPVT_bench, _label, _crossOffset], _d, _car] call FPVT_fnc_show;
            FPVT_moverSpeed = -1;
            private _watch = [_car] spawn { params ["_m"]; while { alive _m } do { FPVT_moverSpeed = speed _m; sleep 0.5; }; };
            _to = [_d, _car, FPVT_fnc_vehicleDone, 90] call FPVT_fnc_await;
            terminate _watch;
            [format ["bench %1 %2 crossing car %3m", _pass, _label, _crossOffset], [_car] call FPVT_fnc_vehicleDone,
                format ["damage=%1 crewAlive=%2 carSpeedBeforeHit=%3km/h timedOut=%4",
                    damage _car toFixed 2, {alive _x} count crew _car, round FPVT_moverSpeed, _to]] call FPVT_fnc_check;
            [_car] call _cleanup; [_d] call _cleanup; deleteVehicle _l;
        } forEach [
            // label     column  tank  crossing  detection range
            ["close",    2500,    60,     60,     200],
            ["medium",   4000,   150,    120,     200],
            ["far",      5500,   400,    300,     500]
        ];

        // C: parked tank 150 m away, tucked in right behind a building - a straight
        // shallow dive would go into the wall.
        private _d = [[7000, 1500, 0]] call FPVT_fnc_spawnDrone;
        _d setVariable ["FPV_AI_Drones_managed", true, true];
        private _wall = createVehicle ["Land_Cargo_HQ_V1_F", [7000, 1636, 0], [], 0, "CAN_COLLIDE"];
        private _t = [[7000, 1647, 0]] call FPVT_fnc_spawnTank;
        private _bb = boundingBoxReal _wall;
        ["bench cover", "INFO", format ["%1 height %2 m, tank %3 m behind its centre",
            typeOf _wall, (((_bb select 1) select 2) - ((_bb select 0) select 2)) toFixed 1, round (_wall distance2D _t)]] call FPVT_fnc_report;
        private _l = [[7008, 1500, 0], FPVT_AT] call FPVT_fnc_module;
        [_l, [_d], true] call FPV_AI_Drones_fnc_initModule;
        [format ["Bench %1/%2 cover - tank parked behind a building", _pass, FPVT_bench], _d, _t] call FPVT_fnc_show;
        private _to = [_d, _t, FPVT_fnc_vehicleDone, 90] call FPVT_fnc_await;
        [format ["bench %1 cover parked tank behind building", _pass], [_t] call FPVT_fnc_vehicleDone,
            format ["damage=%1 crewAlive=%2 timedOut=%3", damage _t toFixed 2, {alive _x} count crew _t, _to]] call FPVT_fnc_check;
        [_t] call _cleanup; [_d] call _cleanup; deleteVehicle _l; deleteVehicle _wall;

        // D: Anti-Personnel drone vs a 4-man squad 150 m away.
        _d = [[7000, 4500, 0], "B_Crocus_AP"] call FPVT_fnc_spawnDrone;
        _d setVariable ["FPV_AI_Drones_managed", true, true];
        private _squad = [[7000, 4650, 0], 4] call FPVT_fnc_spawnSquad;
        _l = [[7008, 4500, 0], FPVT_AP] call FPVT_fnc_module;
        [_l, [_d], true] call FPV_AI_Drones_fnc_initModule;
        [format ["Bench %1/%2 infantry - AP drone vs 4-man squad 150 m away", _pass, FPVT_bench], _d, _squad select 0] call FPVT_fnc_show;
        _to = [_d, _squad, { params ["_units"]; ({alive _x} count _units) == 0 }, 90] call FPVT_fnc_await;
        [format ["bench %1 infantry squad 150m", _pass], ({!alive _x} count _squad) > 0,
            format ["killed %1/4 timedOut=%2", {!alive _x} count _squad, _to]] call FPVT_fnc_check;
        { deleteVehicle _x } forEach _squad; [_d] call _cleanup; deleteVehicle _l;
    };
};

private ["_drone", "_tank", "_logic", "_timedOut"];

if ([1] call FPVT_fnc_runStage) then {
// --- Stage 1: the real Eden path -------------------------------------------
// The mission.sqm places an EMPTY Crocus synced to an untouched AT module.
// That module ran at mission start, before anyone connected; the drone has
// been hovering since, waiting for something to hunt.
_drone = missionNamespace getVariable ["t1_drone", objNull];
private _edenModule = (allMissionObjects "FPV_AI_Drones_AT_Module") param [0, objNull];

["1a empty drone got a crew", count crew _drone > 0,
    format ["crew=%1 (an empty drone used to be ignored entirely)", count crew _drone]] call FPVT_fnc_check;
["1b drone tagged as managed", _drone getVariable ["FPV_AI_Drones_managed", false], ""] call FPVT_fnc_check;
// An untouched AT module must run on the AT preset, not the generic fallbacks.
// initModule writes the resolved values back onto the module.
private _ish = _edenModule getVariable ["InitialSearchHeight", -1];
private _ad = _edenModule getVariable ["AttackDistance", -1];
private _had = _edenModule getVariable ["HeightAdjustmentDelay", -1];
["1c untouched module uses its own preset", _ish == 30 && { _ad == 10 } && { _had == 0.1 },
    format ["InitialSearchHeight=%1 AttackDistance=%2 HeightAdjustmentDelay=%3 (AT preset is 30/10/0.1)", _ish, _ad, _had]] call FPVT_fnc_check;

_tank = [[2000, 2150, 0]] call FPVT_fnc_spawnTank;
["Stage 1/11 - Eden: empty Crocus synced to the Anti-Tank module", _drone, _tank] call FPVT_fnc_show;
_timedOut = [_drone, _tank, FPVT_fnc_vehicleDone] call FPVT_fnc_await;
["1d drone destroyed the tank", [_tank] call FPVT_fnc_vehicleDone,
    format ["tank alive=%1 damage=%2 crewAlive=%3 timedOut=%4", alive _tank, damage _tank toFixed 2, {alive _x} count crew _tank, _timedOut]] call FPVT_fnc_check;

};

if ([2] call FPVT_fnc_runStage) then {
// --- Stage 2: Anti-Personnel vs infantry -----------------------------------
// The "AP just circles me" and "explodes but kills nobody" reports.
_drone = [[3000, 2000, 0], "B_Crocus_AP"] call FPVT_fnc_spawnDrone;
private _squad = [[3000, 2150, 0], 4] call FPVT_fnc_spawnSquad;
_logic = [[3008, 2000, 0], FPVT_AP] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;

["Stage 2/11 - Anti-Personnel drone vs a 4-man squad", _drone, _squad select 0] call FPVT_fnc_show;
_timedOut = [_drone, _squad, { params ["_units"]; ({alive _x} count _units) == 0 }] call FPVT_fnc_await;
private _killed = {!alive _x} count _squad;
["2a AP drone killed infantry", _killed > 0,
    format ["killed %1/%2, drone alive=%3, timedOut=%4", _killed, count _squad, alive _drone, _timedOut]] call FPVT_fnc_check;

};

if ([3] call FPVT_fnc_runStage) then {
// --- Stage 3: Zeus, module dropped onto a drone ----------------------------
// Zeus attaches the module instead of syncing it, so _units arrives empty.
// A second, crewed drone of the same class stands in for a player's own drone:
// it must be left alone (the old code grabbed every drone of the type).
_drone = [[4000, 2000, 0]] call FPVT_fnc_spawnDrone;
private _decoy = [[4000, 1700, 0], "B_Crocus_AT", true] call FPVT_fnc_spawnDrone;
_tank = [[4000, 2150, 0]] call FPVT_fnc_spawnTank;
_logic = [getPosATL _drone, FPVT_AT] call FPVT_fnc_module;
_logic attachTo [_drone, [0, 0, 0]];

FPVT_decoyTouched = false;
private _watch = [_decoy] spawn {
    params ["_d"];
    while {true} do {
        if ((_d getVariable ["initialized", false]) || { _d getVariable ["FPV_AI_Drones_managed", false] }) then {
            FPVT_decoyTouched = true;
        };
        sleep 0.25;
    };
};

[_logic, [], true] call FPV_AI_Drones_fnc_initModule;
["Stage 3/11 - Zeus-style: module attached to the drone, nothing synced", _drone, _tank] call FPVT_fnc_show;
_timedOut = [_drone, _tank, FPVT_fnc_vehicleDone] call FPVT_fnc_await;
terminate _watch;
["3a attached module destroyed the tank", [_tank] call FPVT_fnc_vehicleDone,
    format ["tank alive=%1 damage=%2 crewAlive=%3 timedOut=%4", alive _tank, damage _tank toFixed 2, {alive _x} count crew _tank, _timedOut]] call FPVT_fnc_check;
["3b same-class drone left alone (option off)", !FPVT_decoyTouched,
    "a crewed B_Crocus_AT 300m away must not be taken over by the module"] call FPVT_fnc_check;

};

if ([4] call FPVT_fnc_runStage) then {
// --- Stage 4: Zeus, module dropped on the ground near a drone ---------------
_drone = [[5000, 2000, 0]] call FPVT_fnc_spawnDrone;
_tank = [[5000, 2150, 0]] call FPVT_fnc_spawnTank;
_logic = [[5040, 2000, 0], FPVT_AT] call FPVT_fnc_module;
[_logic, [], true] call FPV_AI_Drones_fnc_initModule;

["4a ground-placed module adopted the drone 40m away", _drone getVariable ["FPV_AI_Drones_managed", false], ""] call FPVT_fnc_check;
["Stage 4/11 - Zeus-style: module placed on the ground 40m from the drone", _drone, _tank] call FPVT_fnc_show;
_timedOut = [_drone, _tank, FPVT_fnc_vehicleDone] call FPVT_fnc_await;
["4b adopted drone destroyed the tank", [_tank] call FPVT_fnc_vehicleDone,
    format ["tank alive=%1 damage=%2 crewAlive=%3 timedOut=%4", alive _tank, damage _tank toFixed 2, {alive _x} count crew _tank, _timedOut]] call FPVT_fnc_check;

};

if ([5] call FPVT_fnc_runStage) then {
// --- Stage 5: module placed FIRST, drone added near it afterwards ----------
// The Zeus "drone station" workflow: place the module once, then put drones next
// to it. Previously a module that found no drone gave up for good.
private _managedBefore = count (vehicles select { _x getVariable ["FPV_AI_Drones_managed", false] });
_logic = [[6000, 2000, 0], FPVT_AT] call FPVT_fnc_module;
["Stage 5/11 - module placed with no drone: should say it's waiting, and take nothing", objNull, _logic] call FPVT_fnc_show;
[_logic, [], true] call FPV_AI_Drones_fnc_initModule;
sleep 6;
private _managedAfter = count (vehicles select { _x getVariable ["FPV_AI_Drones_managed", false] });
["5a lonely module took nothing", _managedAfter == _managedBefore,
    format ["managed drones before=%1 after=%2 (the waiting message shows in chat)", _managedBefore, _managedAfter]] call FPVT_fnc_check;

// Now a drone is put down inside its area, crewed as Zeus would place it.
_drone = [[6040, 2000, 0], "B_Crocus_AT", true] call FPVT_fnc_spawnDrone;
_tank = [[6040, 2150, 0]] call FPVT_fnc_spawnTank;
["Stage 5/11 - drone placed next to the waiting module afterwards: must be picked up", _drone, _tank] call FPVT_fnc_show;
private _pickupDeadline5 = time + 10;
waitUntil { sleep 0.5; (_drone getVariable ["FPV_AI_Drones_managed", false]) || { time > _pickupDeadline5 } };
private _picked = _drone getVariable ["FPV_AI_Drones_managed", false];
["5b drone placed later in the module's area picked up", _picked, format ["managed=%1 within 10s", _picked]] call FPVT_fnc_check;
if (_picked) then {
    _timedOut = [_drone, _tank, FPVT_fnc_vehicleDone] call FPVT_fnc_await;
    ["5c picked-up drone killed the tank", [_tank] call FPVT_fnc_vehicleDone,
        format ["tank alive=%1 damage=%2 crewAlive=%3 timedOut=%4", alive _tank, damage _tank toFixed 2, {alive _x} count crew _tank, _timedOut]] call FPVT_fnc_check;
} else {
    ["5c picked-up drone killed the tank", false, "skipped - the drone was never picked up"] call FPVT_fnc_check;
};

};

if ([6] call FPVT_fnc_runStage) then {
// --- Stage 6: plain drones + waypoint, no FPV module -------------------------
// Baseline for "it doesn't move when I send it via Zeus": does the Crocus follow
// a waypoint at all, with none of our code involved - from the ground, and when
// already flying? These are INFO, not PASS/FAIL: they describe the Crocus mod /
// vanilla AI, which this mod doesn't control.
{
    _x params ["_check", "_x0", "_flying", "_caption"];
    _drone = [[_x0, 4000, 0], "B_Crocus_AT", true, _flying] call FPVT_fnc_spawnDrone;
    private _wpPos = [_x0, 4400, 0];
    private _marker = createVehicle ["Sign_Arrow_Large_F", _wpPos, [], 0, "CAN_COLLIDE"];
    private _grp = group _drone;
    _grp addWaypoint [_wpPos, 0];
    _grp setCurrentWaypoint [_grp, (count waypoints _grp) - 1];   // as Zeus does
    [_caption, _drone, _marker] call FPVT_fnc_show;
    private _reached = [_drone, _wpPos, 40, 60] call FPVT_fnc_reach;
    [_check, "INFO", format ["reached=%1 distance to waypoint %2m, height %3m, alive=%4",
        _reached, round (_drone distance2D _wpPos), round ((getPosATL _drone) select 2), alive _drone]] call FPVT_fnc_report;
    sleep 2;
} forEach [
    ["6a plain drone on the ground + waypoint", 1500, false, "Stage 6/11 - plain drone ON THE GROUND, no module, given a waypoint"],
    ["6b plain drone already flying + waypoint", 2500, true, "Stage 6/11 - plain drone ALREADY FLYING, no module, given a waypoint"]
];

};

if ([7] call FPVT_fnc_runStage) then {
// --- Stage 7: module-managed drone sent by waypoint toward an enemy ---------
// The real Zeus workflow: the tank starts out of detection range, so the drone
// must actually follow the waypoint, spot the tank on the way, and attack.
_drone = [[3000, 4000, 0], "B_Crocus_AT", true] call FPVT_fnc_spawnDrone;
_wpPos = [3000, 4400, 0];
_tank = [[3000, 4500, 0]] call FPVT_fnc_spawnTank;   // 500m from the start, 100m past the waypoint
_logic = [getPosATL _drone, FPVT_AT] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
private _grp7 = group _drone;
_grp7 addWaypoint [_wpPos, 0];
_grp7 setCurrentWaypoint [_grp7, (count waypoints _grp7) - 1];   // as Zeus does
["Stage 7/11 - managed drone sent by waypoint toward a tank that starts out of range", _drone, _tank] call FPVT_fnc_show;
// Flight trace: shows whether the drone takes off, which waypoint the group is on,
// and whether it is moving at all - the "it just sits there" question.
private _trace = [_drone, _grp7] spawn {
    params ["_d", "_g"];
    private _last = "";
    while { alive _d } do {
        // Rounded to 10m / 10km/h so it only prints when something actually changes.
        private _now = format ["h=%1m speed=%2km/h toWp=%3m engine=%4 expectedDest=%5",
            round (((getPosATL _d) select 2) / 10) * 10, round (speed _d / 10) * 10,
            round ((_d distance2D [3000, 4400, 0]) / 10) * 10, isEngineOn _d, (expectedDestination _d) select 1];
        if (_now != _last) then { ["7 trace", "INFO", _now] call FPVT_fnc_report; _last = _now; };
        sleep 2;
    };
};
_timedOut = [_drone, _tank, FPVT_fnc_vehicleDone, 150] call FPVT_fnc_await;
["7a managed drone followed the waypoint and killed the tank", [_tank] call FPVT_fnc_vehicleDone,
    format ["tank alive=%1 damage=%2 crewAlive=%3 drone alive=%4 droneToTank=%5m timedOut=%6",
        alive _tank, damage _tank toFixed 2, {alive _x} count crew _tank, alive _drone,
        if (alive _drone) then { round (_drone distance2D _tank) } else { "-" }, _timedOut]] call FPVT_fnc_check;
terminate _trace;

};

if ([8] call FPVT_fnc_runStage) then {
// --- Stage 8: drone AND module created on the player's machine, like Zeus ----
// In multiplayer, everything a Zeus places belongs to the Zeus player's machine:
// the module (its init runs there) and the drone with its AI crew. The server
// must take the module AND take ownership of the drone - its attack logic only
// drives drones it owns. Found by hand: a Zeus-placed drone that just sat there.
_tank = [[4000, 4150, 0]] call FPVT_fnc_spawnTank;
missionNamespace setVariable ["FPVT_s8drone", objNull, true];
[[], {
    private _d = createVehicle ["B_Crocus_AT", [4000, 4000, 0], [], 0, "CAN_COLLIDE"];
    createVehicleCrew _d;
    private _m = (createGroup sideLogic) createUnit ["FPV_AI_Drones_AT_Module", getPosATL _d, [], 0, "CAN_COLLIDE"];
    _m attachTo [_d, [0, 0, 0]];
    missionNamespace setVariable ["FPVT_s8drone", _d, true];
    // Exactly what the mod's CuratorObjectPlaced handler does when Zeus places a
    // module. Only the event itself firing needs a real Zeus click to verify.
    [objNull, _m] call FPV_AI_Drones_fnc_curatorPlaced;
}] remoteExec ["call", _player];

private _pickupDeadline = time + 15;
waitUntil { sleep 0.5; !isNull (missionNamespace getVariable ["FPVT_s8drone", objNull]) || { time > _pickupDeadline } };
_drone = missionNamespace getVariable ["FPVT_s8drone", objNull];
["Stage 8/11 - drone AND module placed from YOUR machine, like Zeus in multiplayer", _drone, _tank] call FPVT_fnc_show;
waitUntil { sleep 0.5; ((_drone getVariable ["FPV_AI_Drones_managed", false]) && { local _drone }) || { time > _pickupDeadline } };
private _managed = (_drone getVariable ["FPV_AI_Drones_managed", false]) && { local _drone };
["8a player-placed drone + module: server took both", _managed,
    format ["managed=%1 droneOwnedByServer=%2 after %3s (single-player=%4)",
        _drone getVariable ["FPV_AI_Drones_managed", false], local _drone, round (time - _pickupDeadline + 15), !isMultiplayer]] call FPVT_fnc_check;
if (_managed) then {
    _timedOut = [_drone, _tank, FPVT_fnc_vehicleDone] call FPVT_fnc_await;
    ["8b client-created module's drone killed the tank", [_tank] call FPVT_fnc_vehicleDone,
        format ["tank alive=%1 damage=%2 crewAlive=%3 timedOut=%4", alive _tank, damage _tank toFixed 2, {alive _x} count crew _tank, _timedOut]] call FPVT_fnc_check;
} else {
    ["8b client-created module's drone killed the tank", false, "skipped - the module never started"] call FPVT_fnc_check;
};

};

if ([9] call FPVT_fnc_runStage) then {
// --- Stage 9: "Control All Drones Of This Type" ----------------------------
// A drone spawned AFTER the module, never synced or placed on, must be taken
// over because it is the same type - how the mod originally behaved, and how
// Zeus users expect it to work: place one module, then keep spawning drones.
// Independent drones: a type no other stage uses, so no other module can claim it.
_drone = [[5000, 4000, 0], "I_Crocus_AP", true] call FPVT_fnc_spawnDrone;
_logic = [getPosATL _drone, FPVT_AT + [["TakeOverAllOfType", true]]] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
sleep 3;
private _late = [[6000, 4000, 0], "I_Crocus_AP", true] call FPVT_fnc_spawnDrone;   // 1km away, not synced
_tank = [[6000, 4150, 0]] call FPVT_fnc_spawnTank;
["Stage 9/11 - same-type drone spawned AFTER the module, never synced: must be taken over", _late, _tank] call FPVT_fnc_show;

private _adoptDeadline = time + 10;
waitUntil { sleep 0.5; (_late getVariable ["FPV_AI_Drones_managed", false]) || { time > _adoptDeadline } };
private _adopted = _late getVariable ["FPV_AI_Drones_managed", false];
["9a later same-type drone taken over", _adopted, format ["managed=%1 within 10s", _adopted]] call FPVT_fnc_check;
if (_adopted) then {
    _timedOut = [_late, _tank, FPVT_fnc_vehicleDone] call FPVT_fnc_await;
    ["9b taken-over drone killed the tank", [_tank] call FPVT_fnc_vehicleDone,
        format ["tank alive=%1 damage=%2 crewAlive=%3 timedOut=%4", alive _tank, damage _tank toFixed 2, {alive _x} count crew _tank, _timedOut]] call FPVT_fnc_check;
} else {
    ["9b taken-over drone killed the tank", false, "skipped - the drone was never taken over"] call FPVT_fnc_check;
};
};

if ([10] call FPVT_fnc_runStage) then {
// --- Stage 10: Target Sides -------------------------------------------------
// Each case puts a tank the drone must IGNORE closer than the tank it must hit, so
// a wrong choice shows straight away. 10a/10b use the default (the mission's side
// relations, set here), 10c an explicit side. Relations are restored afterwards.
private _savedRelations = [resistance getFriend west, west getFriend resistance, resistance getFriend east, east getFriend resistance];
FPVT_fnc_guerRelations = {
    params ["_withWest", "_withEast"];   // 1 = friendly, 0 = hostile
    resistance setFriend [west, _withWest]; west setFriend [resistance, _withWest];
    resistance setFriend [east, _withEast]; east setFriend [resistance, _withEast];
};
FPVT_fnc_untouched = {
    params ["_veh"];
    alive _veh && { damage _veh < 0.05 } && { ({ !alive _x } count crew _veh) == 0 }
};
FPVT_fnc_sideCase = {
    params ["_check", "_caption", "_droneType", "_dronePos", "_sides", "_hitType", "_hitPos", "_ignoreType", "_ignorePos"];
    private _d = [_dronePos, _droneType] call FPVT_fnc_spawnDrone;
    // Claimed at once: the stage 8 module takes over unclaimed Crocus AT drones (its default types).
    _d setVariable ["FPV_AI_Drones_managed", true, true];
    private _hit = [_hitPos, _hitType] call FPVT_fnc_spawnTank;
    private _ignore = [_ignorePos, _ignoreType] call FPVT_fnc_spawnTank;
    private _l = [_dronePos vectorAdd [8, 0, 0], FPVT_AT + [["TargetSides", _sides]]] call FPVT_fnc_module;
    [_l, [_d], true] call FPV_AI_Drones_fnc_initModule;
    [_caption, _d, _hit] call FPVT_fnc_show;
    private _to = [_d, _hit, FPVT_fnc_vehicleDone] call FPVT_fnc_await;
    private _hitDone = [_hit] call FPVT_fnc_vehicleDone;
    private _ignored = [_ignore] call FPVT_fnc_untouched;
    [_check, _hitDone && _ignored, format ["drone side %1, setting %2 | hit %3: done=%4 damage=%5 | ignore %6: damage=%7 deadCrew=%8 | timedOut=%9",
        side _d, _sides, _hitType, _hitDone, damage _hit toFixed 2, _ignoreType, damage _ignore toFixed 2, { !alive _x } count crew _ignore, _to]] call FPVT_fnc_check;
};

// 10a/10b check the default (mission relations), which already worked in v1.1 -
// full suite only, so quick runs (-Quick / -Stages) spend their time on 10c.
if (FPVT_stages isEqualTo []) then {
    // 10a: Independent drone, Independent friendly to BLUFOR and hostile to OPFOR.
    [1, 0] call FPVT_fnc_guerRelations;
    ["10a Independent drone hits OPFOR, ignores friendly BLUFOR", "Stage 10/11 - Independent drone: hit OPFOR, ignore the closer friendly BLUFOR tank",
        "I_Crocus_AT", [1500, 6000, 0], "ENEMIES", "O_MBT_02_cannon_F", [1600, 6150, 0], "B_MBT_01_cannon_F", [1450, 6110, 0]] call FPVT_fnc_sideCase;

    // 10b: same drone type, relations flipped.
    [0, 1] call FPVT_fnc_guerRelations;
    ["10b relations flipped: hits BLUFOR, ignores friendly OPFOR", "Stage 10/11 - relations flipped: hit BLUFOR, ignore the closer friendly OPFOR tank",
        "I_Crocus_AT", [2500, 6000, 0], "ENEMIES", "B_MBT_01_cannon_F", [2600, 6150, 0], "O_MBT_02_cannon_F", [2450, 6110, 0]] call FPVT_fnc_sideCase;
};

// 10c: explicit side overrides relations - a BLUFOR drone set to Independent only
// hits a (friendly by default) Independent tank and ignores a closer hostile OPFOR one.
[1, 0] call FPVT_fnc_guerRelations;
["10c 'Independent only' setting overrides relations", "Stage 10/11 - BLUFOR drone set to Independent only: ignore the closer OPFOR tank",
    "B_Crocus_AT", [3500, 6000, 0], "GUER", "I_MBT_03_cannon_F", [3600, 6150, 0], "O_MBT_02_cannon_F", [3450, 6110, 0]] call FPVT_fnc_sideCase;

resistance setFriend [west, _savedRelations select 0]; west setFriend [resistance, _savedRelations select 1];
resistance setFriend [east, _savedRelations select 2]; east setFriend [resistance, _savedRelations select 3];
};

if ([11] call FPVT_fnc_runStage) then {
// --- Stage 11: moving target ------------------------------------------------
// A tank driving at ~40 km/h. It starts out of range and passes the drone at
// ~150 m, so the drone must catch a moving target rather than a parked one.
_drone = [[4500, 6000, 0]] call FPVT_fnc_spawnDrone;
_drone setVariable ["FPV_AI_Drones_managed", true, true];   // see stage 10 - claim before another module can
private _mover = createVehicle ["O_MBT_02_cannon_F", [4650, 5800, 0], [], 0, "NONE"];
_mover setDir 0;
createVehicleCrew _mover;
private _mg = group effectiveCommander _mover;
_mg setBehaviour "CARELESS";
_mg setCombatMode "BLUE";
{ _x disableAI "AUTOTARGET"; _x disableAI "TARGET"; } forEach units _mg;
_mover limitSpeed 40;   // km/h
_mg addWaypoint [[4650, 7600, 0], 0];
_logic = [[4508, 6000, 0], FPVT_AT] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
["Stage 11/11 - tank driving at ~40 km/h past the drone", _drone, _mover] call FPVT_fnc_show;
private _speedWatch = [_mover] spawn { params ["_m"]; while { alive _m } do { FPVT_moverSpeed = speed _m; sleep 1; }; };
_timedOut = [_drone, _mover, FPVT_fnc_vehicleDone] call FPVT_fnc_await;
terminate _speedWatch;
["11a moving tank hit", [_mover] call FPVT_fnc_vehicleDone,
    format ["tank alive=%1 damage=%2 crewAlive=%3 tankSpeedBeforeHit=%4km/h timedOut=%5",
        alive _mover, damage _mover toFixed 2, { alive _x } count crew _mover, round (missionNamespace getVariable ["FPVT_moverSpeed", -1]), _timedOut]] call FPVT_fnc_check;
};

// --- Summary + hand over Zeus for manual poking -----------------------------
private _passed = { (_x select 1) == "PASS" } count FPVT_results;
diag_log text format ["FPV_TEST|SUMMARY|%1/%2", _passed, count FPVT_results];

if (!isMultiplayer) then {
    // SP: hand Zeus to whoever "player" is now (it can be briefly null right after a restart).
    private _until = time + 30;
    waitUntil { sleep 0.5; !isNull player || { time > _until } };
    _player = player;
};
if (!isNull _player) then {
    private _curator = (createGroup sideLogic) createUnit ["ModuleCurator_F", [0, 0, 0], [], 0, "NONE"];
    sleep 1;
    _player assignCurator _curator;
    _curator addCuratorAddons activatedAddons;
    ["ZEUS", "INFO", format ["curator assigned to %1", name _player]] call FPVT_fnc_report;
};

[format ["Done - %1 of %2 checks passed. Press Y for Zeus and try placing the module yourself.", _passed, count FPVT_results]] call FPVT_fnc_show;
FPVT_finished = true;
publicVariable "FPVT_finished";
