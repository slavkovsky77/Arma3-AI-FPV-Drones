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
    "_enableChat"
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

// Function to find the nearest enemy of a specific type
private _findNearestEnemyOfType = {
    params ["_uav", "_kinds", "_source", "_objectParentAllowed", "_detectionRange"];

    // A missing default here left _targets undefined and threw on the select below.
    private _targets = switch (_source) do {
        case "allUnits": { allUnits };
        case "vehicles": { vehicles };
        default { allUnits };
    };

    private _enemies = _targets select {
        ([side _uav, side _x] call BIS_fnc_sideIsEnemy) && { [_x, _kinds] call _isUnitOfKind }
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
_uavInstance flyInHeight _initialSearchHeight;
_uavInstance forceSpeed 150;
_uavInstance setVariable ["jac_bonusStealth", 1.0];
// This runs on the server, so it has to be broadcast to actually reach players.
if (_enableChat) then {
    (format ["Initialized drone: %1", _uavInstance]) remoteExec ["systemChat", 0];
};

//"LandVehicle", "Car", "Tank"
private _nearestEnemy = objNull;
while {isNull _nearestEnemy && (!isNull _uavInstance)} do {
	if ([_uavInstance] call _is_dead) then {
		break;
	};
	_nearestEnemy = [_uavInstance, _unitKinds, _targetSource, _allowObjectParent, _targetDetectionRange] call _findNearestEnemyOfType;
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
private _currentDistance2d = _uavInstance distance2D _target;
private _currentDistance = (getPosASL _uavInstance) vectorDistance (getPosASL _target);

private _initialDistance2d = _currentDistance2d;

private _lastSetHeight = _initialSearchHeight;
private _lastSetHeightTime = diag_tickTime;
private _uavCanHitTarget = false;
private _predictedDistance = _currentDistance;

private _lastMoveTime = diag_tickTime;
private _lastLookForNewEnemyTime = diag_tickTime;
private _sleepInterval = 0.05;
private _ascendTimeout = 10;

// How close, in 3D, the drone must actually get before it is allowed to detonate.
private _detonationDistance = _attackDistance2D max 3;
private _diveTimeout = 8;

private _isStuck = {
    params ["_uav", "_stuckTarget", "_lastDistance", "_threshold"];
    private _distanceNow = _uav distance _stuckTarget;
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
    _uav flyInHeight _currentHeight + (_randomOffset select 2);
    _uav move _newPos;
    _uav forceSpeed 150;
    sleep 5;
};


// ... in the main loop, add these variables before the while loop ...
private _lastPos = getPosASL _uavInstance;
private _lastPosTime = diag_tickTime;

// Add these variables before the main while loop
private _lastStuckCheckDistance = _currentDistance;
private _lastStuckCheckTime = diag_tickTime;

// Modify the main while loop to include stuck detection
while {(_predictedDistance > _attackDistance) || (_currentDistance2d > _attackDistance2D)} do {
	sleep _sleepInterval;
	_uavCanHitTarget = false;

	if ([_uavInstance] call _isExternallyControlled) then {
        break;
    };

	// is_dead(_uavInstance)
	if ([_uavInstance] call _is_dead) then {
		break;
	};

	// Current target check. This used to compare against a hardcoded 200, which
	// ignored the configured range: raising Target Detection Range above 200 made
	// the drone acquire a target and immediately drop it, over and over.
	if ([_target] call _is_dead || (_currentDistance > _targetDetectionRange)) then {
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
			_uavInstance flyInHeight _lastSetHeight;
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
		if (_currentTime - _lastStuckCheckTime > _stuckCheckInterval) then {
			if ([_uavInstance, _target, _lastStuckCheckDistance, _stuckThreshold] call _isStuck) then {
        		[_uavInstance] call _handleStuckPos;
				break;
			};
			_lastStuckCheckDistance = _currentDistance;
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
		private _newNearestEnemy = [_uavInstance, _unitKinds, _targetSource, _allowObjectParent, _targetDetectionRange] call _findNearestEnemyOfType;
		if (!(isNull _newNearestEnemy) && (_newNearestEnemy != _target)) then {
			_target = _newNearestEnemy;
		};
		_lastLookForNewEnemyTime = _currentTime;
	};


	_currentDistance2d = _uavInstance distance2D _target;
	_currentDistance = (getPosASL _uavInstance) vectorDistance (getPosASL _target);
	_uavCanHitTarget = true;
};

// final approach and explosion
if (_uavCanHitTarget) then {
	// Dive onto the target before detonating. The loop above can be satisfied
	// while the drone is still AttackHeight metres above its target - for the AP
	// module that is 8m, and a DemoCharge detonated 8m over someone's head is
	// survivable. Close the vertical gap first.
	_uavInstance flyInHeight 0;
	private _diveDeadline = diag_tickTime + _diveTimeout;
	while {
		!([_uavInstance] call _is_dead)
		&& { !([_target] call _is_dead) }
		&& { ((getPosASL _uavInstance) vectorDistance (getPosASL _target)) > _detonationDistance }
		&& { diag_tickTime < _diveDeadline }
	} do {
		_uavInstance doMove (getPosATL _target);
		sleep 0.1;
	};

	// Split the ammo string and create multiple explosives
	private _ammoTypes = _customAmmo splitString ",";
	private _explosives = [];

	{
		private _explosive = _x createVehicle (position _uavInstance);
		_explosive attachTo [_uavInstance, [0, 0, 0]];
		_explosives pushBack _explosive;
	} forEach _ammoTypes;

	// deleteVehicleCrew is unary. This was written as a binary call with the
	// drone on the left, which throws - on the detonation path, which is a good
	// candidate for "the drones explode but nothing dies".
	deleteVehicleCrew _uavInstance;
	sleep 0.5;

	// Detach and detonate all explosives
	{
		detach _x;
		_x setDamage 1;
	} forEach _explosives;

	_uavInstance setDamage 1;
};

// At the end of the script, ensure cleanup
if (!isNull _uavInstance) then {
	_uavInstance setVariable ["initialized", false];
};
