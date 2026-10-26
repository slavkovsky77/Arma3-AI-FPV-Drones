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
// Fallback false: only a placed module (config default true) takes over by type;
// a plain logic handed to this function by a script gets exactly what it asks for.
private _takeOverAllOfType = ["TakeOverAllOfType", false] call _setting;
private _targetSides = ["TargetSides", "ENEMIES"] call _setting;   // who to attack - see fpvLogic _isHostile
private _attackSpeed = ["AttackSpeed", -1] call _setting;   // km/h; -1 = fpvLogic's default for the target kind
private _cruiseSpeed = ["CruiseSpeed", -1] call _setting;   // km/h on waypoints; -1 = fpvLogic's default
private _brakingTime = ["BrakingTime", -1] call _setting;   // s from full speed to a stop; -1 = fpvLogic's default
private _hitChance = ["HitChance", -1] call _setting;       // %; -1 = 100
private _secondPass = ["SecondPassChance", -1] call _setting;   // %; -1 = fpvLogic's default
private _deleteDrone = ["DeleteDrone", true] call _setting;
private _attackEmpty = ["AttackEmptyVehicles", true] call _setting;
private _operatorRequired = ["OperatorRequired", false] call _setting;

// The module's area: drones within this distance of where it was placed are
// picked up - at placement, and any placed there later (a Zeus "drone station").
private _pickupRadius = 100;
private _center = getPosATL _logic;   // fixed: a module attached to a drone shouldn't drag its area along

if (_enableChat) then {
    private _msg = format [
        "FPV Drone Module: UnitKinds: %1, TargetSource: %2, TargetSides: %3, AttackSpeed: %4 km/h, AllowObjectParent: %5, CustomAmmo: %6, TargetDetectionRange: %7, CruiseSpeed: %8 km/h, BrakingTime: %9 s, Accuracy: %10 percent, SecondPass: %11 percent, DeleteDrone: %12, AttackEmpty: %13, OperatorRequired: %14",
        _unitKinds, _targetSource, _targetSides, _attackSpeed, _allowObjectParent, _customAmmo, _targetDetectionRange, _cruiseSpeed, _brakingTime, _hitChance,
        _secondPass, _deleteDrone, _attackEmpty, _operatorRequired
    ];
    // Runs on the server, so it has to be broadcast to reach any player.
    _msg remoteExec ["systemChat", 0];
};

// A drone by config, crewed or not: a Crocus placed as an empty vehicle is not in
// allUnitsUAV, which is why "I synced it and nothing happens" was the most common
// bug report - crew is created for it below. Checking the UAV flag rather than
// "is an aircraft" matters: the latter let a module grab a MANNED helicopter.
private _isDroneCandidate = {
    params ["_obj"];
    !isNull _obj
    && { alive _obj }
    && { !(_obj isKindOf "Logic") }
    && { (unitIsUAV _obj) || { getNumber (configOf _obj >> "isUav") == 1 } }
};

// A drone placed in Zeus belongs to the Zeus player's machine, and the attack logic
// only drives drones the server owns (it skips the rest). Bring the drone and its
// AI crew over to the server. Found in hands-on MP testing: a picked-up drone
// ("B Alpha 1-3:1 REMOTE") that just sat there.
private _takeOwnership = {
    params ["_drone"];
    if (local _drone) exitWith {};
    private _from = owner _drone;
    private _grp = group effectiveCommander _drone;
    private _moved = if (!isNull _grp) then { _grp setGroupOwner clientOwner } else { _drone setOwner clientOwner };
    diag_log format ["FPV_AI_Drones: drone %1 belonged to machine %2 - moving it to the server (%3)", _drone, _from, _moved];
};

// Marks a drone as this module's. Some drone mods replace a drone with a new object
// that inherits its variables (the Ukraine FPV Drone mod does when its payload is set
// in Eden): the key tells the module the new one is its own, and the group gives it
// the route back - the new drone comes with a new crew and group, without waypoints.
FPV_AI_Drones_moduleCount = (missionNamespace getVariable ["FPV_AI_Drones_moduleCount", 0]) + 1;
private _key = FPV_AI_Drones_moduleCount;
private _tag = {
    params ["_drone", "_key"];
    _drone setVariable ["FPV_AI_Drones_managed", true, true];
    _drone setVariable ["FPV_AI_Drones_owner", _key];
    _drone setVariable ["FPV_AI_Drones_group", group _drone];
};

// 1. Eden editor: units synchronised to the module.
private _drones = _units select { [_x] call _isDroneCandidate };

// "UAV Operator Required" (a Workshop wish): soldiers synced to the module are its
// drones' operators. When the last of them is dead, the drones lose their pilot - see
// the loop below. Not a drone's own UAV crew, which is in a drone. (In Zeus, which can't
// sync, the "UAV Operator" module does the same - fn_operatorModule.)
private _operators = if (_operatorRequired) then {
    _units select { _x isKindOf "CAManBase" && { alive _x } && { !(unitIsUAV (vehicle _x)) } }
} else { [] };
if (_operatorRequired && { _operators isEqualTo [] }) then {
    private _note = "FPV AI Drones: 'UAV Operator Required' is on, but no soldier is synced to the module - its drones fly without one.";
    diag_log text _note;
    if (_enableChat) then { _note remoteExec ["systemChat", 0]; };
};

// 2. Zeus: dropped straight onto a drone. Zeus attaches rather than syncing, so
//    _units is empty here and the old code gave up at this point.
if (_drones isEqualTo []) then {
    private _attached = attachedTo _logic;
    if ([_attached] call _isDroneCandidate) then {
        _drones = [_attached];
    };
};

// 3. Zeus: dropped on open ground - adopt drones already in its area. Ones placed
//    there later are picked up by the loop below.
if (_drones isEqualTo []) then {
    _drones = (_center nearEntities [["Air", "LandVehicle"], _pickupRadius]) select {
        [_x] call _isDroneCandidate
    };
};

if (_drones isEqualTo []) then {
    // Not an error any more - the module waits for drones. Still always shown
    // (ignores _enableChat): a module that silently does nothing is what produced
    // most of the "it doesn't work" reports.
    private _note = format [
        "FPV AI Drones: no drone here yet - any drone placed within %1m of this module will be picked up.",
        _pickupRadius
    ];
    diag_log text _note;
    _note remoteExec ["systemChat", 0];
};

{
    // An empty vehicle has no UAV crew, so it never appears in allUnitsUAV and
    // never moves - it just sits where it was placed.
    if ((crew _x) isEqualTo []) then { createVehicleCrew _x; };

    [_x] call _takeOwnership;

    [_x, _key] call _tag;
} forEach _drones;

// The drone types this module controls. With "Control All Drones Of This Type" on
// (the default, and how the mod originally behaved) every other drone of these
// types is taken over too - including ones spawned later, e.g. in Zeus.
private _droneTypes = _drones apply { typeOf _x };
// The AT/AP modules also know their usual drone types (config fpvDefaultDroneTypes),
// so a module placed anywhere in Zeus takes over e.g. every Crocus AT - not only
// once it happens to have picked one up.
if (_takeOverAllOfType) then {
    _droneTypes append getArray (configOf _logic >> "fpvDefaultDroneTypes");
};
_droneTypes = _droneTypes arrayIntersect _droneTypes;   // unique

[
    _logic,
    _center,
    _pickupRadius,
    _isDroneCandidate,
    _takeOwnership,
    _droneTypes,
    _takeOverAllOfType,
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
    _enableChat,
    _targetSides,
    _attackSpeed,
    _cruiseSpeed,
    _brakingTime,
    _hitChance,
    _secondPass,
    _deleteDrone,
    _attackEmpty,
    _operators,
    _key,
    _tag
] spawn {
    params [
        "_logic",
        "_center",
        "_pickupRadius",
        "_isDroneCandidate",
        "_takeOwnership",
        "_droneTypes",
        "_takeOverAllOfType",
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
        "_enableChat",
        "_targetSides",
        "_attackSpeed",
        "_cruiseSpeed",
        "_brakingTime",
        "_hitChance",
        "_secondPass",
        "_deleteDrone",
        "_attackEmpty",
        "_operators",
        "_key",
        "_tag"
    ];

    while {true} do {
        sleep 2;

        // A drone its own mod replaced (see _tag): the new object carries our key.
        // Take it over and copy the route from the old group. Before this, the
        // replacement sat on the ground forever, its old "initialized" flag copied too.
        {
            if ((crew _x) isEqualTo []) then { createVehicleCrew _x; };
            private _oldGrp = _x getVariable ["FPV_AI_Drones_group", grpNull];
            if (!isNull _oldGrp && { _oldGrp != group _x } && { count waypoints _oldGrp > 1 }) then {
                (group _x) copyWaypoints _oldGrp;
            };
            diag_log format ["FPV_AI_Drones: module %1 taking over %2 (%3) - it replaced one of the module's drones (%4 waypoints)",
                typeOf _logic, _x, typeOf _x, count waypoints group _x];
            [_x] call _takeOwnership;
            [_x, _key] call _tag;
            _drones pushBack _x;
            _droneTypes pushBackUnique (typeOf _x);
        } forEach (vehicles select {
            alive _x && { (_x getVariable ["FPV_AI_Drones_owner", -1]) isEqualTo _key } && { !(_x in _drones) }
        });

        // The module's area: pick up any drone placed within it that no module
        // controls yet - so in Zeus you place the module once and then just put
        // drones next to it. Stops once the module itself is deleted.
        if (!isNull _logic) then {
            {
                if ((crew _x) isEqualTo []) then { createVehicleCrew _x; };
                diag_log format ["FPV_AI_Drones: module %1 picked up %2 (%3) - placed in its %4m area",
                    typeOf _logic, _x, typeOf _x, _pickupRadius];
                [_x] call _takeOwnership;
                [_x, _key] call _tag;
                _drones pushBack _x;
                _droneTypes pushBackUnique (typeOf _x);   // so "all of this type" covers it too
            } forEach ((_center nearEntities [["Air", "LandVehicle"], _pickupRadius]) select {
                ([_x] call _isDroneCandidate) && { !(_x getVariable ["FPV_AI_Drones_managed", false]) }
            });
        };

        if (_takeOverAllOfType && { !isNull _logic }) then {
            // Adopt crewed drones of our types that no module controls yet - e.g.
            // ones a Zeus spawned after this module was placed. Crewed only, as
            // the original type-based behaviour was: empty drones parked in a
            // base are left alone unless a module is synced to them.
            {
                diag_log format ["FPV_AI_Drones: module %1 taking over %2 (%3) - same type, not yet controlled",
                    typeOf _logic, _x, typeOf _x];
                [_x] call _takeOwnership;
                [_x, _key] call _tag;
                _drones pushBack _x;
            } forEach (allUnitsUAV select {
                alive _x
                && { (typeOf _x) in _droneTypes }
                && { !(_x getVariable ["FPV_AI_Drones_managed", false]) }
            });
        };

        private _active = _drones select { !isNull _x && { alive _x } };

        // The module keeps watching its area (and its drone types) for as long as
        // it exists; once it's deleted, stop when its last drone is gone.
        if (_active isEqualTo [] && { isNull _logic }) exitWith {};

        {
            // A drone that isn't the server's can't be flown from here. Zeus creates a
            // drone's crew a moment after the drone itself, so one taken over in between
            // went back to the Zeus player's machine with its crew and then sat there
            // forever (seen hands-on). Ask again - unless a player is flying it.
            if (!local _x && { !isUAVConnected _x } && { isNull (_x getVariable ["bis_fnc_moduleRemoteControl_owner", objNull]) }) then {
                [_x] call _takeOwnership;
            };
            // Current group, for a replacement's route (see _tag): Zeus creates the crew
            // a moment after the drone, and can regroup it.
            if (!isNull group _x) then { _x setVariable ["FPV_AI_Drones_group", group _x]; };
            // Its operators: this module's synced ones ("UAV Operator Required"), plus any
            // it came near of a "UAV Operator" module (fn_operatorModule). All of them dead:
            // the drone loses its pilot. Engine off and no fuel; fpvLogic leaves it alone.
            private _ops = _x getVariable ["FPV_AI_Drones_operators", []];
            if ((_operators - _ops) isNotEqualTo []) then {
                _ops = _ops + (_operators - _ops);
                _x setVariable ["FPV_AI_Drones_operators", _ops];
            };
            if (_ops isNotEqualTo [] && { ({ alive _x } count _ops) == 0 } && { !(_x getVariable ["FPV_AI_Drones_disabled", false]) }) then {
                _x setFuel 0;
                _x engineOn false;
                _x setVariable ["FPV_AI_Drones_disabled", true, true];
                _x setVariable ["FPV_AI_Drones_disabledWhy", "its operator was killed"];
                diag_log format ["FPV_AI_Drones: drone %1 lost its operator - engine off, it comes down", _x];
                if (_enableChat) then { (format ["FPV AI Drones: %1 lost its operator", _x]) remoteExec ["systemChat", 0]; };
            };
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
                _enableChat,
                _targetSides,
                _attackSpeed,
                _cruiseSpeed,
                _brakingTime,
                _hitChance,
                _secondPass,
                _deleteDrone,
                _attackEmpty
            ] spawn FPV_AI_Drones_fnc_fpvLogic;
        } forEach _active;
    };
};
