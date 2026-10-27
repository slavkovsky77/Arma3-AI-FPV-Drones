/*
    FPV AI Drones - per-drone attack logic.

    Spawned once per managed drone by fn_initModule. Runs on the server only;
    the caller guarantees that, and the locality check below is a backstop for
    anyone calling this directly.
*/

params [
    "_uavInstance",
    "_unitKinds",
    "_targetSource",
    "_attackDistance",
    "_attackDistance2D",
    "_attackHeight",
    "_allowObjectParent",
    "_customAmmo",
    "_targetDetectionRange",
    "_heightAdjustmentDelay",
    "_stuckCheckInterval",
    "_stuckThreshold",
    "_moveAdjustmentDelay",
    "_initialSearchHeight",
    "_enableChat",
    ["_targetSides", "ENEMIES"],  // ENEMIES | EAST | WEST | GUER | NOTOWN - see _isHostile
    ["_attackSpeedKmh", -1],      // top speed of the attack run; -1 = 180 (vehicles) / 144 (infantry)
    ["_cruiseSpeedKmh", -1],      // speed on waypoints, before a target is found; -1 = 126
    ["_brakingTime", -1],         // seconds to stop from full speed - how heavy the drone is; -1 = default below
    ["_hitChance", -1],           // % of attack runs aimed at the target itself, the rest miss; -1 = 100
    ["_secondPass", -1],          // % of missed runs that fly past and come round for another; -1 = 50
    ["_deleteDrone", true],       // remove the drone when its payload goes off
    ["_attackEmpty", true]        // also attack vehicles with nobody inside, by their faction's side
];
// Since v1.2 _attackDistance, _attackDistance2D, _attackHeight and the delay/stuck
// parameters are unused (the attack run is flown below); they stay for compatibility.

// Flight model. Braking time sets the acceleration for everything the drone does -
// braking, speeding up, turning: acceleration = top speed / braking time. A Workshop
// tester found the drone weightless ("switches to the next waypoint instantly"):
// v1.2 turned at 26 m/s2 on waypoints and 60 m/s2 in the attack run.
private _cruiseSpeed = if (_cruiseSpeedKmh > 0) then { (_cruiseSpeedKmh / 3.6) max 3 } else { 35 };
if (_brakingTime <= 0) then { _brakingTime = 2 };   // same default as the modules' setting (config.cpp)
_brakingTime = (_brakingTime max 0.2) min 20;
_hitChance = if (_hitChance < 0) then { 100 } else { (_hitChance max 0) min 100 };
_secondPass = if (_secondPass < 0) then { 50 } else { (_secondPass max 0) min 100 };

// Movement commands only take effect where the drone is local. Bail out rather
// than issuing orders that silently do nothing.
if (!local _uavInstance) exitWith {};

// These were previously global variables, redefined by every drone's thread and
// exported into the global namespace under names like "is_dead" and "isStuck",
// which is an easy collision with other AI mods. Keep them script-local.
private _isUnitOfKind = {
    params ["_unit", "_kinds"];
    private _result = false;
    {
        if (_unit isKindOf _x) then {
            _result = true;
            break;
        };
    } forEach _kinds;
    _result
};

private _is_dead = {
    params ["_object"];
    (isNull _object) || !(alive _object)
};

// Taken out without being destroyed - by a drone jammer, the mission, or its operator
// being killed (the module's "UAV Operator Required"). Such a drone is left alone for
// good and comes down like any drone without a pilot. v1.3.0 kept flying it: both
// handlers steer it every frame without listening to the engine, and the waypoint one
// even started its engine again - a Workshop user's jammer killed a drone's crew and
// it stayed in the air, engines running. (That jammer, Sania & Volnorez EW, kills an
// AI-flown drone's driver and gunner.) Its AI being switched off does NOT count: the
// Crocus mod switches off all AI on its own drones a second in, and this script switches
// it back on. "" while it can fly.
private _disabledReason = {
    params ["_u"];
    if (_u getVariable ["FPV_AI_Drones_disabled", false]) exitWith { _u getVariable ["FPV_AI_Drones_disabledWhy", "disabled"] };
    // Its operators all dead ("UAV Operator Required", the UAV Operator module): checked
    // here every frame - the module's 2 s round let an attacking drone fly on 100 m.
    private _ops = _u getVariable ["FPV_AI_Drones_operators", []];
    if (_ops isNotEqualTo [] && { ({ alive _x } count _ops) == 0 }) exitWith { "its operator was killed" };
    private _crew = (crew _u) select { alive _x };
    if (_crew isEqualTo []) exitWith { "no living crew" };
    // Only if it could when this script took it on: a drone mod may report a healthy drone as unable.
    // Fuel first: an empty tank makes canMove false too.
    if ((fuel _u) <= 0) exitWith { "out of fuel" };
    if (!canMove _u && { _u getVariable ["FPV_AI_Drones_couldMove", true] }) exitWith { "engine or rotor destroyed" };
    ""
};
private _markDisabled = {
    params ["_u", "_why"];
    if (isNull _u || { _u getVariable ["FPV_AI_Drones_disabled", false] }) exitWith {};
    _u setVariable ["FPV_AI_Drones_disabled", true, true];
    _u setVariable ["FPV_AI_Drones_disabledWhy", _why];
    // No operator: its crew lives, so cut the engine or its AI would keep it in the air.
    if (_why == "its operator was killed") then { _u setFuel 0; _u engineOn false; };
    diag_log format ["FPV_AI_Drones: drone %1 no longer flown: %2", _u, _why];
};

// Whether _other is a target under the module's "Target Sides" setting.
//   ENEMIES - whatever the mission's side relations call hostile to the drone (default, as in v1.1)
//   EAST / WEST / GUER - that side only, regardless of relations
//   NOTOWN  - every combat side except the drone's own; civilians never
private _isHostile = {
    params ["_uav", "_other", "_mode"];
    private _s = side _other;
    // An empty vehicle has no side of its own (it reads as civilian). With "Attack Empty
    // Vehicles" it counts as its faction's side from config, so an abandoned enemy car is
    // a target and a civilian one never is. Wrecks are never targets. Empty means nobody
    // inside at all: crew lists the dead too, so a tank whose crew a drone already killed
    // stays out - with the option on by default, every later drone would go for the hull.
    if (_attackEmpty && { alive _other } && { !(_other isKindOf "CAManBase") } && { (crew _other) isEqualTo [] }) then {
        _s = [east, west, resistance, civilian] param [getNumber (configOf _other >> "side"), civilian];
    };
    switch (_mode) do {
        case "EAST": { _s == east };
        case "WEST": { _s == west };
        case "GUER": { _s == resistance };
        case "NOTOWN": { _s != side _uav && { _s in [east, west, resistance] } };
        default { [side _uav, _s] call BIS_fnc_sideIsEnemy };
    }
};

// Function to find the nearest enemy of a specific type
private _findNearestEnemyOfType = {
    params ["_uav", "_kinds", "_source", "_objectParentAllowed", "_detectionRange", ["_sides", "ENEMIES"]];

    // A missing default here left _targets undefined and threw on the select below.
    private _targets = switch (_source) do {
        case "allUnits": { allUnits };
        case "vehicles": { vehicles };
        default { allUnits };
    };

    private _enemies = _targets select {
        alive _x && { [_uav, _x, _sides] call _isHostile } && { [_x, _kinds] call _isUnitOfKind }
    };

    private _nearestEnemy = objNull;
    private _bestScore = 1e9;

    {
        private _hasObjectParent = !(isNull objectParent _x);
        private _isValidEnemy = _objectParentAllowed || !_hasObjectParent;
        private _distance = _uav distance _x;
        // Each other live drone already attacking it counts as 150 m further away, so
        // a swarm spreads over the targets. Every drone used to take the nearest one:
        // 6 drones went for 2 tanks, blew each other up and left 4 vehicles untouched.
        private _claims = { alive _x && { _x != _uav } } count (_x getVariable ["FPV_AI_Drones_claims", []]);
        private _score = _distance + (150 * _claims);
        // Crewed targets first: an empty one counts as 150 m further away.
        if (_attackEmpty && { !(_x isKindOf "CAManBase") } && { (crew _x) isEqualTo [] }) then { _score = _score + 150; };
        if (_isValidEnemy && { _distance < _detectionRange } && { _score < _bestScore }) then {
            _bestScore = _score;
            _nearestEnemy = _x;
        };
    } forEach _enemies;

    _nearestEnemy
};

private _isExternallyControlled = {
    params ["_unit"];

    // Check UAV Terminal connection
    private _isUAVConnected = isUAVConnected _unit;
    if (_isUAVConnected) then {
        true
    } else {
        // Check if unit is being directly controlled by Zeus
        private _zeusController = _unit getVariable ["bis_fnc_moduleRemoteControl_owner", objNull];
        !isNull _zeusController
    };
};

// One thread per drone. The guard holds the drone object itself rather than "true":
// some drone mods replace a drone with a new object and copy all its variables onto
// it (the Ukraine FPV Drone mod does on a payload change), and a copied "true" kept
// the replacement from ever being flown. "initialized" stays as plain information.
if ((_uavInstance getVariable ["FPV_AI_Drones_runner", objNull]) isEqualTo _uavInstance) exitWith {};
if (isNil { _uavInstance getVariable "FPV_AI_Drones_couldMove" }) then { _uavInstance setVariable ["FPV_AI_Drones_couldMove", canMove _uavInstance]; };
// A disabled drone stays down, and its AI stays as whatever disabled it left it (the
// enableAI below would undo a jammer). Marked only for a drone this script has flown:
// a freshly placed one may just not have its crew yet (Zeus adds it a moment later).
private _whyDisabled = [_uavInstance] call _disabledReason;
if (_whyDisabled != "") exitWith {
    if (_uavInstance getVariable ["FPV_AI_Drones_flown", false]) then { [_uavInstance, _whyDisabled] call _markDisabled; } else {
        // Logged once per reason, so a user's RPT says why a drone just sits there.
        if ((_uavInstance getVariable ["FPV_AI_Drones_waitWhy", ""]) != _whyDisabled) then {
            _uavInstance setVariable ["FPV_AI_Drones_waitWhy", _whyDisabled];
            diag_log format ["FPV_AI_Drones: drone %1 (%2) not flown yet: %3", _uavInstance, typeOf _uavInstance, _whyDisabled];
        };
    };
};
_uavInstance setVariable ["FPV_AI_Drones_runner", _uavInstance];
_uavInstance setVariable ["FPV_AI_Drones_flown", true];

_uavInstance setBehaviour "CARELESS";
_uavInstance setSkill 1;
_uavInstance enableAI "ALL";
_uavInstance setSpeedMode "FULL";
_uavInstance setVariable ["initialized", true];

// Heights use the forced form (Arma 2.14+). With the plain form a landed drone
// waits for a waypoint before it climbs, and any height under 10 m is a LANDING
// order - the attack height is 5-8 m, so drones slowed down and hovered over
// their target instead of hitting it.
_uavInstance flyInHeight [_initialSearchHeight, true];
_uavInstance forceSpeed 150;   // m/s - effectively no cap; speed comes from the AI and the dive

// Leave the flying to this script. The drone's own UAV AI scans for enemies and
// re-plans its path when it sees one (it also drops its waypoints then), and the
// Crocus carries a turret - it was competing with our move orders.
(group _uavInstance) setCombatMode "BLUE";
{
    _x disableAI "AUTOTARGET";
    _x disableAI "TARGET";
} forEach crew _uavInstance;
_uavInstance setVariable ["jac_bonusStealth", 1.0];
// Always logged, so a user's RPT shows whether the drone was picked up at all.
// clientOwner identifies the machine: it should only ever be the server's (2).
diag_log format ["FPV_AI_Drones: drone %1 (%2, side %3) hunting on machine %4", _uavInstance, typeOf _uavInstance, side _uavInstance, clientOwner];

// This runs on the server, so it has to be broadcast to actually reach players.
if (_enableChat) then {
    (format ["Initialized drone: %1", _uavInstance]) remoteExec ["systemChat", 0];
};

// A drone's claim on its target (see the scoring in _findNearestEnemyOfType).
// Server-side only, like all of this; dead drones' claims are ignored there.
private _claim = { params ["_t"]; _t setVariable ["FPV_AI_Drones_claims", ((_t getVariable ["FPV_AI_Drones_claims", []]) - [_uavInstance]) + [_uavInstance]]; };
private _unclaim = { params ["_t"]; if (!isNull _t) then { _t setVariable ["FPV_AI_Drones_claims", (_t getVariable ["FPV_AI_Drones_claims", []]) - [_uavInstance]]; }; };

//"LandVehicle", "Car", "Tank"
private _nearestEnemy = objNull;
private _lastWaypointOrder = [];
private _lastWaypointOrderTime = -1e9;
// Our own place in the group's route: [next waypoint index, positions of waypoints 1..n
// when last seen]. Kept on the drone so it survives this script restarting between
// attack runs. We can't use the engine's currentWaypoint: the Crocus AI marks a
// waypoint complete the moment it's given, without flying anywhere (seen in testing:
// wp 1/2 -> 2/2 within 5s while the drone sat on the ground with the engine off).
(_uavInstance getVariable ["FPV_AI_Drones_route", [1, []]]) params ["_wpIdx", "_wpSig"];

// Keep clear of other aircraft: flying into another drone is fatal - any hit sets a
// Crocus off. Seen in testing: two drones of a swarm crossed paths right after
// takeoff and both blew up; and Zeus gives a group's drones waypoints 1 m apart.
// Returns a velocity to add: away from anything within 12 m, the eastern one climbs.
private _separation = {
    params ["_uav", "_p"];
    private _push = [0, 0, 0];
    // No sideways shove while still on or near the ground - a scrape counts as a hit.
    private _side = ((((_p select 2) - (getTerrainHeightASL _p) - 1.5) / 3) max 0) min 1;
    {
        private _op = getPosASL _x;
        private _away = _p vectorDiff _op;
        private _d = vectorMagnitude _away;
        if (_x != _uav && { alive _x } && { _d > 0.01 }) then {
            private _k = ((12 - _d) / 12) max 0;
            _push = _push vectorAdd ((vectorNormalized [_away select 0, _away select 1, 0]) vectorMultiply (20 * _k * _side));
            if ((_p select 0) > (_op select 0)) then { _push = _push vectorAdd [0, 0, 8 * _k]; };
        };
    } forEach (_uav nearEntities ["Air", 12]);
    _push
};

// Waypoint flight. The AI pilot flies a Crocus to its waypoints at 30-60 km/h
// (its config allows 140): a drone sent 400 m spent ~35 s getting there in testing.
// While it has a waypoint, this handler flies it there at cruise speed, at search
// height over the ground. Before each waypoint it brakes as far as the next leg
// needs - a right angle to half speed, a hairpin almost to a stop, the last waypoint
// to a stop - and flies the turn onto the next leg itself, in an arc. v1.2 slowed
// late and then swung onto the next leg at 26 m/s2 (2.7 g) in one go.
// The search loop below sets "dest" and "next"; dest [] leaves the drone to the AI pilot.
private _cruiseState = createHashMapFromArray [
    ["uav", _uavInstance], ["dest", []], ["next", []], ["turns", 0], ["stop", false],
    ["speed", _cruiseSpeed], ["accel", _cruiseSpeed / _brakingTime],
    ["height", _initialSearchHeight], ["separate", _separation], ["disabled", _disabledReason]
];
private _cruise = {
    private _s = _thisArgs select 0;
    private _uav = _s get "uav";
    if ((_s get "stop") || { isNull _uav } || { !alive _uav } || { ([_uav] call (_s get "disabled")) != "" }) exitWith {
        removeMissionEventHandler ["EachFrame", _thisEventHandler];
    };
    private _dest = _s get "dest";
    if (_dest isEqualTo [] || { isGamePaused }) exitWith {};
    private _dt = diag_deltaTime * accTime;
    if (_dt <= 0) exitWith {};
    if (!isEngineOn _uav) then { _uav engineOn true; };   // else it rises with its rotors still
    private _p = getPosASL _uav;
    private _v = velocity _uav;
    private _speed = _s get "speed";
    private _accel = _s get "accel";
    private _toH = [(_dest select 0) - (_p select 0), (_dest select 1) - (_p select 1), 0];
    private _dist = vectorMagnitude _toH;

    // Corner speed for this waypoint, from the angle onto the next leg: full speed
    // straight on, half at a right angle, a crawl round a hairpin; 0 = stop over it.
    private _next = _s get "next";
    private _vCorner = 0;
    if (_next isNotEqualTo [] && { _dist > 0.5 }) then {
        private _out = [(_next select 0) - (_dest select 0), (_next select 1) - (_dest select 1), 0];
        if ((vectorMagnitude _out) > 1) then {
            _vCorner = ((_speed * (1 + ((vectorNormalized _toH) vectorDotProduct (vectorNormalized _out))) / 2) max 3) min _speed;
        };
    };
    // Start the turn where a turn at corner speed begins: its radius out, v^2 / a.
    private _turnAt = if (_next isEqualTo []) then { 0 } else { ((_vCorner ^ 2) / _accel) max 4 };
    if (_next isNotEqualTo [] && { _dist < _turnAt }) exitWith {
        _s set ["dest", _next];
        _s set ["next", []];
        _s set ["turns", (_s get "turns") + 1];
        if (missionNamespace getVariable ["FPV_AI_Drones_debug", false]) then {
            diag_log format ["FPV_AI_Drones: trace %1 turning onto the next leg at %2 km/h (corner speed %3 km/h)",
                _uav, round ((vectorMagnitude _v) * 3.6), round (_vCorner * 3.6)];
        };
    };

    private _dirH = if (_dist > 0.5) then { vectorNormalized _toH } else { [0, 0, 0] };
    // Fastest it may go here and still be down to the corner speed where the turn
    // starts (braking at 80% of its power, to keep some in hand). Over the last
    // waypoint: settle.
    private _vAllow = sqrt ((_vCorner ^ 2) + (2 * 0.8 * _accel * ((_dist - _turnAt) max 0)));
    if (_next isEqualTo []) then { _vAllow = _vAllow min (_dist * 1.5); };
    // Search height over the higher of the ground here and ~2 s ahead.
    private _ahead = _p vectorAdd (_dirH vectorMultiply (((vectorMagnitude _v) * 2) min _dist));
    private _agl = (_p select 2) - (getTerrainHeightASL _p);
    private _zDes = ((getTerrainHeightASL _p) max (getTerrainHeightASL _ahead)) + (_s get "height");
    private _vz = (((_zDes - (_p select 2)) * 1.0) max -8) min 10;
    // Straight up first when taking off.
    private _vh = (_speed min _vAllow) * ((((_agl - 1.5) / 3) max 0) min 1);
    private _vDes = ((_dirH vectorMultiply _vh) vectorAdd [0, 0, _vz]) vectorAdd ([_uav, _p] call (_s get "separate"));
    // Something in the way in the next ~1.5 s: pull up.
    private _look = ((vectorMagnitude _v) * 1.5) max 15;
    if (_vh > 1 && { (lineIntersectsSurfaces [_p, _p vectorAdd ((vectorNormalized _vDes) vectorMultiply _look), _uav, objNull, true, 1, "GEOM", "NONE"]) isNotEqualTo [] }) then {
        _vDes = [(_vDes select 0) * 0.5, (_vDes select 1) * 0.5, (_vDes select 2) max 8];
    };
    // Weight: the velocity changes by at most "accel" m/s each second, whichever way.
    private _dv = _vDes vectorDiff _v;
    private _maxDv = _accel * _dt;
    if ((vectorMagnitude _dv) > _maxDv) then { _dv = (vectorNormalized _dv) vectorMultiply _maxDv; };
    _uav setVelocity (_v vectorAdd _dv);
};
addMissionEventHandler ["EachFrame", _cruise, [_cruiseState]];

// The waypoint after waypoint _i as the route goes on: the next one - or after a
// CYCLE, the one nearest to it, as the engine does, so a MOVE, MOVE, CYCLE patrol
// goes round for good (v1.2.0 treated CYCLE as the end of the route). -1: none.
private _followingWp = {
    params ["_wps", "_i"];
    if (waypointType (_wps select _i) != "CYCLE") exitWith { [-1, _i + 1] select (_i + 1 < count _wps) };
    private _at = waypointPosition (_wps select _i);
    private _best = -1;
    private _nearest = 1e9;
    for "_k" from 1 to (count _wps - 1) do {
        private _d = (waypointPosition (_wps select _k)) distance2D _at;
        if (_k != _i && { waypointType (_wps select _k) != "CYCLE" } && { _d < _nearest }) then { _nearest = _d; _best = _k; };
    };
    _best
};
private _turnsSeen = 0;

while {isNull _nearestEnemy && (!isNull _uavInstance)} do {
	if ([_uavInstance] call _is_dead) then {
		break;
	};
	if (([_uavInstance] call _disabledReason) != "") then {
		break;
	};
	_nearestEnemy = [_uavInstance, _unitKinds, _targetSource, _allowObjectParent, _targetDetectionRange, _targetSides] call _findNearestEnemyOfType;
	// Claim it and go straight away: other drones choosing in the same instant must
	// see the claim (with the sleep below in between, a whole swarm picked the same
	// two tanks), and it saves up to a second of reaction time.
	if (!isNull _nearestEnemy) then { [_nearestEnemy] call _claim; break; };

	// No target yet: fly the group's waypoints (e.g. ones set in Zeus) while
	// searching, steering the drone explicitly. Nothing here runs once a target
	// is found - the attack takes over.
	if (isNull _nearestEnemy && { [_uavInstance] call _isExternallyControlled }) then { _cruiseState set ["dest", []]; };
	if (isNull _nearestEnemy && { !([_uavInstance] call _isExternallyControlled) }) then {
		private _grp = group _uavInstance;
		private _wps = waypoints _grp;
		private _sig = (_wps select [1]) apply { waypointPosition _x };   // waypoint 0 is just the spawn point
		if !(_sig isEqualTo _wpSig) then {
			// New waypoints appended keep our place; a replaced route starts over.
			if !((_sig select [0, count _wpSig]) isEqualTo _wpSig) then { _wpIdx = 1; };
			_wpSig = _sig;
			_uavInstance setVariable ["FPV_AI_Drones_route", [_wpIdx, _wpSig]];
		};
		if (_wpIdx < count _wps) then {
			// The handler turns onto the next leg by itself, mid-turn; catch up with it.
			private _turns = _cruiseState get "turns";
			if (_turns > _turnsSeen) then {
				for "_n" from 1 to (_turns - _turnsSeen) do {
					private _f = [_wps, _wpIdx] call _followingWp;
					if (_f > 0) then { _wpIdx = _f; };
				};
				_turnsSeen = _turns;
				_uavInstance setVariable ["FPV_AI_Drones_route", [_wpIdx, _wpSig]];
				// Keep the group's own current waypoint on the one we fly to. A drone whose
				// AI follows waypoints itself (unlike the Crocus) otherwise leans towards a
				// different one while this script holds it on course: seen with the Ukraine
				// FPV Drone mod, hanging over its CYCLE waypoint tilted 45 degrees.
				_grp setCurrentWaypoint [_grp, _wpIdx];
			};
			private _wpPos = waypointPosition (_wps select _wpIdx);
			private _f = [_wps, _wpIdx] call _followingWp;
			private _nextPos = if (_f > 0) then { waypointPosition (_wps select _f) } else { [] };
			// Fly to it and on to the next - or, past the last one, stay parked over it.
			// In one go between two frames, and only if the handler hasn't just turned again.
			isNil {
				if ((_cruiseState get "turns") == _turnsSeen) then {
					_cruiseState set ["dest", _wpPos];
					_cruiseState set ["next", _nextPos];
				};
			};
			// Re-issue only when the waypoint moved, or every 10s as a backstop -
			// spamming move orders is what makes the flight look wobbly.
			if (!(_wpPos isEqualTo _lastWaypointOrder) || { diag_tickTime > _lastWaypointOrderTime + 10 }) then {
				if !(_wpPos isEqualTo _lastWaypointOrder) then {
					diag_log format ["FPV_AI_Drones: drone %1 following waypoint %2/%3 at %4 (%5m away)",
						_uavInstance, _wpIdx, count waypoints _grp, _wpPos, round (_uavInstance distance2D _wpPos)];
				};
				_uavInstance doMove _wpPos;
				_lastWaypointOrder = _wpPos;
				_lastWaypointOrderTime = diag_tickTime;
			};
		};
	};

	sleep (1);
};

// The attack run (or nothing, if the drone is gone) takes over from here.
_cruiseState set ["stop", true];

// Reachable whenever the drone dies or is deleted mid-search. This used to be
// "continue" at script scope, outside any loop, which throws a script error.
if (isNull _nearestEnemy) exitWith {
	if (!isNull _uavInstance && { alive _uavInstance }) then {
		private _why = [_uavInstance] call _disabledReason;
		if (_why != "") then { [_uavInstance, _why] call _markDisabled; };
	};
	if (!isNull _uavInstance) then {
		_uavInstance setVariable ["initialized", false];
		_uavInstance setVariable ["FPV_AI_Drones_runner", objNull];
	};
};

private _target = _nearestEnemy;
[_target] call _claim;
// Start of the attack run, for the time-to-kill in the detonation log line.
private _acquiredAt = diag_tickTime;
private _uavName = str _uavInstance;   // the drone is gone by the time the result is logged
diag_log format ["FPV_AI_Drones: drone %1 acquired %2 (%3) at %4m", _uavInstance, _target, typeOf _target, round (_uavInstance distance _target)];

// --- Attack run ---------------------------------------------------------------
// Flown by this script, not the AI pilot. The pilot slows down near every move
// point and re-plans each time the point moves, so runs took 35-65 s and a tank
// driving at 40 km/h was never caught (v1.1 test runs). From acquisition on, an
// EachFrame handler steers the drone's velocity at where the target will be,
// along a glide path that brings it down onto it. Every frame matters at this
// speed: 40 m/s is under a metre per frame, but several metres per scheduler
// tick - which is how the old terminal dive overshot or hit the hull first.

// m/s. Infantry are small and change direction, so AP drones default a bit slower.
private _attackSpeed = if (_attackSpeedKmh > 0) then { (_attackSpeedKmh / 3.6) max 5 } else {
    if ("Man" in _unitKinds) then { 40 } else { 50 }
};

// Accuracy: each run is rolled against the hit chance - at the start, and again after
// every fly-by. A miss is aimed beside the target, a few blast radii of the payload
// away so the miss is a miss. "Second Pass Chance" decides what kind of miss: a fly-by,
// low past that spot and round for another run (a Workshop wish: "not always crash into
// the ground, but a chance to make a second and more attack runs"), or the drone comes
// down there and its payload goes off. Sets the run state's "miss" (offset from the
// target; [] = aimed at it) and "flyby". Runs inside the handler too: nothing may sleep.
private _planMiss = {
    params ["_s"];
    private _uav = _s get "uav";
    private _target = _s get "target";
    _s set ["miss", []];
    _s set ["flyby", false];
    if ((random 100) < (_s get "hitChance")) exitWith {};
    private _miss = [];
    private _blastRadius = 0;
    private _reach = 0;
    {
        private _r = getNumber (configFile >> "CfgAmmo" >> _x >> "indirectHitRange");
        _blastRadius = _blastRadius max _r;
        // Where the blast is down to about 1 point of damage: it falls off with
        // (radius / distance)^4 past its radius. A soldier's armour is so thin that a
        // demo charge (1000, 3 m) still killed 3 of 4 from 9-11 m - so against infantry
        // a miss lands out there instead: ~17 m for the demo charge.
        _reach = _reach max (_r * ((getNumber (configFile >> "CfgAmmo" >> _x >> "indirectHit")) max 1) ^ 0.25);
    } forEach (_s get "ammo");
    private _off = ([(_blastRadius * 2.5) max 6, _reach] select (_target isKindOf "Man")) + random 4;
    private _tp = getPosASL _target;
    private _toT = _tp vectorDiff (getPosASL _uav);
    private _fwd = vectorNormalized [_toT select 0, _toT select 1, 0];
    if (_fwd isEqualTo [0, 0, 0]) then { _fwd = [0, 1, 0]; };
    // Beside the target or short of it - never beyond it, or the dive would cross it.
    // Of those spots, the one farthest from anyone else near the target: a miss on one
    // soldier must not come down in the middle of the rest of the squad.
    private _others = ((ASLToAGL _tp) nearEntities [["Man", "LandVehicle", "Air", "Ship"], _off * 2 + 10]) select { alive _x && { _x != _uav } };
    private _bestClear = -1;
    // Decided first: a fly-by can't use the spot straight short of the target - flying on
    // past it, the climb-out went over the tank and the payload went off on it.
    private _flyby = (random 100) < (_s get "secondPass");
    {
        private _a = _x + (random 20) - 10;   // degrees from straight ahead
        private _cand = [((_fwd select 0) * cos _a) - ((_fwd select 1) * sin _a), ((_fwd select 0) * sin _a) + ((_fwd select 1) * cos _a), 0] vectorMultiply _off;
        private _spot = _tp vectorAdd _cand;
        private _clear = _off * 2;
        { _clear = _clear min (_spot distance2D (getPosASL _x)); } forEach _others;
        if (_clear > _bestClear) then { _bestClear = _clear; _miss = _cand; };
    } forEach (([90, -90, 135, -135, 180] select { !_flyby || { _x != 180 } }) call BIS_fnc_arrayShuffle);
    _s set ["miss", _miss];
    _s set ["flyby", _flyby];
    diag_log format ["FPV_AI_Drones: drone %1 will miss (accuracy %2 percent): %3 %4m from %5, %6m from anyone",
        _uav, _s get "hitChance", ["coming down", "flying past"] select (_s get "flyby"), round vectorMagnitude _miss, _target, round _bestClear];
};

// Fallback trigger radius around the target's centre mass. Vehicles are normally
// set off on contact instead (see the trigger in _guide): a radius big enough for a
// tank's hull left the charge ~2 m short of it - crew killed, hull 20% damaged.
private _blastRange = 3;

// Puts the payload at _posASL; the handler sets it off on the next frame.
// Runs inside the handler, so nothing in here may sleep.
private _arm = {
    params ["_s", "_posASL", "_impacted", ["_aimASL", []]];
    // A warhead payload (rocket, missile or shell ammo - an RPG warhead, or the Crocus's
    // own FPV_RPG42_AT) is fired the last 1.5 m along the drone's flight path at 150 m/s,
    // so it strikes like the real round: a shaped charge works along its axis only, and
    // its penetrator needs the round's speed. A drone that misses drives it into the
    // ground. Set off where it stood (triggerAmmo, as the Crocus mod does) the warheads
    // barely scratched a tank (damage 0.06-0.11, crew alive).
    // Charges and mines just go off where they are (setDamage, next frame).
    // At the target when the drone got to it (_aimASL): fired along the flight path a
    // warhead went where a crossing car was going to be, and into the road beside it.
    private _dir = if (_aimASL isNotEqualTo [] && { (_aimASL vectorDistance _posASL) > 0.3 }) then {
        vectorNormalized (_aimASL vectorDiff _posASL)
    } else { vectorNormalized (_s getOrDefault ["vSet", [0, 0, -1]]) };
    if (_dir isEqualTo [0, 0, 0]) then { _dir = [0, 0, -1]; };
    private _up = if (abs (_dir select 2) < 0.99) then { vectorNormalized ((_dir vectorCrossProduct [0, 0, 1]) vectorCrossProduct _dir) } else { [0, 1, 0] };
    if ((_up select 2) < 0) then { _up = _up vectorMultiply -1; };
    private _charges = (_s get "ammo") apply {
        private _c = createVehicle [_x, ASLToAGL _posASL, [], 0, "CAN_COLLIDE"];
        _c setPosASL _posASL;
        if ((getText (configFile >> "CfgAmmo" >> _x >> "simulation")) in ["shotRocket", "shotMissile", "shotShell", "shotSubmunitions", "shotBullet"]) then {
            _c setPosASL (_posASL vectorDiff (_dir vectorMultiply 1.5));
            _c setVectorDirAndUp [_dir, _up];
            _c setVelocity (_dir vectorMultiply 150);
            _c setVariable ["FPV_AI_Drones_warhead", true];
            if (missionNamespace getVariable ["FPV_AI_Drones_debug", false]) then {
                private _t = _s get "target";
                diag_log format ["FPV_AI_Drones: trace warhead %1 launched at %2 dir %3 v %4, target %5 centre %6",
                    typeOf _c, (getPosASL _c) apply { _x toFixed 1 }, _dir apply { _x toFixed 2 }, (velocity _c) apply { _x toFixed 0 }, typeOf _t, (getPosASL _t) apply { _x toFixed 1 }];
                _c addEventHandler ["HitPart", { params ["_w", "_hit", "", "_pos", "_vel"];
                    diag_log format ["FPV_AI_Drones: trace warhead HitPart %1 at %2 v %3", typeOf _hit, _pos apply { _x toFixed 1 }, _vel apply { _x toFixed 0 }]; }];
                _c addEventHandler ["Explode", { params ["_w", "_pos", "_vel"];
                    diag_log format ["FPV_AI_Drones: trace warhead Explode at %1 v %2", _pos apply { _x toFixed 1 }, _vel apply { _x toFixed 0 }]; }];
                _c addEventHandler ["SubmunitionCreated", { params ["_w", "_sub"];
                    diag_log format ["FPV_AI_Drones: trace warhead penetrator %1 at %2 v %3", typeOf _sub, (getPosASL _sub) apply { _x toFixed 1 }, (velocity _sub) apply { _x toFixed 0 }]; }];
            };
        };
        _c
    };
    // deleteVehicleCrew is unary. It used to be written as a binary call, which
    // threw on this path - a candidate for "the drones explode but nothing dies".
    if (!isNull (_s get "uav")) then { deleteVehicleCrew (_s get "uav"); };
    // A warhead in flight would hit the drone it starts behind: the drone goes now (as
    // the Crocus mod removes its drone when it fires its own warhead).
    if (!isNull (_s get "uav") && { (_charges findIf { _x getVariable ["FPV_AI_Drones_warhead", false] }) >= 0 }) then {
        deleteVehicle (_s get "uav");
    };
    _s set ["charges", _charges];
    _s set ["blastPos", _posASL];
    _s set ["impacted", _impacted];
    _s set ["phase", "armed"];
};

private _guide = {
    private _s = _thisArgs select 0;
    if (isGamePaused) exitWith {};
    private _uav = _s get "uav";
    private _target = _s get "target";

    if ((_s get "phase") == "armed") exitWith {
        {
            if (_x getVariable ["FPV_AI_Drones_warhead", false]) then {
                // In flight - it goes off on impact. If it somehow hasn't in a second, set it off.
                [_x] spawn { params ["_w"]; sleep 1; if (!isNull _w) then { triggerAmmo _w; }; };
            } else { _x setDamage 1; };
        } forEach (_s get "charges");
        if (!isNull _uav) then { _uav setDamage 1; };
        // "Delete Drone After Detonation": no wreck - few FPV drones have a proper
        // destroyed model, and very little is left of a real one (a Workshop wish).
        if ((_s get "deleteDrone") && { !isNull _uav }) then { deleteVehicle _uav; };
        _s set ["result", "detonated"];
        _s set ["phase", "done"];
        removeMissionEventHandler ["EachFrame", _thisEventHandler];
    };

    private _last = _s get "lastPos";
    // The point the run is flown at: the target's centre mass (not the ground under
    // it) - or for a planned miss, the ground beside it, moving with it.
    private _miss = _s get "miss";
    private _flyingPast = (_s get "flyby") && { _miss isNotEqualTo [] };
    private _tPos = if (_miss isEqualTo []) then { (getPosASL _target) vectorAdd [0, 0, 1] } else {
        private _g = (getPosASL _target) vectorAdd _miss;
        // A fly-by passes the spot 5 m up; otherwise the drone goes down on it.
        [_g select 0, _g select 1, (getTerrainHeightASL _g) + ([0, 5] select _flyingPast)]
    };

    // Drone gone: it hit something, its own warhead went off and the Crocus mod
    // deleted it. Next to the target that is the hit we wanted, so set the payload
    // off where it last was; anywhere else it just crashed.
    if (isNull _uav || { !alive _uav }) exitWith {
        if (!isNull _target && { (_last vectorDistance _tPos) < 10 }) then {
            [_s, _last, true] call (_s get "arm");
        } else {
            _s set ["result", format ["drone lost %1m from the target - no detonation", round (_last vectorDistance _tPos)]];
            _s set ["phase", "done"];
            removeMissionEventHandler ["EachFrame", _thisEventHandler];
        };
    };

    // Taken out mid-run (jammer, crew killed, operator dead...): stop flying it, here and
    // now. It comes down where it is, and the payload doesn't go off on the target.
    private _whyDisabled = [_uav] call (_s get "disabled");
    if (_whyDisabled != "") exitWith {
        _s set ["result", "drone disabled: " + _whyDisabled];
        _s set ["phase", "done"];
        removeMissionEventHandler ["EachFrame", _thisEventHandler];
    };

    // Stop requested by the script below (target dead, out of range, taken over...).
    // Done here so the two can never disagree about whether the charge went off.
    if ((_s get "abort") != "") exitWith {
        _s set ["result", _s get "abort"];
        _s set ["phase", "done"];
        removeMissionEventHandler ["EachFrame", _thisEventHandler];
    };

    if (isNull _target) exitWith {
        _s set ["result", "target deleted"];
        _s set ["phase", "done"];
        removeMissionEventHandler ["EachFrame", _thisEventHandler];
    };

    private _dt = diag_deltaTime * accTime;
    if (_dt <= 0) exitWith {};
    private _p = getPosASL _uav;
    // Steer from the velocity set last frame, not the one read back. Between frames the
    // AI pilot's rotors push the drone towards the height it holds, and that push built
    // up: at Braking Time 3 a drone told to sink at 25 m/s for a second was sinking at 2,
    // still 31 m up 70 m from a tank. A big difference is something real (a bump, a
    // blast, the ground on takeoff): then go on from what the engine says.
    private _v = velocity _uav;
    private _vSet = _s getOrDefault ["vSet", _v];
    if ((_vSet vectorDistance _v) < 4) then { _v = _vSet; };
    private _speed = _s get "speed";
    private _blast = _s get "blast";
    _s set ["lastPos", _p];

    // A fly-by: once past its spot (within 6 m, or getting further again after coming
    // within 15 m) the pass is over. The drone flies on and climbs out ("outbound",
    // steered below), and only out there is the next run rolled and planned. Planned at
    // the pass itself, a spot "short of the target" lay right under the drone: it counted
    // a second pass at once and went into the ground turning round 5 m up.
    if (_flyingPast && { !("outbound" in _s) }) then {
        private _dFly = _p vectorDistance _tPos;
        private _bestFly = (_s getOrDefault ["flyBest", 1e9]) min _dFly;
        _s set ["flyBest", _bestFly];
        if (_dFly < 6 || { _bestFly < 15 && { _dFly > _bestFly + 2 } }) then {
            private _passes = (_uav getVariable ["FPV_AI_Drones_passes", 0]) + 1;
            _uav setVariable ["FPV_AI_Drones_passes", _passes, true];
            _s deleteAt "flyBest";
            _s set ["outbound", diag_tickTime];
            diag_log format ["FPV_AI_Drones: drone %1 flew past %2 (pass %3) - climbing out for another run", _uav, _target, _passes];
        };
    };
    // Out far enough to turn back with room for a glide and a dive: the next run.
    if ("outbound" in _s) then {
        private _fromT = _p vectorDiff (getPosASL _target);
        if ((vectorMagnitude [_fromT select 0, _fromT select 1, 0]) > 60 || { diag_tickTime > (_s get "outbound") + 4 }) then {
            _s deleteAt "outbound";
            _s set ["runs", (_s getOrDefault ["runs", 0]) + 1];
            [_s] call (_s get "planMiss");
            diag_log format ["FPV_AI_Drones: drone %1 turning back for run %2 on %3: %4",
                _uav, (_s get "runs") + 1, _target, ["aimed at it", "another miss"] select ((_s get "miss") isNotEqualTo [])];
        };
    };

    // --- trigger: in blast range, or will be by next frame, ...
    // (not on a fly-by: its spot is where the drone passes, not where it goes off)
    private _fire = [];
    private _fireAim = [];   // where a warhead payload is pointed - see _arm
    if (!_flyingPast && { (_p vectorDistance _tPos) <= _blast + ((vectorMagnitude _v) * _dt) }) then { _fire = _p; _fireAim = _tPos; };
    // ... or passed through it since last frame (low frame rate), ...
    if (_fire isEqualTo [] && { !_flyingPast }) then {
        private _seg = _p vectorDiff _last;
        private _segLen2 = _seg vectorDotProduct _seg;
        if (_segLen2 > 0.01) then {
            private _u = ((((_tPos vectorDiff _last) vectorDotProduct _seg) / _segLen2) max 0) min 1;
            private _closest = _last vectorAdd (_seg vectorMultiply _u);
            if ((_closest vectorDistance _tPos) <= _blast) then { _fire = _closest; _fireAim = _tPos; };
        };
    };
    // ... or about to hit something right next to the target (its hull, a wall):
    // then the charge goes off right on the surface it's about to hit. "About to" is
    // two frames' travel plus 1 m for the drone's own size: with less, at 50 m/s its
    // body still hit the hull between two checks (traced: skin 2.6 m away, then impact).
    // Flying past, only the target itself sets it off - not the ground it skims.
    private _near = if (_flyingPast) then { (getPosASL _target) vectorAdd [0, 0, 1] } else { _tPos };
    if (_fire isEqualTo [] && { (_p vectorDistance _near) < 15 }) then {
        private _reach = ((vectorMagnitude _v) * _dt * 2) + 1;
        private _hits = lineIntersectsSurfaces [_p, _p vectorAdd ((vectorNormalized _v) vectorMultiply _reach), _uav, objNull, true, 1, "FIRE", "GEOM"];
        // The target's skin straight towards its centre can be nearer than along the path.
        if (_hits isEqualTo []) then {
            _hits = (lineIntersectsSurfaces [_p, _near, _uav, objNull, true, 1, "FIRE", "GEOM"]) select { ((_x select 0) vectorDistance _p) < _reach };
        };
        if (_hits isNotEqualTo []) then {
            (_hits select 0) params ["_hitPos", "_hitNormal", "_hitObj", "_hitParent"];
            // The target's own hull: aim the warhead into it. Anything else (the ground,
            // a wall): it goes off along the flight path.
            private _onTarget = !isNull _target && { [_target, objectParent _target] findIf { !isNull _x && { _x in [_hitObj, _hitParent] } } >= 0 };
            if (!_flyingPast || { _onTarget }) then {
                _fire = _hitPos vectorAdd (_hitNormal vectorMultiply 0.3);
                if (_onTarget) then { _fireAim = _hitPos; };
            };
        };
    };
    if (_fire isNotEqualTo []) exitWith { [_s, _fire, false, _fireAim] call (_s get "arm"); };

    // --- steering: lead the target - aim where it will be when we get there. Time to
    // get there at the speed the drone is actually doing: in a dive it can be well under
    // top speed, and leading by top speed left it behind a crossing car (Braking Time 2).
    private _tVel = velocity _target;
    private _aim = _tPos;
    private _closing = (vectorMagnitude _v) max (_speed * 0.5);
    for "_i" from 1 to 2 do {
        _aim = _tPos vectorAdd (_tVel vectorMultiply (((_aim vectorDistance _p) / _closing) min 6));
    };
    private _toAim = _aim vectorDiff _p;
    private _toAimH = [_toAim select 0, _toAim select 1, 0];
    private _d2 = vectorMagnitude _toAimH;
    private _ground = getTerrainHeightASL _p;

    // --- obstacles at the target: how steep must the final dive be?
    // A few times a second, find the lowest height from which there's a clear
    // straight line down to the target from 30 m out. In the open that's a shallow,
    // fast dive; a tank parked behind a building needs a steep one - flying the
    // shallow line went straight into the wall.
    if (diag_tickTime > (_s getOrDefault ["planAt", 0])) then {
        _s set ["planAt", diag_tickTime + 0.25];
        private _back = if (_d2 > 1) then { (vectorNormalized _toAimH) vectorMultiply -30 } else { [0, -30, 0] };
        private _termH = 45;
        {
            if ((lineIntersectsSurfaces [(_aim vectorAdd _back) vectorAdd [0, 0, _x], _aim, _uav, _target, true, 1, "GEOM", "FIRE"]) isEqualTo []) exitWith { _termH = _x; };
        } forEach [10, 18, 27, 36];
        _s set ["termH", _termH];
        _s set ["clear", (lineIntersectsSurfaces [_p, _aim, _uav, _target, true, 1, "GEOM", "FIRE"]) isEqualTo []];
    };
    private _termH = _s getOrDefault ["termH", 10];
    private _clear = _s getOrDefault ["clear", true];
    // Blocked inside 30 m: climb until the way down is clear - but not forever (a
    // target under a roof never clears); after 3 s just go for it.
    if (_d2 < 30 && { !_clear }) then {
        if !("blockedAt" in _s) then { _s set ["blockedAt", diag_tickTime]; };
    } else {
        _s deleteAt "blockedAt";
    };
    private _popUp = _d2 < 30 && { !_clear } && { diag_tickTime < (_s get "blockedAt") + 3 };

    // Missed: low, the aim point not ahead any more (the target swerved, or the drone
    // overshot), and further away than the drone is high - no dive left that reaches it.
    // Then it pulls up and makes a new pass instead of flying on into the ground next
    // to the target (Braking Time 2: a drone went down 19 m from a car that had driven
    // past it, and was lost without going off). Straight over the target is not a miss.
    // "Low" grows with the sink rate - stopping a 22 m/s sink takes ~12 m at 25 m/s2 -
    // and when there is no longer room to stop sinking, pulling up is pointless: it
    // keeps diving at the target, so at least the payload goes off near it.
    private _agl = (_p select 2) - _ground;
    private _vMag = vectorMagnitude _v;
    private _sink = (-(_v select 2)) max 0;
    private _missed = _vMag > 5 && { _d2 > _agl }
        && { _agl < ((((_sink ^ 2) / (1.6 * (_s get "accel"))) + 3) max 8) }
        && { _agl > (((_sink ^ 2) / (2 * (_s get "accel"))) + 1.5) }
        && { ((_v vectorDotProduct _toAim) / (_vMag * ((vectorMagnitude _toAim) max 0.1))) < 0.3 };

    private _vDes = [];
    private _sep = [0, 0, 0];
    if (_d2 < 30 && { !_popUp } && { !_missed }) then {
        // Terminal: straight at it - as fast as the drone can still turn onto it. The arc
        // from its heading onto the aim point has radius d / (2 sin a), and flying it takes
        // v^2 / radius of its acceleration. A heavy drone that arrives fast and high slows
        // down to tip into the dive, as a pilot would (Braking Time 2: still 31 m/s forward
        // 12 m over a tank, and it went past). Never slower than the target + 10 m/s: a
        // drone that slowed below a car's speed circled it and never caught it.
        private _dAim = (vectorMagnitude _toAim) max 0.1;
        private _cosA = if (_vMag > 1) then { (_v vectorDotProduct _toAim) / (_vMag * _dAim) } else { 1 };
        private _sinA = if (_cosA < 0) then { 1 } else { sqrt ((1 - (_cosA ^ 2)) max 0) };
        private _vTurn = if (_sinA > 0.01) then { sqrt (0.8 * (_s get "accel") * _dAim / (2 * _sinA)) } else { _speed };
        _vDes = (_toAim vectorMultiply (1 / _dAim)) vectorMultiply ((_speed min _vTurn) max (((vectorMagnitude _tVel) + 10) max 12));
        // A fly-by levels out at its spot's height instead of diving on through it, and
        // keeps its speed: no braking for a dive. Aimed at like a dive, the drone spent
        // its acceleration braking forward, passed the spot still sinking at 17-20 m/s and
        // bottomed out 1-4 m over the ground. It sinks only as fast as the line to the
        // spot needs, and no faster than it can stop by then on 60% of its acceleration.
        if (_flyingPast) then {
            private _vHNow = vectorMagnitude [_v select 0, _v select 1, 0];
            private _vhF = (_vHNow max ((vectorMagnitude _tVel) + 10)) min _speed;
            private _above = (_p select 2) - (_tPos select 2);
            private _vzF = if (_above > 0) then {
                (-_above * _vhF / (_d2 max 1)) max (-sqrt (1.2 * (_s get "accel") * _above))
            } else { (-_above * 2) min 15 };
            _vDes = ((vectorNormalized _toAimH) vectorMultiply _vhF) vectorAdd [0, 0, _vzF];
        };
        _s set ["wantAgl", [2, 5] select _flyingPast];
    } else {
        // Glide path: down at ~1:3 to the dive's entry point (30 m out, _termH up),
        // never higher above the target than the search height (unless the dive needs
        // it), never lower than 5 m over the ground on the way.
        // The descent may be as fast as the slope needs plus some to catch up: capped
        // at 15 m/s - less than the slope's 17.5 at 180 km/h - drones reached the dive
        // entry 10 m too high, which a heavy drone could not make up (it overshot).
        private _slope = 0.35;
        private _ceiling = (_s get "cruise") max _termH;
        // Reach the dive entry slow enough to turn onto the target within its last 30 m
        // (a 30 m turn at the drone's acceleration: 32 m/s at Braking Time 1.5, 22 at 3,
        // never slower than the target + 10), braking for it the way it brakes for a
        // waypoint. A drone at Braking Time 3 reached the dive at 47 m/s and flew 6 m
        // over a parked tank.
        private _vEntry = (sqrt (30 * (_s get "accel"))) max ((vectorMagnitude _tVel) + 10);
        private _vhPlan = _speed min (sqrt ((_vEntry ^ 2) + (2 * 0.8 * (_s get "accel") * ((_d2 - 30) max 0))));
        // It also needs room to set up its sink rate - at Braking Time 2, 0.7 s and 35 m.
        // Flying the slope from where it starts, the drone reached a dive entry 18 m up
        // at 27 m and passed 10 m over a tank behind a building. So it follows the slope
        // as it will be half that distance on, and is on it by the time it matters.
        private _vH = vectorMagnitude [_v select 0, _v select 1, 0];
        private _dSlope = _d2 - (_vH * ((_slope * _vhPlan) / (_s get "accel")) / 2);
        private _hRel = (_termH + (((_dSlope - 30) max 0) * _slope)) min _ceiling;
        private _onSlope = _dSlope > 30 && { _hRel < _ceiling };
        private _zDes = ((_aim select 2) + _hRel) max (_ground + 5);
        _s set ["wantAgl", (_zDes - _ground) max 2];
        private _vz = ((((_zDes - (_p select 2)) * 1.5) + ([0, -_slope * _vhPlan] select _onSlope)) max -((_slope * _vhPlan) + 8)) min 15;
        // A fly-by brakes its sink for the spot already on the glide (see the terminal
        // branch): handed over at 24 m/s down, it still passed sinking 17 and got to 3.5 m.
        if (_flyingPast) then { _vz = _vz max (-sqrt (1.2 * (_s get "accel") * (((_p select 2) - (_tPos select 2)) max 0))); };
        private _vh = _vhPlan min (sqrt (((_speed ^ 2) - (_vz ^ 2)) max 0));
        // Still lifting off: straight up until clear of the ground (dragging along it
        // counts as a hit - see the attitude note below), then ease into going flat out.
        _vh = _vh * (((((_p select 2) - _ground - 1.5) / 3) max 0) min 1);
        // Popping up over cover: slow down so the climb happens before the wall does.
        if (_popUp) then { _vh = _vh * 0.3; };
        _sep = [_uav, _p] call (_s get "separate");
        _vDes = (((vectorNormalized _toAimH) vectorMultiply _vh) vectorAdd [0, 0, _vz]) vectorAdd _sep;

        // Something in the way in the next ~1.5 s (trees, a building, a ridge): pull up.
        private _look = (((vectorMagnitude _v) * 1.5) max 15) min ((_d2 - 5) max 3);
        private _ahead = _p vectorAdd ((vectorNormalized _vDes) vectorMultiply _look);
        if ((lineIntersectsSurfaces [_p, _ahead, _uav, _target, true, 1, "GEOM", "NONE"]) isNotEqualTo []) then {
            _vDes = [(_vDes select 0) * 0.5, (_vDes select 1) * 0.5, (_vDes select 2) max 10];
        };
        // After a miss, stop sinking before anything else: all of the drone's
        // acceleration goes into climbing until it is, then it turns back for the pass.
        if (_missed && { (_v select 2) < 0 }) then { _vDes = [_v select 0, _v select 1, 4]; };
    };

    // Outbound after a fly-by: hold the heading and climb to 25 m (or the search height,
    // if lower), at no more than 70% of top speed so the turn back is short.
    if ("outbound" in _s) then {
        private _vh = [_v select 0, _v select 1, 0];
        private _away = if ((vectorMagnitude _vh) > 1) then { _vh } else { _p vectorDiff (getPosASL _target) };
        private _dirH = vectorNormalized [_away select 0, _away select 1, 0];
        // The target straight ahead (it drove into the way): turn off to the side, not over it.
        private _toT = (getPosASL _target) vectorDiff _p;
        _toT set [2, 0];
        if ((vectorMagnitude _toT) < 40 && { (_dirH vectorDotProduct (vectorNormalized _toT)) > 0.7 }) then {
            private _side = vectorNormalized [-(_toT select 1), _toT select 0, 0];
            if ((_side vectorDotProduct _dirH) < 0) then { _side = _side vectorMultiply -1; };
            _dirH = _side;
        };
        private _zWant = _ground + ((_s get "cruise") min 25);
        // Below 8 m it climbs whatever the height it wants: no skimming the ground.
        private _vz = (((_zWant - (_p select 2)) * 1.5) max ([-5, 4] select (((_p select 2) - _ground) < 8))) min 15;
        _sep = [_uav, _p] call (_s get "separate");
        _vDes = ((_dirH vectorMultiply (((vectorMagnitude _vh) max 15) min (_speed * 0.7))) vectorAdd [0, 0, _vz]) vectorAdd _sep;
        if ((lineIntersectsSurfaces [_p, _p vectorAdd ((vectorNormalized _vDes) vectorMultiply (((vectorMagnitude _v) * 1.5) max 15)), _uav, objNull, true, 1, "GEOM", "NONE"]) isNotEqualTo []) then {
            _vDes = [(_vDes select 0) * 0.5, (_vDes select 1) * 0.5, (_vDes select 2) max 10];
        };
        _s set ["wantAgl", _zWant - _ground];
    };

    // Ease towards it rather than snapping: at most "accel" m/s per second of change -
    // except to keep clear of another drone, which gets up to three times that, like a
    // reflex. Without it heavy drones (Braking Time 3) collided just after takeoff.
    private _dv = _vDes vectorDiff _v;
    private _maxDv = ((_s get "accel") max ((vectorMagnitude _sep) * 3)) * _dt;
    if ((vectorMagnitude _dv) > _maxDv) then { _dv = (vectorNormalized _dv) vectorMultiply _maxDv; };
    private _vNew = _v vectorAdd _dv;

    // Velocity only - the attitude is left to the AI pilot. Setting it every frame
    // (setVectorDirAndUp) cancels that frame's movement: in testing the drone read
    // back 40 m/s while actually crawling at ~1 m/s. Pointing the nose along a climb
    // also tipped the tail into the ground on takeoff, and the Crocus mod treats ANY
    // hit as impact - its "hit" handler fires the drone's own warhead and deletes it.
    _uav setVelocity _vNew;
    _s set ["vSet", _vNew];

    // Flight trace for tuning (FPV_AI_Drones_debug = true): the first frames, then twice a second.
    if (missionNamespace getVariable ["FPV_AI_Drones_debug", false]) then {
        private _n = (_s getOrDefault ["frames", 0]) + 1;
        _s set ["frames", _n];
        if (_n <= 5 || { (_p vectorDistance _tPos) < 20 } || { diag_tickTime > (_s getOrDefault ["traceAt", 0]) }) then {
            _s set ["traceAt", diag_tickTime + 0.5];
            diag_log format ["FPV_AI_Drones: trace %1 f%2 dt=%3 agl=%4 v=%5 (%6 m/s) vDes=%7 d3=%8 d2aim=%9 termH=%10 clear=%11 popUp=%12 missed=%13",
                _uav, _n, _dt toFixed 3, ((_p select 2) - _ground) toFixed 1, _v apply { _x toFixed 1 }, (vectorMagnitude _v) toFixed 1,
                _vDes apply { _x toFixed 1 }, (_p vectorDistance _tPos) toFixed 1, _d2 toFixed 1, _termH, _clear, _popUp, _missed];
        };
    };
};

private _state = createHashMapFromArray [
    ["uav", _uavInstance], ["target", _target], ["phase", "run"], ["abort", ""], ["result", ""],
    ["speed", _attackSpeed], ["accel", _attackSpeed / _brakingTime], ["cruise", _initialSearchHeight],
    ["miss", []], ["flyby", false], ["hitChance", _hitChance], ["secondPass", _secondPass], ["planMiss", _planMiss],
    ["deleteDrone", _deleteDrone], ["disabled", _disabledReason],
    ["blast", _blastRange], ["ammo", _customAmmo splitString ", "],
    ["lastPos", getPosASL _uavInstance], ["arm", _arm], ["separate", _separation],
    ["charges", []], ["blastPos", []], ["impacted", false]
];
[_state] call _planMiss;
_uavInstance engineOn true;
addMissionEventHandler ["EachFrame", _guide, [_state]];
if (missionNamespace getVariable ["FPV_AI_Drones_debug", false]) then {
    _uavInstance addEventHandler ["Hit", { params ["_u", "_src", "_dmg", "_inst"];
        diag_log format ["FPV_AI_Drones: trace %1 HIT by %2 (%3) dmg %4 v=%5", _u, _src, typeOf _src, _dmg, velocity _u]; }];
    _uavInstance addEventHandler ["Killed", { params ["_u", "_k"];
        diag_log format ["FPV_AI_Drones: trace %1 KILLED by %2 at %3", _u, _k, getPosATL _u]; }];
    _uavInstance addEventHandler ["Deleted", { params ["_u"];
        diag_log format ["FPV_AI_Drones: trace %1 DELETED at %2 v=%3", _u, getPosATL _u, velocity _u]; }];
};

// The handler flies and fires; this loop decides when to give up and keeps the
// target choice current.
private _best = _uavInstance distance _target;
private _bestAt = diag_tickTime;
private _lastLook = diag_tickTime;
private _lastOrder = -1e9;
private _pilotAgl = _initialSearchHeight;
private _runsSeen = 0;
while { (_state get "phase") == "run" && { (_state get "abort") == "" } } do {
    sleep 0.25;
    // Drone just died: the handler decides whether that was the hit. Don't race it.
    if ([_uavInstance] call _is_dead) then { continue; };
    private _d = _uavInstance distance _target;
    if (_d < _best - 3) then { _best = _d; _bestAt = diag_tickTime; };
    // Climbing out after a fly-by is no lack of progress; the run after it gets the full
    // 12 s, counted from where it turns back.
    if ("outbound" in _state) then { _bestAt = diag_tickTime; };
    if ((_state getOrDefault ["runs", 0]) != _runsSeen) then { _runsSeen = _state getOrDefault ["runs", 0]; _best = _d; _bestAt = diag_tickTime; };
    private _reason = switch (true) do {
        case (([_uavInstance] call _disabledReason) != ""): { "drone disabled: " + ([_uavInstance] call _disabledReason) };
        case ([_uavInstance] call _isExternallyControlled): { "taken over by a player (UAV terminal or Zeus)" };
        case ([_target] call _is_dead): { "target destroyed before the drone got there" };
        // Crew killed (e.g. by another drone): the hull is still "alive" but no longer
        // an enemy - don't waste a second drone on it, find a live target instead.
        case (!([_uavInstance, _target, _targetSides] call _isHostile)): { "target no longer hostile (crew dead or vehicle empty)" };
        // A target that drives away is chased well past the range it was spotted at.
        case (_d > _targetDetectionRange * 1.5): {
            format ["lost target - %1m away (range %2m x 1.5)", round _d, _targetDetectionRange]
        };
        case (diag_tickTime - _bestAt > 12): {
            format ["no progress for 12s (closest %1m, now %2m)", round _best, round _d]
        };
        default { "" };
    };
    if (_reason != "") then {
        _state set ["abort", _reason];
    } else {
        // Switch only to a clearly closer target - flip-flopping between two
        // similar ones is worse than either.
        if (diag_tickTime > _lastLook + 2) then {
            _lastLook = diag_tickTime;
            private _new = [_uavInstance, _unitKinds, _targetSource, _allowObjectParent, _targetDetectionRange, _targetSides] call _findNearestEnemyOfType;
            if (!isNull _new && { _new != _target } && { (_uavInstance distance _new) < _d * 0.6 }) then {
                diag_log format ["FPV_AI_Drones: drone %1 switching to %2 (%3m) from %4 (%5m)",
                    _uavInstance, _new, round (_uavInstance distance _new), _target, round _d];
                [_target] call _unclaim;
                _target = _new;
                [_target] call _claim;
                _state set ["target", _new];
                _best = _uavInstance distance _new;
                _bestAt = diag_tickTime;
            };
        };
        // Keep the AI pilot's own order pointing the same way, so between frames it
        // isn't pulling against the steering.
        if (diag_tickTime > _lastOrder + 1) then {
            _uavInstance doMove (getPosATL _target);
            _lastOrder = diag_tickTime;
        };
        // Same for height: the pilot holds the height it was given (search height), and
        // between frames its rotors pushed back against the glide - a commanded 13.5 m/s
        // more sink over half a second came out as 10. Give it the height the run wants.
        private _wantAgl = round (_state getOrDefault ["wantAgl", _initialSearchHeight]);
        if (abs (_wantAgl - _pilotAgl) >= 2) then {
            _uavInstance flyInHeight [_wantAgl, true];
            _pilotAgl = _wantAgl;
        };
    };
};

// Let the handler finish what it started - an armed charge goes off next frame.
private _settleBy = diag_tickTime + 3;
waitUntil { sleep 0.05; (_state get "phase") == "done" || { diag_tickTime > _settleBy } };
[_target] call _unclaim;

if ((_state get "result") == "detonated") then {
    // One line per detonation per machine. More than one for the same drone
    // means the explosives are being duplicated across machines again.
    diag_log format ["FPV_AI_Drones: drone %1 detonating %2 on %3 at %4m%5 on machine %6, %7s after acquiring the target",
        _uavName, _state get "ammo", _target, round ((_state get "blastPos") vectorDistance (getPosASL _target)),
        (["", " (drone impacted first)"] select (_state get "impacted")) + (["", " - a planned miss"] select ((_state get "miss") isNotEqualTo [])),
        clientOwner, (diag_tickTime - _acquiredAt) toFixed 1];
} else {
    diag_log format ["FPV_AI_Drones: drone %1 broke off its attack run: %2", _uavName, _state get "result"];
    if (!isNull _uavInstance && { alive _uavInstance }) then {
        private _why = [_uavInstance] call _disabledReason;
        if (_why != "") then { [_uavInstance, _why] call _markDisabled; };
    };
};

// At the end of the script, ensure cleanup
if (!isNull _uavInstance) then {
	_uavInstance setVariable ["initialized", false];
	_uavInstance setVariable ["FPV_AI_Drones_runner", objNull];
};
