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
    ["_attackSpeedKmh", -1]       // top speed of the attack run; -1 = 180 (vehicles) / 144 (infantry)
];
// Since v1.2 _attackDistance, _attackDistance2D, _attackHeight and the delay/stuck
// parameters are unused (the attack run is flown below); they stay for compatibility.

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

// Whether _other is a target under the module's "Target Sides" setting.
//   ENEMIES - whatever the mission's side relations call hostile to the drone (default, as in v1.1)
//   EAST / WEST / GUER - that side only, regardless of relations
//   NOTOWN  - every combat side except the drone's own; civilians never
private _isHostile = {
    params ["_uav", "_other", "_mode"];
    private _s = side _other;
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
        ([_uav, _x, _sides] call _isHostile) && { [_x, _kinds] call _isUnitOfKind }
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
_uavInstance setVariable ["FPV_AI_Drones_runner", _uavInstance];

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
// While it has a waypoint, this handler flies it there at ~125 km/h, at search
// height over the ground, easing into the waypoint and parking over the last one.
// The search loop below sets "dest"; [] leaves the drone to the AI pilot.
private _cruiseState = createHashMapFromArray [
    ["uav", _uavInstance], ["dest", []], ["stop", false],
    ["speed", 35], ["height", _initialSearchHeight], ["separate", _separation]
];
private _cruise = {
    private _s = _thisArgs select 0;
    private _uav = _s get "uav";
    if ((_s get "stop") || { isNull _uav } || { !alive _uav }) exitWith {
        removeMissionEventHandler ["EachFrame", _thisEventHandler];
    };
    private _dest = _s get "dest";
    if (_dest isEqualTo [] || { isGamePaused }) exitWith {};
    private _dt = diag_deltaTime * accTime;
    if (_dt <= 0) exitWith {};
    if (!isEngineOn _uav) then { _uav engineOn true; };   // else it rises with its rotors still
    private _p = getPosASL _uav;
    private _v = velocity _uav;
    private _toH = [(_dest select 0) - (_p select 0), (_dest select 1) - (_p select 1), 0];
    private _dist = vectorMagnitude _toH;
    private _dirH = if (_dist > 0.5) then { vectorNormalized _toH } else { [0, 0, 0] };
    // Search height over the higher of the ground here and ~2 s ahead.
    private _ahead = _p vectorAdd (_dirH vectorMultiply (((vectorMagnitude _v) * 2) min _dist));
    private _agl = (_p select 2) - (getTerrainHeightASL _p);
    private _zDes = ((getTerrainHeightASL _p) max (getTerrainHeightASL _ahead)) + (_s get "height");
    private _vz = (((_zDes - (_p select 2)) * 1.0) max -8) min 10;
    // Slow into the waypoint; straight up first when taking off.
    private _vh = ((_s get "speed") min (_dist * 0.5)) * ((((_agl - 1.5) / 3) max 0) min 1);
    private _vDes = ((_dirH vectorMultiply _vh) vectorAdd [0, 0, _vz]) vectorAdd ([_uav, _p] call (_s get "separate"));
    // Something in the way in the next ~1.5 s: pull up.
    private _look = ((vectorMagnitude _v) * 1.5) max 15;
    if (_vh > 1 && { (lineIntersectsSurfaces [_p, _p vectorAdd ((vectorNormalized _vDes) vectorMultiply _look), _uav, objNull, true, 1, "GEOM", "NONE"]) isNotEqualTo [] }) then {
        _vDes = [(_vDes select 0) * 0.5, (_vDes select 1) * 0.5, (_vDes select 2) max 8];
    };
    private _dv = _vDes vectorDiff _v;
    private _maxDv = 25 * _dt;
    if ((vectorMagnitude _dv) > _maxDv) then { _dv = (vectorNormalized _dv) vectorMultiply _maxDv; };
    _uav setVelocity (_v vectorAdd _dv);
};
addMissionEventHandler ["EachFrame", _cruise, [_cruiseState]];

while {isNull _nearestEnemy && (!isNull _uavInstance)} do {
	if ([_uavInstance] call _is_dead) then {
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
			private _wpIndex = _wpIdx;
			private _wpPos = waypointPosition (_wps select _wpIdx);
			// Fly to it - and once it's the last one reached, stay parked over it.
			_cruiseState set ["dest", _wpPos];
			if (_uavInstance distance2D _wpPos < 40) then {
				_wpIdx = _wpIdx + 1;
				// CYCLE: carry on from the waypoint nearest to it, as the engine does, so
				// a MOVE, MOVE, CYCLE patrol goes round for good. It used to be treated as
				// the end of the route: the drone parked there after one lap.
				if (waypointType (_wps select _wpIndex) == "CYCLE") then {
					private _next = -1;
					private _nearest = 1e9;
					for "_i" from 1 to (count _wps - 1) do {
						private _d = (waypointPosition (_wps select _i)) distance2D _wpPos;
						if (_i != _wpIndex && { waypointType (_wps select _i) != "CYCLE" } && { _d < _nearest }) then {
							_nearest = _d;
							_next = _i;
						};
					};
					if (_next > 0) then { _wpIdx = _next; };
				};
				_uavInstance setVariable ["FPV_AI_Drones_route", [_wpIdx, _wpSig]];
				// Keep the group's own current waypoint on the one we fly to. A drone whose
				// AI follows waypoints itself (unlike the Crocus) otherwise leans towards a
				// different one while this script holds it on course: seen with the Ukraine
				// FPV Drone mod, hanging over its CYCLE waypoint tilted 45 degrees.
				if (_wpIdx < count _wps) then { _grp setCurrentWaypoint [_grp, _wpIdx]; };
				_lastWaypointOrder = [];
			} else {
				// Re-issue only when the waypoint moved, or every 10s as a backstop -
				// spamming move orders is what makes the flight look wobbly.
				if (!(_wpPos isEqualTo _lastWaypointOrder) || { diag_tickTime > _lastWaypointOrderTime + 10 }) then {
					if !(_wpPos isEqualTo _lastWaypointOrder) then {
						diag_log format ["FPV_AI_Drones: drone %1 following waypoint %2/%3 at %4 (%5m away)",
							_uavInstance, _wpIndex, count waypoints _grp, _wpPos, round (_uavInstance distance2D _wpPos)];
					};
					_uavInstance doMove _wpPos;
					_lastWaypointOrder = _wpPos;
					_lastWaypointOrderTime = diag_tickTime;
				};
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

// Fallback trigger radius around the target's centre mass. Vehicles are normally
// set off on contact instead (see the trigger in _guide): a radius big enough for a
// tank's hull left the charge ~2 m short of it - crew killed, hull 20% damaged.
private _blastRange = 3;

// Puts the payload at _posASL; the handler sets it off on the next frame.
// Runs inside the handler, so nothing in here may sleep.
private _arm = {
    params ["_s", "_posASL", "_impacted"];
    private _charges = (_s get "ammo") apply {
        private _c = createVehicle [_x, ASLToAGL _posASL, [], 0, "CAN_COLLIDE"];
        _c setPosASL _posASL;
        _c
    };
    // deleteVehicleCrew is unary. It used to be written as a binary call, which
    // threw on this path - a candidate for "the drones explode but nothing dies".
    if (!isNull (_s get "uav")) then { deleteVehicleCrew (_s get "uav"); };
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
        { _x setDamage 1; } forEach (_s get "charges");
        if (!isNull _uav) then { _uav setDamage 1; };
        _s set ["result", "detonated"];
        _s set ["phase", "done"];
        removeMissionEventHandler ["EachFrame", _thisEventHandler];
    };

    private _aimOffset = [0, 0, 1];   // centre mass, not the ground under the target
    private _last = _s get "lastPos";
    private _tPos = (getPosASL _target) vectorAdd _aimOffset;

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
    private _v = velocity _uav;
    private _speed = _s get "speed";
    private _blast = _s get "blast";
    _s set ["lastPos", _p];

    // --- trigger: in blast range, or will be by next frame, ...
    private _fire = [];
    if ((_p vectorDistance _tPos) <= _blast + ((vectorMagnitude _v) * _dt)) then { _fire = _p; };
    // ... or passed through it since last frame (low frame rate), ...
    if (_fire isEqualTo []) then {
        private _seg = _p vectorDiff _last;
        private _segLen2 = _seg vectorDotProduct _seg;
        if (_segLen2 > 0.01) then {
            private _u = ((((_tPos vectorDiff _last) vectorDotProduct _seg) / _segLen2) max 0) min 1;
            private _closest = _last vectorAdd (_seg vectorMultiply _u);
            if ((_closest vectorDistance _tPos) <= _blast) then { _fire = _closest; };
        };
    };
    // ... or about to hit something right next to the target (its hull, a wall):
    // then the charge goes off right on the surface it's about to hit. "About to" is
    // two frames' travel plus 1 m for the drone's own size: with less, at 50 m/s its
    // body still hit the hull between two checks (traced: skin 2.6 m away, then impact).
    if (_fire isEqualTo [] && { (_p vectorDistance _tPos) < 15 }) then {
        private _reach = ((vectorMagnitude _v) * _dt * 2) + 1;
        private _hits = lineIntersectsSurfaces [_p, _p vectorAdd ((vectorNormalized _v) vectorMultiply _reach), _uav, objNull, true, 1, "FIRE", "GEOM"];
        // The target's skin straight towards its centre can be nearer than along the path.
        if (_hits isEqualTo []) then {
            _hits = (lineIntersectsSurfaces [_p, _tPos, _uav, objNull, true, 1, "FIRE", "GEOM"]) select { ((_x select 0) vectorDistance _p) < _reach };
        };
        if (_hits isNotEqualTo []) then {
            (_hits select 0) params ["_hitPos", "_hitNormal"];
            _fire = _hitPos vectorAdd (_hitNormal vectorMultiply 0.3);
        };
    };
    if (_fire isNotEqualTo []) exitWith { [_s, _fire, false] call (_s get "arm"); };

    // --- steering: lead the target - aim where it will be when we get there
    private _tVel = velocity _target;
    private _aim = _tPos;
    for "_i" from 1 to 2 do {
        _aim = _tPos vectorAdd (_tVel vectorMultiply (((_aim vectorDistance _p) / _speed) min 6));
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

    private _vDes = [];
    if (_d2 < 30 && { !_popUp }) then {
        // Terminal: straight at it.
        _vDes = (vectorNormalized _toAim) vectorMultiply _speed;
    } else {
        // Glide path: down at ~1:3 to the dive's entry point (30 m out, _termH up),
        // never higher above the target than the search height (unless the dive needs
        // it), never lower than 5 m over the ground on the way.
        private _slope = 0.35;
        private _ceiling = (_s get "cruise") max _termH;
        private _hRel = (_termH + (((_d2 - 30) max 0) * _slope)) min _ceiling;
        private _onSlope = _d2 > 30 && { _hRel < _ceiling };
        private _zDes = ((_aim select 2) + _hRel) max (_ground + 5);
        private _vz = ((((_zDes - (_p select 2)) * 1.5) + ([0, -_slope * _speed] select _onSlope)) max -15) min 15;
        private _vh = sqrt (((_speed ^ 2) - (_vz ^ 2)) max 0);
        // Still lifting off: straight up until clear of the ground (dragging along it
        // counts as a hit - see the attitude note below), then ease into going flat out.
        _vh = _vh * (((((_p select 2) - _ground - 1.5) / 3) max 0) min 1);
        // Popping up over cover: slow down so the climb happens before the wall does.
        if (_popUp) then { _vh = _vh * 0.3; };
        _vDes = (((vectorNormalized _toAimH) vectorMultiply _vh) vectorAdd [0, 0, _vz]) vectorAdd ([_uav, _p] call (_s get "separate"));

        // Something in the way in the next ~1.5 s (trees, a building, a ridge): pull up.
        private _look = (((vectorMagnitude _v) * 1.5) max 15) min ((_d2 - 5) max 3);
        private _ahead = _p vectorAdd ((vectorNormalized _vDes) vectorMultiply _look);
        if ((lineIntersectsSurfaces [_p, _ahead, _uav, _target, true, 1, "GEOM", "NONE"]) isNotEqualTo []) then {
            _vDes = [(_vDes select 0) * 0.5, (_vDes select 1) * 0.5, (_vDes select 2) max 10];
        };
    };

    // Ease towards it rather than snapping: at most "accel" m/s per second of change.
    private _dv = _vDes vectorDiff _v;
    private _maxDv = (_s get "accel") * _dt;
    if ((vectorMagnitude _dv) > _maxDv) then { _dv = (vectorNormalized _dv) vectorMultiply _maxDv; };
    private _vNew = _v vectorAdd _dv;

    // Velocity only - the attitude is left to the AI pilot. Setting it every frame
    // (setVectorDirAndUp) cancels that frame's movement: in testing the drone read
    // back 40 m/s while actually crawling at ~1 m/s. Pointing the nose along a climb
    // also tipped the tail into the ground on takeoff, and the Crocus mod treats ANY
    // hit as impact - its "hit" handler fires the drone's own warhead and deletes it.
    _uav setVelocity _vNew;

    // Flight trace for tuning (FPV_AI_Drones_debug = true): the first frames, then twice a second.
    if (missionNamespace getVariable ["FPV_AI_Drones_debug", false]) then {
        private _n = (_s getOrDefault ["frames", 0]) + 1;
        _s set ["frames", _n];
        if (_n <= 5 || { (_p vectorDistance _tPos) < 20 } || { diag_tickTime > (_s getOrDefault ["traceAt", 0]) }) then {
            _s set ["traceAt", diag_tickTime + 0.5];
            diag_log format ["FPV_AI_Drones: trace %1 f%2 dt=%3 agl=%4 v=%5 (%6 m/s) vDes=%7 d3=%8 d2aim=%9 termH=%10 clear=%11 popUp=%12",
                _uav, _n, _dt toFixed 3, ((_p select 2) - _ground) toFixed 1, _v apply { _x toFixed 1 }, (vectorMagnitude _v) toFixed 1,
                _vDes apply { _x toFixed 1 }, (_p vectorDistance _tPos) toFixed 1, _d2 toFixed 1, _termH, _clear, _popUp];
        };
    };
};

private _state = createHashMapFromArray [
    ["uav", _uavInstance], ["target", _target], ["phase", "run"], ["abort", ""], ["result", ""],
    ["speed", _attackSpeed], ["accel", 60], ["cruise", _initialSearchHeight],
    ["blast", _blastRange], ["ammo", _customAmmo splitString ", "],
    ["lastPos", getPosASL _uavInstance], ["arm", _arm], ["separate", _separation],
    ["charges", []], ["blastPos", []], ["impacted", false]
];
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
while { (_state get "phase") == "run" && { (_state get "abort") == "" } } do {
    sleep 0.25;
    // Drone just died: the handler decides whether that was the hit. Don't race it.
    if ([_uavInstance] call _is_dead) then { continue; };
    private _d = _uavInstance distance _target;
    if (_d < _best - 3) then { _best = _d; _bestAt = diag_tickTime; };
    private _reason = switch (true) do {
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
        ["", " (drone impacted first)"] select (_state get "impacted"), clientOwner, (diag_tickTime - _acquiredAt) toFixed 1];
} else {
    diag_log format ["FPV_AI_Drones: drone %1 broke off its attack run: %2", _uavName, _state get "result"];
};

// At the end of the script, ensure cleanup
if (!isNull _uavInstance) then {
	_uavInstance setVariable ["initialized", false];
	_uavInstance setVariable ["FPV_AI_Drones_runner", objNull];
};
