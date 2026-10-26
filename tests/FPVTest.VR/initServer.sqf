/*
    FPV AI Drones - automated test harness (server side).

    Plays each stage in turn, far enough apart that drones can't see each
    other's targets. Every check is written to the server RPT as

        FPV_TEST|<check>|<PASS|FAIL|INFO>|<detail>

    and the run ends with FPV_TEST|SUMMARY|<passed>/<total>, which
    tests/run_tests.py watches for. The watching client's camera follows
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
    // FPVT_set (run_tests.py --set) comes last, so it overrides a stage's own settings.
    { _logic setVariable [_x select 0, _x select 1, true]; } forEach (_settings + FPVT_set);
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
        private _aimAt = if (_target isEqualType []) then { (_target select { alive _x }) param [0, objNull] } else { _target };
        ["stalled", "INFO", format ["no progress for 30 s (closest %1 m) - stopped early: %2 | drone %3 at %4 agl %5 speed %6 | target at %7 speed %8",
            round _best, missionNamespace getVariable ["FPVT_caption", ""], _drone, (getPosATL _drone) apply { round _x },
            round ((getPosATL _drone) select 2), round speed _drone, (getPosATL _aimAt) apply { round _x }, round speed _aimAt]] call FPVT_fnc_report;
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

// Which stage to start from - tests/run_tests.py --start-stage writes this file.
FPVT_startStage = 1;
FPVT_stages = [];   // non-empty: run exactly these stages (run_tests.py --stages / --quick)
FPVT_bench = 0;     // > 0: only the speed bench, this many rounds (run_tests.py --bench)
FPVT_compat = [];   // [[drone class, payload], ...]: only the other-mods drone check (run_tests.py --compat)
FPVT_headless = false;   // dedicated server with no one watching (run_tests.py --headless): don't wait for a client
FPVT_benchCases = [];   // non-empty: only these bench cases - close/medium/far/cover/infantry/dodge/swarm (run_tests.py --bench-cases)
FPVT_set = [];   // [[module setting, value], ...] for every module in the run (run_tests.py --set), e.g. [["BrakingTime", 2.5]]
if (fileExists "testconfig.sqf") then { call compile preprocessFileLineNumbers "testconfig.sqf"; };
FPVT_fnc_runStage = { params ["_n"]; if (FPVT_stages isEqualTo []) then { _n >= FPVT_startStage } else { _n in FPVT_stages } };

// --- Other mods' drones, set up like an Eden mission (run_tests.py --compat) ----
// Reported for the "Ukraine FPV Drone" mod: a drone synced to the AT module with
// waypoints MOVE, MOVE, CYCLE flew its loop, then hung in the air tilting once an
// enemy vehicle came close. Everything is created here, at mission start and before
// any player joins, so the order of init scripts matches Eden: the module takes the
// drone at time 0, the other mod's own drone init runs after time 1. The payload
// variable is what that mod's Eden "Payload" attribute sets.
FPVT_compatCases = [];
if (FPVT_compat isNotEqualTo []) then {
    {
        _x params ["_type", ["_payload", ""]];
        private _x0 = 1500 + _forEachIndex * 1500;
        private _home = [_x0, 5000, 0];
        private _drone = objNull;
        isNil {   // unscheduled: the payload must be set before that mod's init script looks
            _drone = createVehicle [_type, _home, [], 0, "CAN_COLLIDE"];
            createVehicleCrew _drone;
            if (_payload != "") then { _drone setVariable ["UA_FPV_PayloadType", _payload, true]; };
        };
        private _grp = group _drone;
        (_grp addWaypoint [[_x0, 5300, 0], 0]) setWaypointType "MOVE";
        (_grp addWaypoint [[_x0 + 300, 5300, 0], 0]) setWaypointType "MOVE";
        (_grp addWaypoint [_home, 0]) setWaypointType "CYCLE";
        private _l = [_home vectorAdd [8, 0, 0], FPVT_AT] call FPVT_fnc_module;
        [_l, [_drone], true] call FPV_AI_Drones_fnc_initModule;
        FPVT_compatCases pushBack [_type, _payload, _drone, _home];
    } forEach FPVT_compat;
};

// ---------------------------------------------------------------------------

["Waiting for the watching client to connect..."] call FPVT_fnc_show;
// allPlayers is only populated in multiplayer; in singleplayer the player is just "player".
FPVT_fnc_humans = { if (isMultiplayer) then { allPlayers - entities "HeadlessClient_F" } else { [player] select { !isNull _x } } };
if (isMultiplayer) then {
    if (FPVT_headless) exitWith { sleep 5; };
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

// --- Other mods' drones: the run (set up at mission start, see above) ---------
// Per drone: watch it fly its loop, then send an enemy car through the middle of
// the loop at ~40 km/h. A drone state line is logged every few seconds.
if (FPVT_compatCases isNotEqualTo []) then {
    FPVT_stages = [-1];
    FPV_AI_Drones_debug = true;
    // The other mod may replace the drone with a new object (its payload swap does):
    // then follow whatever drone is now where this one was.
    private _follow = {
        params ["_d", "_lastPos"];
        if (!isNull _d && { alive _d }) exitWith { _d };
        ((_lastPos nearEntities ["Air", 80]) select { alive _x && { unitIsUAV _x } }) param [0, objNull]
    };
    private _state = {
        params ["_d", "_home"];
        if (isNull _d) exitWith { "no drone" };
        private _drv = driver _d;
        format ["%1 (%2) agl=%3 speed=%4km/h home=%5m managed=%6 initialized=%7 aiMOVE=%8 aiPATH=%9 engine=%10 fuel=%11 up=%12 wp=%13/%14",
            _d, typeOf _d, round ((getPosATL _d) select 2), round speed _d, round (_d distance2D _home),
            _d getVariable ["FPV_AI_Drones_managed", false], _d getVariable ["initialized", false],
            if (isNull _drv) then { "-" } else { _drv checkAIFeature "MOVE" }, if (isNull _drv) then { "-" } else { _drv checkAIFeature "PATH" },
            isEngineOn _d, (fuel _d) toFixed 2, (vectorUp _d) apply { _x toFixed 2 },
            currentWaypoint group _d, count waypoints group _d]
    };
    {
        _x params ["_type", "_payload", "_drone0", "_home"];
        private _label = format ["%1%2", _type, ["", " payload " + _payload] select (_payload != "")];
        private _x0 = _home select 0;
        private _drone = [_drone0, _home] call _follow;
        private _lastPos = if (isNull _drone) then { _home } else { getPosATL _drone };

        // 1. The loop: one lap, the CYCLE back home, and on to waypoint 1 again. It has
        // been flying since mission start, so laps are counted from here on. Hanging in
        // one spot in the air for 6 s (the reported symptom) fails it straight away.
        [format ["Compat %1/%2 - %3: flying its MOVE, MOVE, CYCLE loop", _forEachIndex + 1, count FPVT_compatCases, _label], _drone, objNull] call FPVT_fnc_show;
        private _legs = [];   // waypoints reached in order: 1, 2, 0 (home = the CYCLE)
        private _stillSince = -1;
        private _hung = "";
        private _until = time + 90;
        private _nextLog = 0;
        // How the corners are flown (Workshop report: "no braking, it switches to the next
        // waypoint instantly, as if it had no weight"): the lowest speed near each waypoint,
        // and the hardest horizontal speed change, sampled every 0.25 s.
        private _corners = [];   // [waypoint, lowest km/h within 40 m] per visit
        private _peakAcc = 0;
        private _lastV = [];
        private _lastT = time;
        while { time < _until && { _hung == "" } && { (_legs select [count _legs - 4 max 0]) isNotEqualTo [1, 2, 0, 1] } } do {
            _drone = [_drone, _lastPos] call _follow;
            if (!isNull _drone) then {
                _lastPos = getPosATL _drone;
                private _v = velocity _drone;
                _v set [2, 0];
                if (_lastV isNotEqualTo [] && { time > _lastT }) then {
                    _peakAcc = _peakAcc max ((vectorMagnitude (_v vectorDiff _lastV)) / (time - _lastT));
                };
                _lastV = _v;
                _lastT = time;
                private _at = [[_x0, 5000, 0], [_x0, 5300, 0], [_x0 + 300, 5300, 0]] findIf { _drone distance2D _x < 40 };
                if (_at >= 0 && { (_legs param [count _legs - 1, -1]) != _at }) then { _legs pushBack _at; _corners pushBack [_at, 1e9]; };
                if (_at >= 0 && { _corners isNotEqualTo [] }) then {
                    private _c = _corners select (count _corners - 1);
                    _c set [1, (_c select 1) min ((vectorMagnitude _v) * 3.6)];
                };
                if (speed _drone < 5 && { ((getPosATL _drone) select 2) > 5 }) then {
                    if (_stillSince < 0) then { _stillSince = time; };
                    if (time - _stillSince > 6) then { _hung = [_drone, _home] call _state; };
                } else { _stillSince = -1; };
            };
            if (time > _nextLog) then {
                _nextLog = time + 5;
                ["compat state", "INFO", [_drone, _home] call _state] call FPVT_fnc_report;
            };
            sleep 0.25;
        };
        [format ["compat %1 flew its loop round", _label], _hung == "" && { (_legs select [count _legs - 4 max 0]) isEqualTo [1, 2, 0, 1] },
            format ["waypoints in order %1 (want ...1,2,0,1) hung=%2 drone=%3 (placed %4)", _legs, [_hung, "no"] select (_hung == ""), _drone, _drone0]] call FPVT_fnc_check;
        // Turns: wp1 90 deg, wp2 135 deg, home (the CYCLE) 135 deg.
        ["corners", "INFO", format ["%1: lowest speed near each waypoint %2 km/h, peak horizontal acceleration %3 m/s2",
            _label, _corners apply { format ["wp%1=%2", _x select 0, round (_x select 1)] }, _peakAcc toFixed 1]] call FPVT_fnc_report;

        // 2. Enemy car driving north through the middle of the loop, coming into range
        // while the drone is on its way round.
        private _car = createVehicle ["O_MRAP_02_F", [_x0 + 150, 4750, 0], [], 0, "NONE"];
        _car setDir 0;
        createVehicleCrew _car;
        private _cg = group effectiveCommander _car;
        _cg setBehaviour "CARELESS";
        _cg setCombatMode "BLUE";
        { _x disableAI "AUTOTARGET"; _x disableAI "TARGET"; } forEach units _cg;
        _car limitSpeed 40;
        _cg addWaypoint [[_x0 + 150, 6400, 0], 0];
        [format ["Compat %1/%2 - %3: enemy car driving through the loop", _forEachIndex + 1, count FPVT_compatCases, _label], _drone, _car] call FPVT_fnc_show;
        private _start = time;
        private _best = 1e9;
        private _bestAt = time;
        private _inRangeAt = -1;
        _nextLog = 0;
        while { !([_car] call FPVT_fnc_vehicleDone) && { time < _start + 90 } } do {
            _drone = [_drone, _lastPos] call _follow;
            if (!isNull _drone) then {
                _lastPos = getPosATL _drone;
                private _d = _drone distance _car;
                if (_d < 200 && { _inRangeAt < 0 }) then { _inRangeAt = time; };
                if (_d < _best - 5) then { _best = _d; _bestAt = time; };
            };
            // Fail fast: in range for 25 s without getting 5 m closer.
            if (_inRangeAt > 0 && { time - _inRangeAt > 25 } && { time - _bestAt > 25 }) exitWith {
                ["stalled", "INFO", format ["no progress for 25 s with the car in range (closest %1 m)", round _best]] call FPVT_fnc_report;
            };
            if (time > _nextLog) then {
                _nextLog = time + 2;
                ["compat state", "INFO", format ["%1 car=%2m carSpeed=%3", [_drone, _home] call _state,
                    if (isNull _drone) then { "-" } else { round (_drone distance _car) }, round speed _car]] call FPVT_fnc_report;
            };
            sleep 0.5;
        };
        private _done = [_car] call FPVT_fnc_vehicleDone;
        if (_done) then {
            ["ttk", "INFO", format ["%1s  Compat %2 - car through the loop", (time - _start) toFixed 1, _label]] call FPVT_fnc_report;
        };
        sleep 3;
        [format ["compat %1 killed the car", _label], _done,
            format ["damage=%1 crewAlive=%2 closest=%3m drone=%4", damage _car toFixed 2, { alive _x } count crew _car, round _best,
                [_drone, _home] call _state]] call FPVT_fnc_check;
        { deleteVehicle _x } forEach crew _car; deleteVehicle _car;
        if (!isNull _drone) then { { deleteVehicle _x } forEach crew _drone; deleteVehicle _drone; };
    } forEach FPVT_compatCases;
};

// --- Speed bench on real terrain (run_tests.py --bench N --map Stratis) --------
// The same two attacks at random spots on the map - hills, trees, houses - since
// VR is flat and empty. Per pass: 3 parked tanks 120-250 m away and 3 cars driving
// past from 280-350 m out. Each line logs the height difference and how many
// obstacles sit on the straight line from 30 m over the drone to the target.
if (FPVT_bench > 0 && { worldName != "VR" }) then {
    FPVT_stages = [-1];
    FPV_AI_Drones_debug = true;
    private _cleanup = { params ["_veh"]; if (!isNull _veh) then { { deleteVehicle _x } forEach crew _veh; deleteVehicle _veh; }; };
    private _settings = FPVT_AT + [["TargetDetectionRange", 300]];
    // A random flat-enough spot on land, [] if there's none.
    private _land = {
        params ["_center", "_min", "_max"];
        private _p = [_center, _min, _max, 8, 0, 0.3, 0, [], [[-1, -1, 0], [-1, -1, 0]]] call BIS_fnc_findSafePos;
        if ((_p select 0) < 0) then { [] } else { [_p select 0, _p select 1, 0] }
    };
    // Prefer spots among trees and houses - open fields are the easy case.
    private _cover = {
        params ["_center", "_min", "_max"];
        private _best = (selectBestPlaces [_center, _max, "forest + trees + houses", 25, 15]) select {
            private _d = _center distance2D (_x select 0);
            _d >= _min && { _d <= _max }
        };
        private _spot = if (_best isEqualTo []) then { _center } else { (selectRandom _best) select 0 };
        if (_best isEqualTo []) then { [_center, _min, _max] call _land } else { [_spot, 0, 40] call _land }
    };
    private _describe = {
        params ["_from", "_to", ["_ignore", objNull]];
        private _obstacles = lineIntersectsSurfaces [AGLToASL (_from vectorAdd [0, 0, 30]), AGLToASL (_to vectorAdd [0, 0, 2]), _ignore, objNull, true, 20, "GEOM", "NONE"];
        format ["%1 m away, %2 m %3, %4 obstacles on the line", round (_from distance2D _to),
            round abs ((getTerrainHeightASL _to) - (getTerrainHeightASL _from)),
            ["lower", "higher"] select ((getTerrainHeightASL _to) > (getTerrainHeightASL _from)), count _obstacles]
    };
    private _mapCenter = [worldSize / 2, worldSize / 2, 0];
    for "_pass" from 1 to FPVT_bench do {
        for "_i" from 1 to 3 do {
            // A: parked tank.
            private _p = [_mapCenter, 0, worldSize / 2] call _land;
            private _tp = if (_p isEqualTo []) then { [] } else { [_p, 120, 250] call _cover };
            if (_tp isEqualTo []) then {
                ["terrain", "INFO", "no spot found for a parked-tank trial - skipped"] call FPVT_fnc_report;
            } else {
                private _d = [_p] call FPVT_fnc_spawnDrone;
                _d setVariable ["FPV_AI_Drones_managed", true, true];
                private _t = [_tp] call FPVT_fnc_spawnTank;
                private _l = [_p vectorAdd [8, 0, 0], _settings] call FPVT_fnc_module;
                [_l, [_d], true] call FPV_AI_Drones_fnc_initModule;
                private _desc = [_p, _tp, _t] call _describe;
                [format ["Terrain %1.%2 - parked tank %3", _pass, _i, _desc], _d, _t] call FPVT_fnc_show;
                private _to = [_d, _t, FPVT_fnc_vehicleDone, 90] call FPVT_fnc_await;
                [format ["terrain %1.%2 parked tank (%3) at %4", _pass, _i, _desc, mapGridPosition _tp], [_t] call FPVT_fnc_vehicleDone,
                    format ["damage=%1 crewAlive=%2 timedOut=%3", damage _t toFixed 2, {alive _x} count crew _t, _to]] call FPVT_fnc_check;
                [_t] call _cleanup; [_d] call _cleanup; deleteVehicle _l;
            };

            // B: car driving past - from 280-350 m out to a spot beyond the drone.
            _p = [_mapCenter, 0, worldSize / 2] call _land;
            private _start = if (_p isEqualTo []) then { [] } else { [_p, 280, 350] call _land };
            private _dest = if (_start isEqualTo []) then { [] } else { [_p vectorAdd ((_p vectorDiff _start) vectorMultiply 1.5), 0, 150] call _land };
            if (_dest isEqualTo []) then {
                ["terrain", "INFO", "no spot found for a moving-car trial - skipped"] call FPVT_fnc_report;
            } else {
                private _d = [_p] call FPVT_fnc_spawnDrone;
                _d setVariable ["FPV_AI_Drones_managed", true, true];
                private _car = createVehicle ["O_MRAP_02_F", _start, [], 0, "NONE"];
                _car setDir (_start getDir _dest);
                createVehicleCrew _car;
                private _cg = group effectiveCommander _car;
                _cg setBehaviour "CARELESS";
                _cg setCombatMode "BLUE";
                _cg setSpeedMode "FULL";
                { _x disableAI "AUTOTARGET"; _x disableAI "TARGET"; } forEach units _cg;
                _car limitSpeed 70;
                _cg addWaypoint [_dest, 0];
                private _l = [_p vectorAdd [8, 0, 0], _settings] call FPVT_fnc_module;
                [_l, [_d], true] call FPV_AI_Drones_fnc_initModule;
                private _desc = [_p, _start, _car] call _describe;
                [format ["Terrain %1.%2 - car driving past, starts %3", _pass, _i, _desc], _d, _car] call FPVT_fnc_show;
                FPVT_moverSpeed = -1;
                private _watch = [_car] spawn { params ["_m"]; while { alive _m } do { FPVT_moverSpeed = speed _m; sleep 0.5; }; };
                private _to = [_d, _car, FPVT_fnc_vehicleDone, 90] call FPVT_fnc_await;
                terminate _watch;
                [format ["terrain %1.%2 moving car (starts %3) at %4", _pass, _i, _desc, mapGridPosition _p], [_car] call FPVT_fnc_vehicleDone,
                    format ["damage=%1 crewAlive=%2 carSpeedBeforeHit=%3km/h timedOut=%4",
                        damage _car toFixed 2, {alive _x} count crew _car, round FPVT_moverSpeed, _to]] call FPVT_fnc_check;
                [_car] call _cleanup; [_d] call _cleanup; deleteVehicle _l;
            };
        };
    };
};

// --- Speed bench (run_tests.py --bench N) -----------------------------------
// The same two attacks - a parked tank and a car crossing in front of the drone
// at ~70 km/h - at close, medium and far range, N passes. Nothing else runs.
// Drones start on the ground, like a drone placed in the editor. The far range
// is past the default 200 m detection range, so that module gets 500 m.
// Compare the ttk lines (and the drones' "s after acquiring") between changes.
if (FPVT_bench > 0 && { worldName == "VR" }) then {
    FPVT_stages = [-1];   // no regular stages
    FPV_AI_Drones_debug = true;
    FPVT_dodges = [];
    FPVT_fnc_benchCase = { params ["_c"]; FPVT_benchCases isEqualTo [] || { _c in FPVT_benchCases } };
    // The AT payload in use and what the game's config says it does.
    private _benchAmmo = "";
    { if ((_x select 0) == "CustomAmmo") then { _benchAmmo = _x select 1; }; } forEach (FPVT_AT + FPVT_set);
    {
        private _a = configFile >> "CfgAmmo" >> _x;
        private _sub = getText (_a >> "submunitionAmmo");
        ["bench payload", "INFO", format ["%1: exists=%2 simulation=%3 hit=%4 indirectHit=%5 indirectHitRange=%6 submunition=%7 (hit %8)",
            _x, isClass _a, getText (_a >> "simulation"), getNumber (_a >> "hit"), getNumber (_a >> "indirectHit"), getNumber (_a >> "indirectHitRange"),
            _sub, getNumber (configFile >> "CfgAmmo" >> _sub >> "hit")]] call FPVT_fnc_report;
    } forEach (_benchAmmo splitString ", ");
    private _cleanup = { params ["_veh"]; if (!isNull _veh) then { { deleteVehicle _x } forEach crew _veh; deleteVehicle _veh; }; };
    for "_pass" from 1 to FPVT_bench do {
        {
            _x params ["_label", "_x0", "_tankDist", "_crossOffset", "_range"];
            if !([_label] call FPVT_fnc_benchCase) then { continue; };
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
        if (["cover"] call FPVT_fnc_benchCase) then {
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
        };

        // D: Anti-Personnel drone vs a 4-man squad 150 m away.
        if (["infantry"] call FPVT_fnc_benchCase) then {
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

        // F: dodge - a car at ~80 km/h that swerves 60 degrees when the drone is 40 m
        // out, three tries. Info only: with more Braking Time (a heavier drone) more of
        // these should get away - that's the point of the setting.
        if (["dodge"] call FPVT_fnc_benchCase) then {
        for "_try" from 1 to 3 do {
            _d = [[1000, 2000, 0]] call FPVT_fnc_spawnDrone;
            _d setVariable ["FPV_AI_Drones_managed", true, true];
            private _car = createVehicle ["O_MRAP_02_F", [1100, 1680, 0], [], 0, "NONE"];
            _car setDir 0;
            createVehicleCrew _car;
            private _cg = group effectiveCommander _car;
            _cg setBehaviour "CARELESS";
            _cg setCombatMode "BLUE";
            _cg setSpeedMode "FULL";
            { _x disableAI "AUTOTARGET"; _x disableAI "TARGET"; } forEach units _cg;
            _car limitSpeed 80;
            _cg addWaypoint [[1100, 4500, 0], 0];
            _l = [[1008, 2000, 0], FPVT_AT] call FPVT_fnc_module;
            [_l, [_d], true] call FPV_AI_Drones_fnc_initModule;
            [format ["Bench %1/%2 dodge %3/3 - car swerves when the drone is 40 m out", _pass, FPVT_bench, _try], _d, _car] call FPVT_fnc_show;
            FPVT_jink = [];   // [time, car speed km/h, side] once it has swerved
            private _jink = [_car, _d] spawn {
                params ["_car", "_d"];
                waitUntil { sleep 0.02; !alive _d || { !alive _car } || { (_d distance _car) < 40 } };
                if (!alive _d || { !alive _car }) exitWith {};
                private _side = selectRandom [-1, 1];
                FPVT_jink = [time, round speed _car, _side];
                // 60 degrees in 0.4 s, keeping its speed - a hard swerve.
                for "_i" from 1 to 6 do {
                    private _v = (speed _car) / 3.6;
                    _car setDir ((getDir _car) + 10 * _side);
                    _car setVelocityModelSpace [0, _v, 0];
                    sleep 0.067;
                };
            };
            private _closest = 1e9;
            private _end = time + 60;
            waitUntil {
                sleep 0.05;
                if (alive _d) then { _closest = _closest min (_d distance _car); };
                [_car] call FPVT_fnc_vehicleDone || { !alive _d } || { time > _end }
            };
            sleep 3;
            terminate _jink;
            private _hit = [_car] call FPVT_fnc_vehicleDone;
            ["bench dodge", "INFO", format ["try %1: %2 - swerved=%3 at %4 km/h, closest %5 m, car damage=%6 crewAlive=%7",
                _try, ["car got away", "car hit"] select _hit, FPVT_jink isNotEqualTo [], FPVT_jink param [1, -1],
                round _closest, damage _car toFixed 2, { alive _x } count crew _car]] call FPVT_fnc_report;
            FPVT_dodges pushBack _hit;
            [_car] call _cleanup; [_d] call _cleanup; deleteVehicle _l;
        };
        };

        if !(["swarm"] call FPVT_fnc_benchCase) then { continue; };
        // E: swarm - 6 drones side by side vs 3 tanks + 3 cars spread out 150 m away.
        // Fast drones arriving together can catch each other's blasts (any hit sets a
        // Crocus off), and every drone runs a per-frame handler: watch the server FPS.
        private _drones = [];
        private _targets = [];
        for "_k" from 0 to 5 do {
            private _dk = [[1500 + _k * 15, 6500, 0]] call FPVT_fnc_spawnDrone;
            _dk setVariable ["FPV_AI_Drones_managed", true, true];
            _drones pushBack _dk;
            private _tk = if (_k < 3) then { [[1440 + _k * 60, 6650, 0]] call FPVT_fnc_spawnTank } else {
                private _c = createVehicle ["O_MRAP_02_F", [1440 + _k * 60, 6650, 0], [], 0, "NONE"];
                createVehicleCrew _c; [group effectiveCommander _c] call FPVT_fnc_passive; _c };
            _targets pushBack _tk;
        };
        _l = [[1460, 6500, 0], FPVT_AT] call FPVT_fnc_module;
        [_l, _drones, true] call FPV_AI_Drones_fnc_initModule;
        [format ["Bench %1/%2 swarm - 6 drones vs 6 vehicles 150 m away", _pass, FPVT_bench], _drones select 2, _targets select 2] call FPVT_fnc_show;
        private _minFps = 1000;
        private _swarmEnd = time + 60;
        private _swarmStart = time;
        waitUntil {
            sleep 0.25;
            _minFps = _minFps min diag_fps;
            ({ !([_x] call FPVT_fnc_vehicleDone) } count _targets) == 0 || { time > _swarmEnd } || { ({ alive _x } count _drones) == 0 && { time > _swarmStart + 5 } }
        };
        sleep 3;
        private _killed = { [_x] call FPVT_fnc_vehicleDone } count _targets;
        ["ttk", "INFO", format ["%1s  Bench %2/%3 swarm - %4/6 vehicles done", (time - _swarmStart - 3) toFixed 1, _pass, FPVT_bench, _killed]] call FPVT_fnc_report;
        [format ["bench %1 swarm 6 drones vs 6 vehicles", _pass], _killed >= 5,
            format ["%1/6 vehicles done, server fps min %2", _killed, round _minFps]] call FPVT_fnc_check;
        { [_x] call _cleanup } forEach (_targets + _drones); deleteVehicle _l;
    };
    ["bench dodge", "INFO", format ["swerving car hit %1 of %2 times (settings: %3)", { _x } count FPVT_dodges, count FPVT_dodges, FPVT_set]] call FPVT_fnc_report;
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
private _as = _edenModule getVariable ["AttackSpeed", -1];
private _uk = _edenModule getVariable ["UnitKinds", ""];
["1c untouched module uses its own preset", _ish == 30 && { _as == 180 } && { _uk == "LandVehicle,Car,Tank" },
    format ["InitialSearchHeight=%1 AttackSpeed=%2 UnitKinds=%3 (AT preset is 30 / 180 / LandVehicle,Car,Tank)", _ish, _as, _uk]] call FPVT_fnc_check;

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
            round ((_d distance2D [3000, 4400, 0]) / 10) * 10, isEngineOn _d, (expectedDestination _d) param [1, "<none>"]];
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

if ([8] call FPVT_fnc_runStage && { FPVT_headless }) then {
    ["8 skipped", "INFO", "headless run: stage 8 needs a player's machine to place the drone from"] call FPVT_fnc_report;
};
if ([8] call FPVT_fnc_runStage && { !FPVT_headless }) then {
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

if ([12] call FPVT_fnc_runStage) then {
// --- Stage 12: Accuracy -------------------------------------------------------
// The module's "Accuracy (%)": a run that misses on purpose comes down beside the
// target, a few blast radii of its payload away. At 0% every run misses: the payload
// must go off well clear, and the target must come through it.
// Where it went off: the drone's last position, recorded every frame.
FPVT_watchDrone = objNull;
FPVT_lastDronePos = [];
private _recorder = addMissionEventHandler ["EachFrame", { if (alive FPVT_watchDrone) then { FPVT_lastDronePos = getPosASL FPVT_watchDrone; }; }];

_drone = [[5500, 6000, 0]] call FPVT_fnc_spawnDrone;
_drone setVariable ["FPV_AI_Drones_managed", true, true];
FPVT_watchDrone = _drone;
_tank = [[5500, 6150, 0]] call FPVT_fnc_spawnTank;
_logic = [[5508, 6000, 0], FPVT_AT + [["HitChance", 0]]] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
["Stage 12 - Anti-Tank drone set to 0% accuracy: must come down beside the tank", _drone, _tank] call FPVT_fnc_show;
_timedOut = [_drone, _tank, FPVT_fnc_vehicleDone, 60] call FPVT_fnc_await;
private _off = if (FPVT_lastDronePos isEqualTo []) then { -1 } else { round (FPVT_lastDronePos distance2D (getPosASL _tank)) };
["12a AT drone at 0% accuracy missed the tank", !alive _drone && { _off >= 7 } && { !([_tank] call FPVT_fnc_vehicleDone) },
    format ["went off %1 m from the tank (want 7+), tank damage=%2 crewAlive=%3 canMove=%4, drone alive=%5 timedOut=%6",
        _off, damage _tank toFixed 2, { alive _x } count crew _tank, canMove _tank, alive _drone, _timedOut]] call FPVT_fnc_check;

// The same for Anti-Personnel: a smaller charge, so a closer miss - nobody may die.
_drone = [[6500, 6000, 0], "B_Crocus_AP"] call FPVT_fnc_spawnDrone;
_drone setVariable ["FPV_AI_Drones_managed", true, true];
FPVT_watchDrone = _drone;
FPVT_lastDronePos = [];
private _squad12 = [[6500, 6150, 0], 4] call FPVT_fnc_spawnSquad;
_logic = [[6508, 6000, 0], FPVT_AP + [["HitChance", 0]]] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
["Stage 12 - Anti-Personnel drone set to 0% accuracy: must miss the squad", _drone, _squad12 select 0] call FPVT_fnc_show;
_timedOut = [_drone, _squad12, { params ["_units"]; ({alive _x} count _units) == 0 }, 60] call FPVT_fnc_await;
_off = if (FPVT_lastDronePos isEqualTo []) then { -1 } else { round selectMin (_squad12 apply { FPVT_lastDronePos distance2D (getPosASL _x) }) };
["12b AP drone at 0% accuracy missed the squad", !alive _drone && { ({ !alive _x } count _squad12) == 0 },
    format ["went off %1 m from the nearest soldier, killed %2/4, wounded %3, drone alive=%4 timedOut=%5",
        _off, { !alive _x } count _squad12, { alive _x && { damage _x > 0.05 } } count _squad12, alive _drone, _timedOut]] call FPVT_fnc_check;
removeMissionEventHandler ["EachFrame", _recorder];
{ deleteVehicle _x } forEach _squad12;
};

if ([13] call FPVT_fnc_runStage) then {
// --- Stage 13: a drone taken out without being destroyed -----------------------
// A drone jammer (or the mission) kills a drone's crew, empties its tank or switches
// its AI off. The drone must come down, or at least stop - v1.3.0 kept flying it (a
// Workshop report: "AI crew killed by jammer but drone still in the air, engines
// running"). Each case: a drone on the ground 450 m from a parked tank, detection 500,
// so it flies a long attack run; 250 m out it is taken out; the tank must survive.
private _caseDisabled = {
    params ["_label", "_type", "_x0", "_disable"];
    private _d = [[_x0, 7000, 0], _type] call FPVT_fnc_spawnDrone;
    _d setVariable ["FPV_AI_Drones_managed", true, true];
    private _t = [[_x0, 7450, 0]] call FPVT_fnc_spawnTank;
    private _l = [[_x0 + 8, 7000, 0], FPVT_AT + [["TargetDetectionRange", 500]]] call FPVT_fnc_module;
    [_l, [_d], true] call FPV_AI_Drones_fnc_initModule;
    [format ["Stage 13 - %1", _label], _d, _t] call FPVT_fnc_show;
    private _until = time + 60;
    waitUntil { sleep 0.1; !alive _d || { (_d distance2D _t) < 250 } || { time > _until } };
    private _reached = alive _d && { (_d distance2D _t) < 250 };
    if (_reached) then { [_d] call _disable; };
    sleep 15;
    private _agl = if (isNull _d) then { -1 } else { round ((getPosATL _d) select 2) };
    private _stopped = isNull _d || { !alive _d } || { _agl < 3 } || { (speed _d) < 15 };
    [format ["13 %1", _label], _reached && { _stopped } && { !([_t] call FPVT_fnc_vehicleDone) } && { (damage _t) < 0.1 },
        format ["taken out 250 m out=%1, then 15 s: drone alive=%2 agl=%3 speed=%4km/h crewAlive=%5 flagged=%6 | tank damage=%7 crewAlive=%8",
            _reached, alive _d, _agl, if (isNull _d) then { -1 } else { round speed _d }, { alive _x } count crew _d,
            _d getVariable ["FPV_AI_Drones_disabledWhy", "-"], damage _t toFixed 2, { alive _x } count crew _t]] call FPVT_fnc_check;
    { deleteVehicle _x } forEach crew _t; deleteVehicle _t;
    if (!isNull _d) then { { deleteVehicle _x } forEach crew _d; deleteVehicle _d; };
    deleteVehicle _l;
};
["a Crocus whose crew is killed mid-attack", "B_Crocus_AT", 500, { params ["_d"]; { _x setDamage 1; } forEach crew _d; }] call _caseDisabled;
["an AR-2 Darter whose crew is killed mid-attack", "B_UAV_01_F", 1500, { params ["_d"]; { _x setDamage 1; } forEach crew _d; }] call _caseDisabled;
["a Crocus whose fuel is cut mid-attack", "B_Crocus_AT", 2500, { params ["_d"]; _d setFuel 0; }] call _caseDisabled;
["an AR-2 Darter whose AI is switched off mid-attack", "B_UAV_01_F", 3500, { params ["_d"]; { _x disableAI "MOVE"; } forEach crew _d; }] call _caseDisabled;

// 13e: the same while flying waypoints (no target) - the waypoint handler also started
// the engine again in v1.3.0.
_drone = [[4500, 7000, 0], "B_UAV_01_F", true] call FPVT_fnc_spawnDrone;
_drone setVariable ["FPV_AI_Drones_managed", true, true];
(group _drone) addWaypoint [[4500, 7900, 0], 0];
_logic = [[4508, 7000, 0], FPVT_AT] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
["Stage 13 - an AR-2 flying waypoints, crew killed on the way", _drone] call FPVT_fnc_show;
private _until13 = time + 40;
waitUntil { sleep 0.25; (((getPosATL _drone) select 2) > 15 && { (speed _drone) > 50 }) || { time > _until13 } };
private _flying13 = ((getPosATL _drone) select 2) > 15;
{ _x setDamage 1; } forEach crew _drone;
sleep 12;
private _agl13 = if (isNull _drone) then { -1 } else { round ((getPosATL _drone) select 2) };
["13e AR-2 flying waypoints comes down when its crew is killed", _flying13 && { isNull _drone || { !alive _drone } || { _agl13 < 3 } },
    format ["was flying=%1, 12 s later: alive=%2 agl=%3 speed=%4km/h engine=%5", _flying13, alive _drone, _agl13, round speed _drone, isEngineOn _drone]] call FPVT_fnc_check;
if (!isNull _drone) then { deleteVehicle _drone; };
deleteVehicle _logic;
};

if ([14] call FPVT_fnc_runStage) then {
// --- Stage 14: UAV Operator Required --------------------------------------------
// A soldier synced to the module is the drone's operator (a Workshop wish). Killed
// mid-attack: the drone loses its pilot and comes down; the tank survives.
_drone = [[1000, 5000, 0]] call FPVT_fnc_spawnDrone;
_drone setVariable ["FPV_AI_Drones_managed", true, true];
private _op = (createGroup [west, true]) createUnit ["B_soldier_UAV_F", [960, 5000, 0], [], 0, "CAN_COLLIDE"];
_op disableAI "MOVE";
_tank = [[1000, 5450, 0]] call FPVT_fnc_spawnTank;
_logic = [[1008, 5000, 0], FPVT_AT + [["TargetDetectionRange", 500], ["OperatorRequired", true]]] call FPVT_fnc_module;
[_logic, [_drone, _op], true] call FPV_AI_Drones_fnc_initModule;
["Stage 14 - UAV Operator Required: the operator is killed mid-attack", _drone, _tank] call FPVT_fnc_show;
private _until14 = time + 60;
waitUntil { sleep 0.1; !alive _drone || { (_drone distance2D _tank) < 250 } || { time > _until14 } };
private _flew14 = alive _drone && { (_drone distance2D _tank) < 250 };
_op setDamage 1;
sleep 15;
private _agl14 = if (isNull _drone) then { -1 } else { round ((getPosATL _drone) select 2) };
["14a drone comes down when its operator is killed", _flew14 && { isNull _drone || { !alive _drone } || { _agl14 < 3 } } && { !([_tank] call FPVT_fnc_vehicleDone) },
    format ["flew while the operator lived=%1, 15 s after: alive=%2 agl=%3 fuel=%4 why=%5 | tank damage=%6",
        _flew14, alive _drone, _agl14, fuel _drone, _drone getVariable ["FPV_AI_Drones_disabledWhy", "-"], damage _tank toFixed 2]] call FPVT_fnc_check;
};

if ([15] call FPVT_fnc_runStage) then {
// --- Stage 15: Attack Empty Vehicles --------------------------------------------
// 15a: on - an empty enemy (OPFOR) car is attacked; the empty civilian car next to it isn't.
_drone = [[2500, 5000, 0]] call FPVT_fnc_spawnDrone;
_drone setVariable ["FPV_AI_Drones_managed", true, true];
private _emptyEnemy = createVehicle ["O_MRAP_02_F", [2500, 5150, 0], [], 0, "NONE"];
private _emptyCiv = createVehicle ["C_Offroad_01_F", [2420, 5150, 0], [], 0, "NONE"];
_logic = [[2508, 5000, 0], FPVT_AT + [["AttackEmptyVehicles", true]]] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
["Stage 15 - Attack Empty Vehicles: the empty OPFOR car, not the civilian one", _drone, _emptyEnemy] call FPVT_fnc_show;
_timedOut = [_drone, _emptyEnemy, { params ["_v"]; !alive _v || { (damage _v) > 0.5 } }, 60] call FPVT_fnc_await;
["15a empty enemy car attacked, empty civilian car left alone", (!alive _emptyEnemy || { (damage _emptyEnemy) > 0.5 }) && { alive _emptyCiv } && { (damage _emptyCiv) < 0.3 },
    format ["OPFOR car alive=%1 damage=%2 | civilian car alive=%3 damage=%4 | timedOut=%5",
        alive _emptyEnemy, damage _emptyEnemy toFixed 2, alive _emptyCiv, damage _emptyCiv toFixed 2, _timedOut]] call FPVT_fnc_check;

// 15b: off (default) - the same empty enemy car is no target: the drone stays put.
_drone = [[4000, 5000, 0]] call FPVT_fnc_spawnDrone;
_drone setVariable ["FPV_AI_Drones_managed", true, true];
private _emptyEnemy2 = createVehicle ["O_MRAP_02_F", [4000, 5150, 0], [], 0, "NONE"];
_logic = [[4008, 5000, 0], FPVT_AT] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
["Stage 15 - option off: the empty OPFOR car must be ignored", _drone, _emptyEnemy2] call FPVT_fnc_show;
sleep 25;
["15b empty enemy car ignored with the option off", alive _drone && { (_drone distance2D [4000, 5000, 0]) < 30 } && { (damage _emptyEnemy2) < 0.1 },
    format ["drone alive=%1 moved=%2m | car damage=%3", alive _drone, round (_drone distance2D [4000, 5000, 0]), damage _emptyEnemy2 toFixed 2]] call FPVT_fnc_check;
{ deleteVehicle _x } forEach crew _drone; deleteVehicle _drone; deleteVehicle _emptyEnemy2;
};

if ([16] call FPVT_fnc_runStage) then {
// --- Stage 16: Second Pass Chance -----------------------------------------------
// Accuracy 0 and Second Pass 100: every run is a fly-by, low past the tank and round
// again - the drone keeps making passes, and neither it nor the tank is lost.
_drone = [[5500, 5000, 0]] call FPVT_fnc_spawnDrone;
_drone setVariable ["FPV_AI_Drones_managed", true, true];
_tank = [[5500, 5150, 0]] call FPVT_fnc_spawnTank;
_logic = [[5508, 5000, 0], FPVT_AT + [["HitChance", 0], ["SecondPassChance", 100]]] call FPVT_fnc_module;
[_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
["Stage 16 - Accuracy 0, Second Pass 100: passes the tank again and again", _drone, _tank] call FPVT_fnc_show;
sleep 40;
private _passes = _drone getVariable ["FPV_AI_Drones_passes", 0];
["16a missed runs fly past and come round again", _passes >= 2 && { alive _drone } && { (damage _tank) < 0.1 },
    format ["passes=%1 drone alive=%2 agl=%3 | tank damage=%4 crewAlive=%5",
        _passes, alive _drone, round ((getPosATL _drone) select 2), damage _tank toFixed 2, { alive _x } count crew _tank]] call FPVT_fnc_check;
{ deleteVehicle _x } forEach crew _drone; deleteVehicle _drone; deleteVehicle _logic;
};

if ([17] call FPVT_fnc_runStage) then {
// --- Stage 17: Delete Drone After Detonation ------------------------------------
// An AR-2 (no Crocus self-delete): with the option (default on) no wreck is left; off, it is.
{
    _x params ["_x0", "_delete"];
    _drone = [[_x0, 5000, 0], "B_UAV_01_F"] call FPVT_fnc_spawnDrone;
    _drone setVariable ["FPV_AI_Drones_managed", true, true];
    _tank = [[_x0, 5150, 0]] call FPVT_fnc_spawnTank;
    _logic = [[_x0 + 8, 5000, 0], FPVT_AT + [["DeleteDrone", _delete]]] call FPVT_fnc_module;
    [_logic, [_drone], true] call FPV_AI_Drones_fnc_initModule;
    [format ["Stage 17 - AR-2, Delete Drone After Detonation %1", ["off", "on"] select _delete], _drone, _tank] call FPVT_fnc_show;
    _timedOut = [_drone, _tank, FPVT_fnc_vehicleDone, 60] call FPVT_fnc_await;
    [format ["17%1 Delete Drone %2: %3", ["b", "a"] select _delete, ["off", "on"] select _delete, ["wreck left", "no wreck"] select _delete],
        ([_tank] call FPVT_fnc_vehicleDone) && { (isNull _drone) isEqualTo _delete },
        format ["tank done=%1 | drone deleted=%2 alive=%3 timedOut=%4", [_tank] call FPVT_fnc_vehicleDone, isNull _drone, alive _drone, _timedOut]] call FPVT_fnc_check;
} forEach [[6500, true], [7300, false]];
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
