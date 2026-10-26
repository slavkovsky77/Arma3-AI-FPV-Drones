/*
    FPV AI Drones - editor example (server).

    Everything that matters is placed in the editor (mission.sqm):
      - "FPV AI Drones - Anti-Tank" module, synced to two EMPTY Crocus AT drones
      - "FPV AI Drones - Anti-Personnel" module, synced to an empty Crocus AP
      - to the south, an Anti-Tank module with "UAV Operator Required" ticked, synced to
        an empty AR-2 Darter and to a UAV operator soldier
    That is the whole setup - no scripting needed. This file only sends enemies
    at the drones and gives the player a Zeus camera to watch with.
*/

FPVX_fnc_giveZeus = {
    params ["_unit"];
    if (isNull _unit || { _unit getVariable ["FPVX_zeus", false] }) exitWith {};
    _unit setVariable ["FPVX_zeus", true];
    private _curator = (createGroup sideLogic) createUnit ["ModuleCurator_F", [0, 0, 0], [], 0, "NONE"];
    sleep 1;
    _unit assignCurator _curator;
    _curator addCuratorAddons activatedAddons;
    // Keep everything editable in Zeus, including what this script spawns later.
    while { !isNull _curator } do {
        _curator addCuratorEditableObjects [vehicles + allUnits, true];
        sleep 10;
    };
};
if (!isMultiplayer) then { [] spawn { waitUntil { !isNull player }; [player] call FPVX_fnc_giveZeus; }; };

// Enemies keep their weapons quiet (combat mode BLUE) so the demo is about the drones.
FPVX_fnc_passive = {
    params ["_grp"];
    _grp setBehaviour "CARELESS";
    _grp setCombatMode "BLUE";
    _grp setSpeedMode "LIMITED";
};

[] spawn {
    sleep 20;   // time to read the briefing

    // Armour from the east toward the Anti-Tank drones (they spot targets within 200m).
    {
        private _tank = createVehicle ["O_MBT_02_cannon_F", _x, [], 0, "NONE"];
        _tank setDir 270;
        createVehicleCrew _tank;
        private _grp = group effectiveCommander _tank;
        [_grp] call FPVX_fnc_passive;
        _grp addWaypoint [[1260, _x select 1, 0], 0];
    } forEach [[1700, 980, 0], [1760, 1040, 0], [1700, 600, 0]];

    // Infantry toward the Anti-Personnel drone.
    private _inf = createGroup [east, true];
    for "_i" from 0 to 5 do {
        _inf createUnit ["O_Soldier_F", [1700 + _i * 4, 1110, 0], [], 0, "FORM"];
    };
    [_inf] call FPVX_fnc_passive;
    _inf addWaypoint [[1260, 1100, 0], 0];

    "Enemy armour and infantry are moving in from the east." remoteExec ["systemChat", 0];
};

// UAV Operator Required: once the AR-2 to the south starts its attack run, its operator
// is taken out (scripted here, for the demo) - and the drone comes down.
[] spawn {
    private _op = missionNamespace getVariable ["fpvx_operator", objNull];
    private _drone = missionNamespace getVariable ["fpvx_opDrone", objNull];
    if (isNull _op || { isNull _drone }) exitWith {};
    waitUntil { sleep 0.5; !alive _drone || { ((getPosATL _drone) select 2) > 15 && { (speed _drone) > 60 } } };
    sleep 2;
    if (!alive _op || { !alive _drone }) exitWith {};
    _op setDamage 1;
    "The AR-2's UAV operator has been killed - the drone loses its pilot and comes down." remoteExec ["systemChat", 0];
};
