params ["_logic", "_units", "_activated"];

if !(_activated) exitWith {};

private _unitKinds = (_logic getVariable ["UnitKinds", "LandVehicle,Car,Tank"]) splitString ",";
private _targetSource = _logic getVariable ["TargetSource", "vehicles"];
private _maxDistance = _logic getVariable ["MaxDistance", 7];
private _maxDistance2d = _logic getVariable ["MaxDistance2D", 3];
private _finalHeight = _logic getVariable ["FinalHeight", 5];
private _allowObjectParent = _logic getVariable ["AllowObjectParent", true];
private _customAmmo = _logic getVariable ["CustomAmmo", "SatchelCharge_Remote_Ammo"];
private _minTargetDistance = _logic getVariable ["MinTargetDistance", 200];
private _heightAdjustmentDelay = _logic getVariable ["HeightAdjustmentDelay", 0.5];
private _stuckCheckInterval = _logic getVariable ["StuckCheckInterval", 10];
private _stuckThreshold = _logic getVariable ["StuckThreshold", 0.1];

systemChat format [
    "FPV Drone Module: UnitKinds: %1, TargetSource: %2, MaxDistance: %3, MaxDistance2D: %4, FinalHeight: %5, AllowObjectParent: %6, CustomAmmo: %7, MinTargetDistance: %8", 
    _unitKinds, _targetSource, _maxDistance, _maxDistance2d, _finalHeight, _allowObjectParent, _customAmmo, _minTargetDistance
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

// Start the main monitoring loop for ALL drones of this type
[_droneType, _unitKinds, _targetSource, _maxDistance, _maxDistance2d, _finalHeight, _allowObjectParent, _customAmmo, _minTargetDistance, _heightAdjustmentDelay, _stuckCheckInterval, _stuckThreshold] spawn {
    params ["_droneType", "_unitKinds", "_targetSource", "_maxDistance", "_maxDistance2d", "_finalHeight", "_allowObjectParent", "_customAmmo", "_minTargetDistance", "_heightAdjustmentDelay", "_stuckCheckInterval", "_stuckThreshold"];
    
    while {true} do {
        sleep 2;
        private _drones = allUnitsUAV select {typeOf _x == _droneType};
        {
            private _uavInstance = _x;
            [_uavInstance, _unitKinds, _targetSource, _maxDistance, _maxDistance2d, _finalHeight, _allowObjectParent, _customAmmo, _minTargetDistance, _heightAdjustmentDelay, _stuckCheckInterval, _stuckThreshold] spawn FPV_AI_Drones_fnc_fpvLogic;
        } forEach _drones;
    };
};

