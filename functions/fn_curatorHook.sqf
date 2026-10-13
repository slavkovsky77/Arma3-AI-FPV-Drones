/*
    FPV AI Drones - Zeus hook (postInit, every machine with an interface, and the server).

    Starts FPV modules placed by a Zeus curator explicitly, instead of relying on
    the module framework to run a curator-placed module's function. In testing, a
    module created mid-mission never had its function run at all - so without this,
    a module dropped in Zeus could silently do nothing.

    Curators can be created at any time (mission start, scripted later, mods like
    ZEN), so new ones are picked up by a slow poll rather than only at startup.
*/

if (!hasInterface && { !isServer }) exitWith {};   // headless clients never run Zeus

[] spawn {
    while { true } do {
        {
            if !(_x getVariable ["FPV_AI_Drones_hooked", false]) then {
                _x setVariable ["FPV_AI_Drones_hooked", true];   // per machine, deliberately not broadcast
                _x addEventHandler ["CuratorObjectPlaced", { _this call FPV_AI_Drones_fnc_curatorPlaced }];
            };
        } forEach allCurators;
        sleep 5;
    };
};
