params ["_logic", "_units", "_activated"];

if !(_activated) exitWith {};

private _unitKinds = (_logic getVariable ["UnitKinds", "LandVehicle,Car,Tank"]) splitString ",";
private _targetSource = _logic getVariable ["TargetSource", "vehicles"];
private _attackDistance = _logic getVariable ["AttackDistance", 7];
private _attackDistance2D = _logic getVariable ["AttackDistance2D", 3];
private _attackHeight = _logic getVariable ["AttackHeight", 5];
private _allowObjectParent = _logic getVariable ["AllowObjectParent", true];
private _customAmmo = _logic getVariable ["CustomAmmo", "SatchelCharge_Remote_Ammo"];
private _targetDetectionRange = _logic getVariable ["TargetDetectionRange", 200];
private _heightAdjustmentDelay = _logic getVariable ["HeightAdjustmentDelay", 0.5];
private _stuckCheckInterval = _logic getVariable ["StuckCheckInterval", 10];
private _stuckThreshold = _logic getVariable ["StuckThreshold", 0.1];
private _moveAdjustmentDelay = _logic getVariable ["MoveAdjustmentDelay", 5];
private _initialSearchHeight = _logic getVariable ["InitialSearchHeight", 50];

systemChat format [
    "FPV Drone Module: UnitKinds: %1, TargetSource: %2, AttackDistance: %3, AttackDistance2D: %4, AttackHeight: %5, AllowObjectParent: %6, CustomAmmo: %7, TargetDetectionRange: %8", 
    _unitKinds, _targetSource, _attackDistance, _attackDistance2D, _attackHeight, _allowObjectParent, _customAmmo, _targetDetectionRange
];

// Get the drone type from the first synchronized unit
private _droneType = "";
{
    if (unitIsUAV _x) then {
        _droneType = typeOf _x;
        break;
    };
} forEach _units;

if (_droneType == "") exitWith {
    systemChat "No UAV synchronized with module!";
};

[
    _droneType,
    _unitKinds,
    _targetSource,
    _attackDistance,
    _attackDistance2D,
    _attackHeight,
    _allowObjectParent,
    _customAmmo,
    _targetDetectionRange,
    _heightAdjustmentDelay,
    _stuckCheckInterval,
    _stuckThreshold,
    _moveAdjustmentDelay,
    _initialSearchHeight
] spawn {
    params [
        "_droneType",
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
        "_initialSearchHeight"
    ];
    
    while {true} do {
        sleep 2;
        private _drones = allUnitsUAV select {typeOf _x == _droneType};
        {
            private _uavInstance = _x;
            [
                _uavInstance,
                _unitKinds,
                _targetSource,
                _attackDistance,
                _attackDistance2D,
                _attackHeight,
                _allowObjectParent,
                _customAmmo,
                _targetDetectionRange,
                _heightAdjustmentDelay,
                _stuckCheckInterval,
                _stuckThreshold,
                _moveAdjustmentDelay,
                _initialSearchHeight
            ] spawn FPV_AI_Drones_fnc_fpvLogic;
        } forEach _drones;
    };
};

