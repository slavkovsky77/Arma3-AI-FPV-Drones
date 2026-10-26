/*
    FPV AI Drones - "UAV Operator" module (server).

    Makes soldiers drone operators: the soldier it is dropped onto in Zeus, or the soldiers
    it is synced to in the editor. The module goes where he goes, and so does his area:
    every drone this mod flies, of his side, that comes within 100 m of him becomes his -
    also one placed next to him later, wherever he has walked to. Once his, it stays his,
    however far it flies. When all of a drone's operators are dead, the drone module that
    flies it takes it down (fn_initModule). A Workshop wish ("the operator killed, the
    drone crashes"); Zeus can't sync and shows no module settings, so this is how Zeus
    marks one particular soldier.

    Deleting the module (Zeus) ends his role: his drones no longer depend on him.
*/

params [["_logic", objNull, [objNull]], ["_units", [], [[]]], ["_activated", true, [true]]];
if (!isServer || { !_activated } || { isNull _logic }) exitWith {};

[_logic, _units] spawn {
    params ["_logic", "_units"];
    private _isSoldier = { params ["_u"]; !isNull _u && { _u isKindOf "CAManBase" } && { alive _u } && { !(unitIsUAV (vehicle _u)) } };

    // Zeus attaches the module to the soldier a moment after placing it.
    private _ops = [];
    private _until = time + 1.5;
    waitUntil {
        _ops = (_units + [attachedTo _logic]) select { [_x] call _isSoldier };
        _ops isNotEqualTo [] || { time > _until } || { isNull _logic }
    };
    // The module framework and the Zeus hook may both start it: only the first one runs.
    if (isNull _logic || { _logic getVariable ["FPV_AI_Drones_started", false] }) exitWith {};
    _logic setVariable ["FPV_AI_Drones_started", true];
    _ops = _ops arrayIntersect _ops;
    if (_ops isEqualTo []) exitWith {
        private _note = "FPV AI Drones: drop the UAV Operator module onto a soldier (in the editor: sync it to one).";
        diag_log text _note;
        _note remoteExec ["systemChat", 0];
    };
    // It goes where he goes. In Zeus it is attached to him already.
    if (isNull attachedTo _logic) then { _logic attachTo [_ops select 0, [0, 0, 0]]; };
    {
        _x setVariable ["FPV_AI_Drones_isOperator", true, true];
        private _note = format ["FPV AI Drones: %1 is now a UAV operator - drones of his side within 100 m become his, and come down if he is killed.", name _x];
        diag_log text _note;
        _note remoteExec ["systemChat", 0];
    } forEach _ops;

    private _radius = 100;
    while { !isNull _logic && { ({ alive _x } count _ops) > 0 } } do {
        {
            private _op = _x;
            if (alive _op) then {
                {
                    private _list = _x getVariable ["FPV_AI_Drones_operators", []];
                    if !(_op in _list) then {
                        _x setVariable ["FPV_AI_Drones_operators", _list + [_op]];
                        diag_log format ["FPV_AI_Drones: drone %1 is now flown for operator %2 (%3m from him)", _x, _op, round (_x distance _op)];
                    };
                } forEach ((_op nearEntities [["Air", "LandVehicle"], _radius]) select {
                    alive _x && { _x getVariable ["FPV_AI_Drones_managed", false] } && { (side group _x) isEqualTo (side group _op) }
                });
            };
        } forEach _ops;
        sleep 2;
    };

    // Module deleted (Zeus): his drones no longer depend on him.
    if (isNull _logic) then {
        {
            private _list = (_x getVariable ["FPV_AI_Drones_operators", []]) - _ops;
            _x setVariable ["FPV_AI_Drones_operators", _list];
        } forEach (vehicles select { ((_x getVariable ["FPV_AI_Drones_operators", []]) arrayIntersect _ops) isNotEqualTo [] });
        { _x setVariable ["FPV_AI_Drones_isOperator", nil, true]; } forEach (_ops select { alive _x });
        diag_log format ["FPV_AI_Drones: UAV Operator module deleted - %1 no longer operator(s)", _ops];
    };
};
