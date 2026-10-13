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
if (!isServer) exitWith {
    // A module placed in Zeus is created on the curator's machine and its init
    // runs there. Hand it to the server rather than quietly doing nothing.
    // Eden-placed modules are server-local, so clients never forward those.
    if (local _logic) then {
        [_logic, _units, _activated] remoteExec ["FPV_AI_Drones_fnc_initModule", 2];
    };
};

// With isGlobal = 1 the server can see both its own call and a forwarded one
// for the same module; only the first one counts.
if (_logic getVariable ["FPV_AI_Drones_started", false]) exitWith {};
_logic setVariable ["FPV_AI_Drones_started", true];

// Resolves one setting: the value set on the module (Eden attribute or script),
// else THIS module class's own defaultValue from config, else a last-resort
// fallback. Without the config step an untouched module - and every module
// placed in Zeus, which has no attribute dialog - fell back to one generic set,
// so the Anti-Personnel module hunted vehicles instead of infantry.
// The resolved value is written back so it can be inspected on the module.
private _attributesCfg = configOf _logic >> "Attributes";
private _setting = {
    params ["_name", "_fallback"];
    private _value = _logic getVariable _name;
    if (isNil "_value") then {
        private _default = _attributesCfg >> _name >> "defaultValue";
        _value = if (isText _default) then { call compile getText _default } else { _fallback };
        _logic setVariable [_name, _value];
    };
    _value
};

private _unitKinds = (["UnitKinds", "LandVehicle,Car,Tank"] call _setting) splitString ",";
private _targetSource = ["TargetSource", "vehicles"] call _setting;
private _attackDistance = ["AttackDistance", 10] call _setting;
private _attackDistance2D = ["AttackDistance2D", 3] call _setting;
private _attackHeight = ["AttackHeight", 5] call _setting;
private _allowObjectParent = ["AllowObjectParent", true] call _setting;
private _customAmmo = ["CustomAmmo", "SatchelCharge_Remote_Ammo"] call _setting;
private _targetDetectionRange = ["TargetDetectionRange", 200] call _setting;
private _heightAdjustmentDelay = ["HeightAdjustmentDelay", 0.5] call _setting;
private _stuckCheckInterval = ["StuckCheckInterval", 10] call _setting;
private _stuckThreshold = ["StuckThreshold", 0.1] call _setting;
private _moveAdjustmentDelay = ["MoveAdjustmentDelay", 5] call _setting;
private _initialSearchHeight = ["InitialSearchHeight", 50] call _setting;
private _enableChat = ["EnableChatMessages", false] call _setting;

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
