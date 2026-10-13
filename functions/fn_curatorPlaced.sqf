/*
    FPV AI Drones - handles one object placed by a Zeus curator.

    Runs on the curator's machine (CuratorObjectPlaced is local). If the object is
    one of our modules, starts it on the server, where all drone AI runs.
    initModule ignores a module it has already started, so it doesn't matter if
    the module framework also gets to it.
*/

params ["_curator", "_entity"];

if !(_entity isKindOf "FPV_AI_Drones_Module") exitWith {};   // the AT/AP modules inherit from this

[_entity] spawn {
    params ["_module"];
    // Give Zeus a moment to attach the module to the drone it was dropped on;
    // initModule falls back to nearby drones if it isn't attached.
    sleep 0.5;
    diag_log format ["FPV_AI_Drones: Zeus placed %1 (attached to %2) - starting it on the server",
        typeOf _module, attachedTo _module];
    [_module, synchronizedObjects _module, true] remoteExec ["FPV_AI_Drones_fnc_initModule", 2];
};
