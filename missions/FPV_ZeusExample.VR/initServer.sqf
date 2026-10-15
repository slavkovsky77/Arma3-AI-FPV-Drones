/*
    FPV AI Drones - Zeus example (server).

    A sandbox: every player is Zeus. Two drone stations are marked on the map,
    each with parked (empty) Crocus drones. Placing an FPV AI Drones module on a
    station picks up every drone within 100 m - and any drone placed there later.
*/

FPVX_fnc_giveZeus = {
    params ["_unit"];
    if (isNull _unit || { _unit getVariable ["FPVX_zeus", false] }) exitWith {};
    _unit setVariable ["FPVX_zeus", true];
    private _curator = (createGroup sideLogic) createUnit ["ModuleCurator_F", [0, 0, 0], [], 0, "NONE"];
    sleep 1;
    _unit assignCurator _curator;
    _curator addCuratorAddons activatedAddons;
    // Keep everything editable in Zeus, including what gets spawned later.
    while { !isNull _curator } do {
        _curator addCuratorEditableObjects [vehicles + allUnits, true];
        sleep 10;
    };
};
if (!isMultiplayer) then { [] spawn { waitUntil { !isNull player }; [player] call FPVX_fnc_giveZeus; }; };

FPVX_fnc_station = {
    params ["_name", "_text", "_pos", "_types", "_color"];
    private _m = createMarker [_name, _pos];
    _m setMarkerShape "ELLIPSE";
    _m setMarkerSize [100, 100];
    _m setMarkerBrush "Border";
    _m setMarkerColor _color;
    private _l = createMarker [_name + "_label", _pos];
    _l setMarkerType "mil_dot";
    _l setMarkerText _text;
    _l setMarkerColor _color;
    createVehicle ["Land_HelipadSquare_F", _pos, [], 0, "CAN_COLLIDE"];
    {
        private _d = createVehicle [_x, _pos vectorAdd [(_forEachIndex - 1) * 8, 6, 0], [], 0, "CAN_COLLIDE"];
        createVehicleCrew _d;   // live drones, like ones placed in Zeus - not empty shells
    } forEach _types;
};

// Two stations so the AT and AP modules don't pick up each other's drones.
["fpvx_at", "Drone station: place the ANTI-TANK module here", [1100, 1000, 0], ["B_Crocus_AT", "B_Crocus_AT", "B_Crocus_AT"], "ColorBlue"] call FPVX_fnc_station;
["fpvx_ap", "Drone station: place the ANTI-PERSONNEL module here", [1100, 1300, 0], ["B_Crocus_AP", "B_Crocus_AP"], "ColorGreen"] call FPVX_fnc_station;

// Enemies keep their weapons quiet (combat mode BLUE) so the sandbox is about the drones.
FPVX_fnc_passive = {
    params ["_grp"];
    _grp setBehaviour "CARELESS";
    _grp setCombatMode "BLUE";
    { _x disableAI "PATH"; } forEach units _grp;
};

// Close targets: inside the 200 m a drone can see, so they're hit straight away.
// Far targets: send a drone there with a Zeus waypoint.
{
    _x params ["_pos", "_dir"];
    private _tank = createVehicle ["O_MBT_02_cannon_F", _pos, [], 0, "NONE"];
    _tank setDir _dir;
    createVehicleCrew _tank;
    [group effectiveCommander _tank] call FPVX_fnc_passive;
} forEach [[[1280, 1000, 0], 270], [[1650, 940, 0], 270], [[1700, 1080, 0], 250]];

{
    private _grp = createGroup [east, true];
    for "_i" from 0 to 4 do { _grp createUnit ["O_Soldier_F", _x vectorAdd [_i * 4, 0, 0], [], 0, "CAN_COLLIDE"]; };
    [_grp] call FPVX_fnc_passive;
} forEach [[1270, 1300, 0], [1650, 1350, 0]];

private _far = createMarker ["fpvx_far", [1680, 1150, 0]];
_far setMarkerType "mil_warning";
_far setMarkerText "Out of drone range - send drones with a Zeus waypoint";
_far setMarkerColor "ColorOPFOR";
