params ["_uavInstance", "_unitKinds", "_targetSource", "_maxDistance", "_maxDistance2d", "_finalHeight", "_allowObjectParent", "_customAmmo", "_minTargetDistance"];


isUnitOfKind = {
    params ["_unit", "_unitKinds"];
    private _result = false;
    {      
        private _is_kind_of = _unit isKindOf _x;
        if (_unit isKindOf _x) then { 
            _result = true;
            //systemChat format ["%1 isKindOf (%2) and breaking", _unit, _x, _is_kind_of];
            break;
        };
    } forEach _unitKinds;
    _result
};

// Function to find the nearest enemy of a specific type
findNearestEnemyOfType = {
    params ["_uavInstance", "_unitKinds", "_targetSource", "_allowObjectParent", "_minTargetDistance"];
    //systemChat format ["findNearestEnemyOfType: %1", _uavInstance];

    private _enemy_side = switch (side _uavInstance) do {
        case east: { west };
        case west: { east };
        default { civilian }; 
    };
    private _targets = switch (_targetSource) do {
        case "allUnits": { allUnits };
        case "vehicles": { vehicles };
    };

    private _enemies = _targets select {
        side _x == _enemy_side && { [_x, _unitKinds] call isUnitOfKind }
    };
    //systemChat format ["Enemies: %1", count _enemies];
    private _nearestEnemy = objNull;
    private _minDistance = _minTargetDistance;
    private _uniqueTypes = [];

    {
        private _hasObjectParent = !(isNull objectParent _x);
        private _isValidEnemy = _allowObjectParent || !_hasObjectParent;
        private _distance = _uavInstance distance _x;
        //systemChat format ["_distance(: %1 to %2) = %3", _unit, _x, _distance];
        if (_isValidEnemy && (_distance < _minDistance)) then {
            _minDistance = _distance;
            _nearestEnemy = _x;
        };

        
    } forEach _enemies;
    
    /*
    if (!isNull _nearestEnemy) then {
        systemChat format ["Nearest Enemy: %1(%3) for drone: %2, parent %4", _nearestEnemy, _uavInstance, typeOf _nearestEnemy, objectParent _nearestEnemy];
    };*/

    _nearestEnemy
};


is_dead = {
    params ["_object"];
    (isNull _object) || !(alive _object)
};



private _initialized = _uavInstance getVariable ["initialized", false];
private _maxFlyHeight = 30;

if (_initialized) exitWith {}; 

_uavInstance setBehaviour "CARELESS";
_uavInstance setSkill 1;
_uavInstance enableAI "ALL";
_uavInstance setSpeedMode "FULL";
_uavInstance setVariable ["initialized", true];
_uavInstance flyInHeight _maxFlyHeight;
_uavInstance forceSpeed 150;
_uavInstance setVariable ["jac_bonusStealth", 1.0];
systemChat format ["Initialized drone: %1", _uavInstance];

//"LandVehicle", "Car", "Tank"
private _nearestEnemy = objNull;
while {isNull _nearestEnemy && (!isNull _uavInstance)} do {
	if ([_uavInstance] call is_dead) then {
		_uavCanHitTarget = false;
		break;
	};
	_nearestEnemy = [_uavInstance, _unitKinds, _targetSource, _allowObjectParent, _minTargetDistance] call findNearestEnemyOfType;
	sleep (1);
};

if (isNull _nearestEnemy) then {
	systemChat format ['Drone %1 has no target!', _uavInstance];
	continue;
};

systemChat format ["Target aquired for drone: %1 -> %2 (%3)", _uavInstance, _nearestEnemy, typeOf _nearestEnemy];

private _target = _nearestEnemy;
private _cutDistance = 0;
private _currentDistance2d = _uavInstance distance2D _target;
private _currentDistance = (getPosASL _uavInstance) vectorDistance (getPosASL _target);

private _initialDistance2d = _currentDistance2d;
//private _initialHeight = ((getPosATL _uavInstance) select 2);

private _lastSetHeight = _maxFlyHeight;
private _lastSetHeightTime = diag_tickTime;
private _uavCanHitTarget = true;
private _predictedDistance = _currentDistance;

private _lastMoveTime = diag_tickTime;
private _lastLookForNewEnemyTime = diag_tickTime;
private _sleepInterval = 0.05; 
private _ascendTimeout = 10;

//while {(_currentDistance2d > _cutDistance) && (_currentDistance2d > 2) && (_currentDistance > 2)} do {
while {(_predictedDistance > _maxDistance) || (_currentDistance2d > _maxDistance2d)} do {
	sleep _sleepInterval;

	// is_dead(_uavInstance)
	if ([_uavInstance] call is_dead) then {
		systemChat format ["Drone is dead!"];
		_uavCanHitTarget = false;
		break;
	};

	if ([_target] call is_dead || (_currentDistance > 200)) then {
		systemChat format ["Drone %1 lost the target!", _uavInstance];
		_uavCanHitTarget = false;
		break;
	};

	private _isConnected = isUAVConnected _uavInstance;
	if (_isConnected) then {
		systemChat format ["Drone %1 is connected to UAV", _uavInstance];
		break;
	};

	
	private _currentHeight = ((getPosATL _uavInstance) select 2);
	private _distanceRatio = _currentDistance2d / _initialDistance2d min 1.0;
	private _desiredHeight = _finalHeight + (_maxFlyHeight - _finalHeight) * _distanceRatio;
	private _currentTime = diag_tickTime;
	
	//if ((_currentHeight < _desiredHeight && (_currentTime > _lastSetHeightTime + _ascendTimeout)) || (_currentHeight > _desiredHeight)) then {
	
	//_currentHeight
	private _setHeightFrequency = 1;
	if ((_currentHeight + 1 >= _finalHeight) && (_currentHeight > _desiredHeight + 1) && (_currentTime > _lastSetHeightTime + _setHeightFrequency)) then {
		private _isAscend = _desiredHeight > _lastSetHeight;
		private _ascendPossible = true;
		if (_isAscend && (_currentTime <= _lastSetHeightTime + _ascendTimeout)) then {
			_ascendPossible = false;
		};
		if (_ascendPossible) then {
			_lastSetHeight = _desiredHeight;
			_lastSetHeightTime = _currentTime;
			_uavInstance flyInHeight _lastSetHeight;
			// systemChat format ["Drone %1 setting flyInHeight = %2, _currentHeight = %3", _uavInstance, _lastSetHeight, _currentHeight];
		};
	};
					
	// Predictive targeting: adjust path based on target's velocity
	private _targetPos = getPosASL _target;
	private _targetVel = velocity _target;
	private _uavPos = getPosASL _uavInstance;
	private _uavVel = velocity _uavInstance;
	

	// Enhanced prediction considering acceleration
	/*private _predictedTargetPos = _targetPos vectorAdd (_targetVel vectorMultiply _sleepInterval) vectorAdd (_targetAcc vectorMultiply (0.5 * _sleepInterval * _sleepInterval));
	private _predictedUavPos = _uavPos vectorAdd (_uavVel vectorMultiply _sleepInterval);
	_predictedDistance = _predictedUavPos vectorDistance _predictedTargetPos;
	*/

	// Simple prediction assuming constant velocity and linear motion
	private _predictedTargetPos = _targetPos vectorAdd (_targetVel vectorMultiply _sleepInterval);
	private _predictedUavPos = _uavPos vectorAdd (_uavVel vectorMultiply _sleepInterval);
	_predictedDistance = _predictedUavPos vectorDistance _predictedTargetPos;


	private _movePos = getPosATL _target;
	//private _moveTimeout = 5;
	if (_predictedDistance < _maxDistance * 2) then {
		private _uavPosATL = getPosATL _uavInstance;
		private _targetPosATL = getPosATL _target;
		private _moveVector = (_targetPosATL vectorDiff _uavPosATL);
		_moveVector = vectorNormalized _moveVector;
		_moveVector = _moveVector vectorMultiply (_predictedDistance + 1.5*_maxDistance2d);
		
		_movePos = _uavPosATL vectorAdd _moveVector;
		_movePos = [_movePos select 0, _movePos select 1, _finalHeight];
		// systemChat format ["Drone %1 distance to |move vector| = %2", _uavInstance, vectorMagnitude _moveVector];
		//_moveTimeout = 0.2;
	};


	//if (_currentTime > _lastMoveTime + _moveTimeout) then {
	_uavInstance DoMove _movePos;
	_uavInstance forceSpeed 150;
	_lastMoveTime = _currentTime;
	//};


	// occasionally look for new enemy
	private _lastLookForNewEnemyFreq = 4;                     
	if (_currentTime > _lastLookForNewEnemyTime + _lastLookForNewEnemyFreq) then {
		private _newNearestEnemy = [_uavInstance, _unitKinds, _targetSource, _allowObjectParent, _minTargetDistance] call findNearestEnemyOfType;
		if (!(isNull _newNearestEnemy) && !(isNull _target) && (_newNearestEnemy != _target)) then {
			systemChat format ["New target aquired for drone: %1 -> %2 (%3)", _uavInstance, _nearestEnemy, typeOf _nearestEnemy];
			_target = _newNearestEnemy;
			continue;
		};
		_lastLookForNewEnemyTime = _currentTime;
	};


	_currentDistance2d = _uavInstance distance2D _target;
	_currentDistance = (getPosASL _uavInstance) vectorDistance (getPosASL _target);
	/*
	if (_currentDistance < 15 ) then {
			systemChat format ["Drone %1 distance to target = %2, distance2d = %3. _predictedDistance = %4", _uavInstance, _currentDistance, _currentDistance2d, _predictedDistance];
	};*/
};

//private _uavPos = getPos _uavInstance;
//private _targetDir = _targetPos vectorDiff _uavPos;
// https://community.bistudio.com/wiki/isRemoteControlling check this   
if (_uavCanHitTarget) then {
	// https://community.bistudio.com/wiki/UAVControl
	_uavInstance DoMove (position _target);
	sleep 0.5;

	private _explosives = [];
	for "_i" from 1 to 3 do {
		private _explosive = _customAmmo createVehicle (position _uavInstance);
		_explosive attachTo [_uavInstance, [0, 0, 0]];
		_explosives pushBack _explosive;
	};

	_uavInstance deleteVehicleCrew driver _uavInstance;
	sleep 3;
	_uavInstance setDamage 1;

};

if (([_uavInstance] call is_dead) == false) then {
	_uavInstance setVariable ["initialized", false];
};
