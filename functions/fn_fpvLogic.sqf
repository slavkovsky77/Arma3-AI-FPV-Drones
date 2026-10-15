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
    ["_targetSides", "ENEMIES"]   // ENEMIES | EAST | WEST | GUER | NOTOWN - see _isHostile
];

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
    private _minDistance = _detectionRange;

    {
        private _hasObjectParent = !(isNull objectParent _x);
        private _isValidEnemy = _objectParentAllowed || !_hasObjectParent;
        private _distance = _uav distance _x;
        if (_isValidEnemy && (_distance < _minDistance)) then {
            _minDistance = _distance;
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

private _initialized = _uavInstance getVariable ["initialized", false];

if (_initialized) exitWith {};

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
while {isNull _nearestEnemy && (!isNull _uavInstance)} do {
	if ([_uavInstance] call _is_dead) then {
		break;
	};
	_nearestEnemy = [_uavInstance, _unitKinds, _targetSource, _allowObjectParent, _targetDetectionRange, _targetSides] call _findNearestEnemyOfType;

	// No target yet: fly the group's waypoints (e.g. ones set in Zeus) while
	// searching, steering the drone explicitly. Nothing here runs once a target
	// is found - the attack takes over.
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
			if (_uavInstance distance2D _wpPos < 40) then {
				_wpIdx = _wpIdx + 1;
				_uavInstance setVariable ["FPV_AI_Drones_route", [_wpIdx, _wpSig]];
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

// Reachable whenever the drone dies or is deleted mid-search. This used to be
// "continue" at script scope, outside any loop, which throws a script error.
if (isNull _nearestEnemy) exitWith {
	if (!isNull _uavInstance) then {
		_uavInstance setVariable ["initialized", false];
	};
};

private _target = _nearestEnemy;
// Start of the attack run, for the time-to-kill in the detonation log line.
private _acquiredAt = diag_tickTime;
diag_log format ["FPV_AI_Drones: drone %1 acquired %2 (%3) at %4m", _uavInstance, _target, typeOf _target, round (_uavInstance distance _target)];
private _currentDistance2d = _uavInstance distance2D _target;
private _currentDistance = (getPosASL _uavInstance) vectorDistance (getPosASL _target);

private _initialDistance2d = _currentDistance2d;

private _lastSetHeight = _initialSearchHeight;
private _lastSetHeightTime = diag_tickTime;
// True if the attack loop is skipped entirely because the target is already close;
// every break-off path inside the loop sets it false first.
private _uavCanHitTarget = true;
private _predictedDistance = _currentDistance;

private _lastMoveTime = diag_tickTime;
private _lastLookForNewEnemyTime = diag_tickTime;
private _sleepInterval = 0.05;
private _ascendTimeout = 10;

// Terminal dive: how close (3D, to the target's centre of mass) before the charge
// goes off, how fast to dive, and how long to keep trying.
private _detonationDistance = 3;
private _diveSpeed = 20;
private _diveTimeout = 6;
private _aimOffset = [0, 0, 1];   // centre mass, not the ground under the target

private _isStuck = {
    params ["_uav", "_stuckTarget", "_lastDistance", "_threshold"];
    private _distanceNow = _uav distance2D _stuckTarget;   // horizontal: climbing is not "no progress"
    private _relativeChange = abs(_distanceNow - _lastDistance) / _lastDistance;
    _relativeChange < _threshold
};


private _handleStuckPos = {
    params ["_uav"];

    // Get current position and height
    private _currentPos = getPosATL _uav;
    private _currentHeight = _currentPos select 2;

    // Calculate new position while maintaining height
    private _randomOffset = [
        (random 100) - 50,
        (random 100) - 50,
        (random 100) - 50
    ];
    private _newPos = _currentPos vectorAdd _randomOffset;

    // Force immediate stop, then move to new position
    _uav forceSpeed 0;
    sleep 2;
    _uav flyInHeight [(_currentHeight + (_randomOffset select 2)) max 15, true];
    _uav move _newPos;
    _uav forceSpeed 150;
    sleep 5;
};


// ... in the main loop, add these variables before the while loop ...
private _lastPos = getPosASL _uavInstance;
private _lastPosTime = diag_tickTime;

// Add these variables before the main while loop
private _lastStuckCheckDistance = _currentDistance2d;
private _lastStuckCheckTime = diag_tickTime;

// Why the attack run ended early, if it did - logged below so a user's RPT says
// whether the drone gave up, got stuck, lost its target or was taken over.
private _exitReason = "";

// Modify the main while loop to include stuck detection
// Hand over to the terminal dive as soon as the drone is close in 3D OR lined up
// overhead. Requiring both used to leave it hovering a few metres off-centre above
// the target (seen in testing as ~6s at 10m height and 0km/h before it lined up);
// the dive steers itself, so it doesn't need a perfect setup.
while {(_predictedDistance > _attackDistance * 1.5) && { _currentDistance2d > _attackDistance2D }} do {
	sleep _sleepInterval;
	_uavCanHitTarget = false;

	if ([_uavInstance] call _isExternallyControlled) then {
		_exitReason = "taken over by a player (UAV terminal or Zeus)";
        break;
    };

	// is_dead(_uavInstance)
	if ([_uavInstance] call _is_dead) then {
		_exitReason = "drone destroyed";
		break;
	};

	// Current target check. This used to compare against a hardcoded 200, which
	// ignored the configured range: raising Target Detection Range above 200 made
	// the drone acquire a target and immediately drop it, over and over.
	if ([_target] call _is_dead || (_currentDistance > _targetDetectionRange)) then {
		_exitReason = format ["lost target (alive=%1, distance=%2m, range=%3m)", alive _target, round _currentDistance, _targetDetectionRange];
		break;
	};

	private _currentHeight = ((getPosATL _uavInstance) select 2);
	private _distanceRatio = _currentDistance2d / _initialDistance2d min 1.0;
	private _desiredHeight = _attackHeight + (_initialSearchHeight - _attackHeight) * _distanceRatio;
	private _currentTime = diag_tickTime;

	private _setHeightFrequency = 1;
	if ((_currentHeight + 1 >= _attackHeight) && (_currentHeight > _desiredHeight + 1) && (_currentTime > _lastSetHeightTime + _setHeightFrequency)) then {

		private _canChangeHeight = true;
		if ((_desiredHeight > _lastSetHeight) && (_currentTime <= _lastSetHeightTime + _ascendTimeout)) then {
			_canChangeHeight = false;
		};
		if (_canChangeHeight) then {
			_lastSetHeight = _desiredHeight;
			_lastSetHeightTime = _currentTime;
			_uavInstance flyInHeight [_lastSetHeight, true];
			private _sleepTime = ((_currentHeight / _desiredHeight) * _heightAdjustmentDelay) max 0.1;
			sleep _sleepTime;
		};
	};

	// Predictive targeting: adjust path based on target's velocity
	private _targetPos = getPosASL _target;
	private _targetVel = velocity _target;
	private _uavPos = getPosASL _uavInstance;
	private _uavVel = velocity _uavInstance;

	// Simple prediction assuming constant velocity and linear motion
	private _predictedTargetPos = _targetPos vectorAdd (_targetVel vectorMultiply _sleepInterval);
	private _predictedUavPos = _uavPos vectorAdd (_uavVel vectorMultiply _sleepInterval);
	_predictedDistance = _predictedUavPos vectorDistance _predictedTargetPos;


	private _movePos = getPosATL _target;
	if (_predictedDistance < _attackDistance * 2) then {
		private _uavPosATL = getPosATL _uavInstance;
		private _targetPosATL = getPosATL _target;
		private _moveVector = (_targetPosATL vectorDiff _uavPosATL);
		_moveVector = vectorNormalized _moveVector;

		// Aim past the target so the ram carries through, but cap the lead.
		// Scaling it at 1.5 * AttackDistance2D gave the AP module a 12m overshoot,
		// so the drone flew well past infantry, turned, and overshot again -
		// which on the ground looks like a drone harmlessly circling you.
		private _overshoot = (1.5 * _attackDistance2D) min 4;
		_moveVector = _moveVector vectorMultiply (_predictedDistance + _overshoot);

		_movePos = _uavPosATL vectorAdd _moveVector;
		_movePos = [_movePos select 0, _movePos select 1, _attackHeight];
	} else {
		// Hold the stuck clock until the drone is airborne and well into its climb.
		// Engine start, takeoff and climbing to search height take longer than the
		// check interval, and were being mistaken for being stuck - the drone got
		// shoved to a random spot and restarted its attack (seen in test runs as
		// "stuck - distance 150m -> 155m in 16s" right after spawning).
		if (isTouchingGround _uavInstance || { _currentHeight < (_initialSearchHeight * 0.5) }) then {
			_lastStuckCheckDistance = _currentDistance2d;
			_lastStuckCheckTime = _currentTime;
		};
		if (_currentTime - _lastStuckCheckTime > _stuckCheckInterval) then {
			if ([_uavInstance, _target, _lastStuckCheckDistance, _stuckThreshold] call _isStuck) then {
				_exitReason = format ["stuck - distance %1m -> %2m in %3s (threshold %4)",
					round _lastStuckCheckDistance, round _currentDistance2d, round (_currentTime - _lastStuckCheckTime), _stuckThreshold];
        		[_uavInstance] call _handleStuckPos;
				break;
			};
			_lastStuckCheckDistance = _currentDistance2d;
			_lastStuckCheckTime = _currentTime;
		};
	};


	_uavInstance DoMove _movePos;
	// Scale sleep based on how far we are from both min and max distances
	private _distanceRange = _targetDetectionRange - _attackDistance;
	private _distanceFromMax = (_predictedDistance - _attackDistance) max 0;
	private _distanceRatio = (_distanceFromMax / _distanceRange) min 1.0;
	private _moveSleepTime = ((_distanceRatio * _distanceRatio) * _moveAdjustmentDelay) max 0.01;

	sleep _moveSleepTime;

	_uavInstance forceSpeed 150;
	_lastMoveTime = _currentTime;


	// occasionally look for new enemy
	private _lastLookForNewEnemyFreq = 4;
	if (_currentTime > _lastLookForNewEnemyTime + _lastLookForNewEnemyFreq) then {
		private _newNearestEnemy = [_uavInstance, _unitKinds, _targetSource, _allowObjectParent, _targetDetectionRange, _targetSides] call _findNearestEnemyOfType;
		if (!(isNull _newNearestEnemy) && (_newNearestEnemy != _target)) then {
			_target = _newNearestEnemy;
		};
		_lastLookForNewEnemyTime = _currentTime;
	};


	_currentDistance2d = _uavInstance distance2D _target;
	_currentDistance = (getPosASL _uavInstance) vectorDistance (getPosASL _target);
	_uavCanHitTarget = true;
};

if (_exitReason != "") then {
	diag_log format ["FPV_AI_Drones: drone %1 broke off its attack run: %2", _uavInstance, _exitReason];
};

// final approach and explosion
if (_uavCanHitTarget) then {
	// Terminal guidance: steer straight at the target's centre of mass for the
	// last few metres instead of leaving it to the AI pilot. The pilot alone would
	// hover AttackHeight above the target (8m for AP - survivable), and forcing
	// flyInHeight 0 instead flew it into the ground short of the target.
	// Bigger targets get a bigger trigger radius: approaching a tank nose-first,
	// the drone hits the hull ~4m out from its centre - before a fixed 3m trigger -
	// and only the Crocus' own small warhead went off (seen in testing: 12% damage).
	private _blastRange = _detonationDistance max ((((boundingBoxReal _target) select 2) * 0.8) min 6);
	private _lastPos = getPosATL _uavInstance;
	private _diveDeadline = diag_tickTime + _diveTimeout;
	while {
		!([_uavInstance] call _is_dead)
		&& { !([_target] call _is_dead) }
		&& { ((getPosASL _uavInstance) vectorDistance ((getPosASL _target) vectorAdd _aimOffset)) > _blastRange }
		&& { diag_tickTime < _diveDeadline }
	} do {
		private _toTarget = ((getPosASL _target) vectorAdd _aimOffset) vectorDiff (getPosASL _uavInstance);
		_uavInstance setVelocity ((vectorNormalized _toTarget) vectorMultiply _diveSpeed);
		_lastPos = getPosATL _uavInstance;
		sleep 0.05;
	};

	// If it hit something on the way in, the Crocus' own warhead has gone off and
	// that mod deletes the drone. Hitting the target is exactly when the payload
	// should go off, so detonate it where the drone last was - unless it crashed
	// somewhere else entirely.
	private _droneGone = [_uavInstance] call _is_dead;
	if (_droneGone && { _lastPos distance _target > 10 }) exitWith {
		diag_log format ["FPV_AI_Drones: drone lost during terminal dive %1m from %2 - no detonation on machine %3",
			round (_lastPos distance _target), _target, clientOwner];
	};
	private _blastPos = if (_droneGone) then { _lastPos } else { getPosATL _uavInstance };

	// Split the ammo string and create multiple explosives
	private _ammoTypes = _customAmmo splitString ",";

	// One line per detonation per machine. More than one for the same drone
	// means the explosives are being duplicated across machines again.
	diag_log format ["FPV_AI_Drones: drone %1 detonating %2 on %3 at %4m%5 on machine %6, %7s after acquiring the target",
		_uavInstance, _ammoTypes, _target, round (_blastPos distance _target),
		["", " (drone impacted first)"] select _droneGone, clientOwner, round (diag_tickTime - _acquiredAt)];
	private _explosives = [];

	{
		private _explosive = _x createVehicle _blastPos;
		if (!_droneGone) then { _explosive attachTo [_uavInstance, [0, 0, 0]]; };
		_explosives pushBack _explosive;
	} forEach _ammoTypes;

	if (!_droneGone) then {
		// deleteVehicleCrew is unary. This was written as a binary call with the
		// drone on the left, which throws - on the detonation path, which is a good
		// candidate for "the drones explode but nothing dies".
		deleteVehicleCrew _uavInstance;
		sleep 0.5;
	};

	// Detach and detonate all explosives
	{
		detach _x;
		_x setDamage 1;
	} forEach _explosives;

	if (!isNull _uavInstance) then { _uavInstance setDamage 1; };
};

// At the end of the script, ensure cleanup
if (!isNull _uavInstance) then {
	_uavInstance setVariable ["initialized", false];
};
