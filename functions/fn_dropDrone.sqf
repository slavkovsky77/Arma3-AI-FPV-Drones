/*
    FPV AI Drones - a drone whose operator was killed drops out of the sky.

    Fuel and engine off alone are not enough: the game's helicopter physics carry a drone on
    for 14 s and 160 m after its engine stops, still climbing at first (stage 14, 27 Oct) -
    towards its target. The Crocus and the AR-2 have no rotor hit point to break. So, until
    it is on the ground: no more climbing, its forward speed bleeds off in about a second,
    and gravity takes it down. From 30 m up that is about 2.5 s and 20 m on.

    Runs where the drone is local (setVelocity has a local effect): the server, which owns
    the drones this mod flies.
*/
params [["_drone", objNull, [objNull]]];
if (isNull _drone || { !local _drone }) exitWith {};
_drone setFuel 0;
_drone engineOn false;
if (_drone getVariable ["FPV_AI_Drones_dropping", false]) exitWith {};
_drone setVariable ["FPV_AI_Drones_dropping", true];

addMissionEventHandler ["EachFrame", {
    _thisArgs params ["_drone", "_until"];
    if (isNull _drone || { !alive _drone } || { !local _drone } || { time > _until }
        || { isTouchingGround _drone } || { ((getPosATL _drone) select 2) < 0.8 }) exitWith {
        removeMissionEventHandler ["EachFrame", _thisEventHandler];
    };
    private _dt = (diag_deltaTime * accTime) min 0.1;
    if (_dt <= 0) exitWith {};   // paused
    (velocity _drone) params ["_vx", "_vy", "_vz"];
    private _keep = exp (-1.5 * _dt);
    _drone setVelocity [_vx * _keep, _vy * _keep, ((_vz min 0) - (9.81 * _dt)) max -40];
}, [_drone, time + 20]];
