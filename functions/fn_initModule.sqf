/*
    FPV AI Drones - module init.

    Resolves which drones this module manages (Eden sync, Zeus attachment, or
    Zeus ground placement), prepares them, and starts the per-drone attack logic.

    Mission makers can drive a drone directly without a module:
        _drone setVariable ["FPV_AI_Drones_managed", true, true];
        [_drone, ["Man"], "allUnits", 30, 3, 5, false, "DemoCharge_Remote_Ammo",
         200, 0.25, 15, 0.1, 5, 50, false] spawn FPV_AI_Drones_fnc_fpvLogic;
*/

params ["_logic", "_units", "_activated"];

if !(_activated) exitWith {};

// The whole AI loop is server-side. Previously it ran on every machine (the
// module is isGlobal = 1), so every client issued movement orders at the same
// drone and every client ran createVehicle on the explosives - which has global
// effect, so a 10-player server produced 10 sets of charges per drone.
if (!isServer) exitWith {};

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
private _enableChat = _logic getVariable ["EnableChatMessages", false];

// How far from a Zeus-placed module to look for drones when it was dropped on
// open ground rather than onto a specific drone.
private _zeusSearchRadius = 100;

if (_enableChat) then {
    private _msg = format [
        "FPV Drone Module: UnitKinds: %1, TargetSource: %2, AttackDistance: %3, AttackDistance2D: %4, AttackHeight: %5, AllowObjectParent: %6, CustomAmmo: %7, TargetDetectionRange: %8",
        _unitKinds, _targetSource, _attackDistance, _attackDistance2D, _attackHeight, _allowObjectParent, _customAmmo, _targetDetectionRange
    ];
    // Runs on the server, so it has to be broadcast to reach any player.
    _msg remoteExec ["systemChat", 0];
};

// Deliberately accepts drones that have no crew yet: a Crocus placed as an empty
// vehicle in the editor is not in allUnitsUAV and fails unitIsUAV, which is why
// "I synced it and nothing happens" was the most common bug report. Crew is
// created below.
private _isDroneCandidate = {
    params ["_obj"];
    !isNull _obj
    && { alive _obj }
    && { !(_obj isKindOf "Logic") }
    && { (_obj isKindOf "Air") || { unitIsUAV _obj } }
};

// 1. Eden editor: units synchronised to the module.
private _drones = _units select { [_x] call _isDroneCandidate };

// 2. Zeus: dropped straight onto a drone. Zeus attaches rather than syncing, so
//    _units is empty here and the old code gave up at this point.
if (_drones isEqualTo []) then {
    private _attached = attachedTo _logic;
    if ([_attached] call _isDroneCandidate) then {
        _drones = [_attached];
    };
};

// 3. Zeus: dropped on open ground - adopt nearby drones.
if (_drones isEqualTo []) then {
    _drones = ((getPosATL _logic) nearEntities [["Air"], _zeusSearchRadius]) select {
        [_x] call _isDroneCandidate
    };
};

if (_drones isEqualTo []) exitWith {
    // Ignores _enableChat on purpose. A module that silently does nothing when
    // misconfigured is what produced most of the "it doesn't work" reports.
    private _warning = format [
        "FPV AI Drones: module found no drone. Synchronise it with a drone in the editor, or place it on (or within %1m of) one in Zeus.",
        _zeusSearchRadius
    ];
    diag_log text _warning;
    _warning remoteExec ["systemChat", 0];
};

{
    // An empty vehicle has no UAV crew, so it never appears in allUnitsUAV and
    // never moves - it just sits where it was placed.
    if ((crew _x) isEqualTo []) then { createVehicleCrew _x; };

    // Tag rather than match on typeOf. Selecting by type meant one module
    // commandeered every drone of that class on the map, including a player's own.
    _x setVariable ["FPV_AI_Drones_managed", true, true];
} forEach _drones;

[
    _drones,
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
    _initialSearchHeight,
    _enableChat
] spawn {
    params [
        "_drones",
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

    while {true} do {
        sleep 2;

        private _active = _drones select { !isNull _x && { alive _x } };

        // Every managed drone is gone - nothing left for this module to do.
        if (_active isEqualTo []) exitWith {};

        {
            // fpvLogic guards re-entry with the drone's "initialized" variable,
            // so re-spawning here every 2s picks up drones that finished or lost
            // a target without stacking threads on ones already running.
            [
                _x,
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
                _initialSearchHeight,
                _enableChat
            ] spawn FPV_AI_Drones_fnc_fpvLogic;
        } forEach _active;
    };
};
