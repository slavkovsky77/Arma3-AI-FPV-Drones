/*
    FPV AI Drones - v1.2 showcase, for the trailer. Singleplayer.

    Scripted scenes on Altis with a cinematic camera. Recorded by
    tests\record_showcase.py, which starts capturing at SHOWCASE|BEGIN and stops at
    SHOWCASE|END in the RPT; SHOWCASE|SCENE lines mark the cuts.
*/
if (!isServer) exitWith {};

SC_log = { diag_log text format ["SHOWCASE|%1|%2", _this, diag_tickTime toFixed 2]; };

// --- Look -----------------------------------------------------------------
setDate [2035, 6, 24, 7, 10];
0 setOvercast 0.15; 0 setRain 0; 0 setFog 0; forceWeatherChange;
setViewDistance 4000;
setObjectViewDistance [3000, 150];
enableEnvironment [false, true];   // no rabbits and snakes, keep the ambient sound
showChat false;                    // the Crocus mod chats "Deleteing !" on every impact
enableRadio false; enableSentences false; 0 fadeRadio 0;
showHUD false;
player allowDamage false;
player hideObjectGlobal true;
player enableSimulation false;

("SC_black" call BIS_fnc_rscLayer) cutText ["", "BLACK FADED", 0];

// --- Helpers ----------------------------------------------------------------
SC_passive = {
    params ["_grp"];
    _grp setBehaviour "CARELESS";
    _grp setCombatMode "BLUE";
    { _x disableAI "AUTOTARGET"; _x disableAI "TARGET"; } forEach units _grp;
};
SC_tank = {
    params ["_pos", ["_dir", 0], ["_type", "O_MBT_02_cannon_F"]];
    private _t = createVehicle [_type, _pos, [], 0, "NONE"];
    _t setDir _dir;
    createVehicleCrew _t;
    [group effectiveCommander _t] call SC_passive;
    { _x disableAI "MOVE"; } forEach crew _t;
    _t
};
SC_drone = {
    params ["_pos", ["_dir", 0], ["_type", "B_Crocus_AT"]];
    private _d = createVehicle [_type, _pos, [], 0, "CAN_COLLIDE"];
    _d setDir _dir;
    _d setVariable ["FPV_AI_Drones_managed", true, true];
    _d
};
SC_AT = [["UnitKinds", "LandVehicle,Car,Tank"], ["TargetSource", "vehicles"], ["InitialSearchHeight", 30],
    ["TargetDetectionRange", 300], ["AllowObjectParent", true], ["CustomAmmo", "SatchelCharge_Remote_Ammo"],
    ["EnableChatMessages", false], ["TakeOverAllOfType", false], ["AttackSpeed", 180]];
SC_AP = [["UnitKinds", "Man"], ["TargetSource", "allUnits"], ["InitialSearchHeight", 40],
    ["TargetDetectionRange", 300], ["AllowObjectParent", false], ["CustomAmmo", "DemoCharge_Remote_Ammo"],
    ["EnableChatMessages", false], ["TakeOverAllOfType", false], ["AttackSpeed", 144]];
// Starts the module on these drones - from here on they hunt.
SC_go = {
    params ["_pos", "_settings", "_drones"];
    private _l = (createGroup sideLogic) createUnit ["Logic", _pos, [], 0, "CAN_COLLIDE"];
    { _l setVariable [_x select 0, _x select 1, true]; } forEach _settings;
    [_l, _drones, true] call FPV_AI_Drones_fnc_initModule;
    _l
};
// 2D distance from _p to the segment _a-_b.
SC_segDist = {
    params ["_p", "_a", "_b"];
    private _ab = [(_b select 0) - (_a select 0), (_b select 1) - (_a select 1), 0];
    private _ap = [(_p select 0) - (_a select 0), (_p select 1) - (_a select 1), 0];
    private _l2 = _ab vectorDotProduct _ab;
    private _t = if (_l2 > 0) then { (((_ap vectorDotProduct _ab) / _l2) max 0) min 1 } else { 0 };
    _ap vectorDistance (_ab vectorMultiply _t)
};
// An open corridor: a flat spot near _near with a level line of _len m from it, and
// no trees, houses, walls or power lines within _width m of that line. [pos, dir].
// Takes the best of 80 tries if none is perfectly clear.
SC_spots = [];   // scenes stay 1.2 km apart: a survivor of one scene drew the next scene's drone
SC_open = {
    params ["_near", "_radius", "_len", ["_width", 40]];
    private _best = [];
    private _bestScore = 1e9;
    for "_i" from 1 to 150 do {
        private _p = [_near, 0, _radius, 25, 0, 0.05, 0, [], [[-1, -1, 0], [-1, -1, 0]]] call BIS_fnc_findSafePos;
        if ((_p select 0) >= 0 && { (SC_spots findIf { (_x distance2D _p) < 1200 }) < 0 }) then {
            _p = [_p select 0, _p select 1, 0];
            private _dir = random 360;
            private _end = _p getPos [_len, _dir];
            if (!surfaceIsWater _end && { abs ((getTerrainHeightASL _end) - (getTerrainHeightASL _p)) < 6 }) then {
                private _mid = _p getPos [_len / 2, _dir];
                private _objs = nearestTerrainObjects [_mid, ["TREE", "SMALL TREE", "BUILDING", "HOUSE", "CHURCH", "CHAPEL", "FENCE", "WALL", "POWER LINES", "TRANSMITTER", "ROCK", "ROCKS", "FOREST", "HIDE", "RUIN", "FUELSTATION", "HOSPITAL", "LIGHTHOUSE", "QUAY", "WATERTOWER"], (_len / 2) + _width, false, true];
                private _score = { ([getPosATL _x, _p, _end] call SC_segDist) < _width } count _objs;
                if (_score < _bestScore) then { _bestScore = _score; _best = [_p, _dir]; };
            };
        };
        if (_bestScore == 0) exitWith {};
    };
    format ["spot %1 (%2 obstacles in the corridor)", _best, _bestScore] call SC_log;
    if (_best isNotEqualTo []) then { SC_spots pushBack (_best select 0); };
    _best
};
// A camera spot around _subject (ASL) with a clear view of it: tries headings around
// _dir at _dist m and _h m up. Returns ASL.
SC_viewFrom = {
    params ["_subject", "_dir", "_dist", "_h", ["_ignore", []]];
    private _pick = [];
    {
        private _c = AGLToASL (((ASLToAGL _subject) getPos [_dist, _dir + _x]) vectorAdd [0, 0, 0]);
        _c set [2, (getTerrainHeightASL _c) + _h];
        private _hits = (lineIntersectsSurfaces [_c, _subject, objNull, objNull, true, 5, "VIEW", "GEOM"]) select { !((_x select 2) in _ignore) && { !((_x select 3) in _ignore) } };
        if (_hits isEqualTo []) exitWith { _pick = _c; };
    } forEach [0, 25, -25, 50, -50, 75, -75, 110, -110];
    if (_pick isEqualTo []) then {
        _pick = AGLToASL ((ASLToAGL _subject) getPos [_dist, _dir]);
        _pick set [2, (getTerrainHeightASL _pick) + _h + 6];
    };
    _pick
};
// Lower-third title.
SC_title = {
    params ["_big", ["_small", ""], ["_dur", 3.5]];
    private _txt = format ["<t font='PuristaBold' size='3' shadow='2' color='#ffffff'>%1</t>", _big];
    if (_small != "") then { _txt = _txt + format ["<br/><t font='PuristaMedium' size='1.6' shadow='2' color='#ffcc55'>%1</t>", _small]; };
    ("SC_title" call BIS_fnc_rscLayer) cutText [_txt, "PLAIN DOWN", 0.5, true, true];
    [_dur] spawn { params ["_d"]; uiSleep _d; ("SC_title" call BIS_fnc_rscLayer) cutFadeOut 0.7; };
};
// Slow motion once _drone is within _dist of _target, for _hold real seconds.
SC_slowmo = {
    params ["_drone", "_target", "_dist", "_factor", "_hold"];
    private _until = diag_tickTime + 40;
    waitUntil { uiSleep 0.02; !alive _drone || { _drone distance _target < _dist } || { diag_tickTime > _until } };
    if (diag_tickTime > _until) exitWith {};
    setAccTime _factor;
    uiSleep _hold;
    setAccTime 1;
};
// Waits (real time) until _cond is true or _max seconds pass.
SC_wait = {
    params ["_cond", "_max"];
    private _until = diag_tickTime + _max;
    waitUntil { uiSleep 0.05; (call _cond) || { diag_tickTime > _until } };
};

// --- Camera -----------------------------------------------------------------
// One camera, driven every frame from SC_shot:
//   ["static", posASL, lookAt (object or posASL), fov]
//   ["chase",  drone, target, back m, up m, fov]   - behind the drone; pulls back when it hits
//   ["track",  vehicle, modelSpaceOffset, fov]     - rides alongside a vehicle
//   ["orbit",  centerASL, radius, height, deg/s, fov]
showCinemaBorder false;   // before cameraEffect, or the letterbox bars stay
SC_cam = "camera" camCreate [0, 0, 0];
SC_cam cameraEffect ["internal", "back"];
showCinemaBorder false;   // and again after - take 2 still had the bars
SC_shot = [];
SC_cut = true;
SC_hold = [];
SC_camPos = [0, 0, 0];
SC_camLook = [0, 0, 1];
SC_orbitAng = 0;
SC_setShot = { SC_shot = _this; SC_cut = true; SC_hold = []; };
addMissionEventHandler ["EachFrame", {
    if (SC_shot isEqualTo []) exitWith {};
    private _dt = diag_deltaTime min 0.1;
    private _pos = SC_camPos;
    private _look = SC_camLook;
    private _fov = 0.75;
    switch (SC_shot select 0) do {
        case "static": {
            SC_shot params ["", "_p", "_at", ["_f", 0.75]];
            _pos = _p; _fov = _f;
            _look = if (_at isEqualType objNull) then {
                if (isNull _at) then { SC_camLook } else { (getPosASLVisual _at) vectorAdd [0, 0, 1] }
            } else { _at };
        };
        case "chase": {
            SC_shot params ["", "_d", "_t", ["_back", 9], ["_up", 2.5], ["_f", 0.8]];
            _fov = _f;
            private _tp = if (isNull _t) then { SC_camLook } else { (getPosASLVisual _t) vectorAdd [0, 0, 1] };
            if (alive _d) then {
                private _dp = getPosASLVisual _d;
                private _v = velocity _d;
                private _fwd = if ((vectorMagnitude _v) > 5) then { vectorNormalized _v } else { vectorNormalized (_tp vectorDiff _dp) };
                private _fwdH = vectorNormalized [_fwd select 0, _fwd select 1, 0];
                _pos = (_dp vectorDiff (_fwdH vectorMultiply _back)) vectorAdd [0, 0, _up];
                _look = _dp vectorAdd (_fwd vectorMultiply 6);
            } else {
                // Hit: glide back out of the blast so the fireball is in frame.
                if (SC_hold isEqualTo []) then {
                    private _away = SC_camPos vectorDiff _tp;
                    _away set [2, 0];
                    SC_hold = (SC_camPos vectorAdd ((vectorNormalized _away) vectorMultiply 30)) vectorAdd [0, 0, 9];
                };
                _pos = SC_hold;
                _look = _tp vectorAdd [0, 0, 2];
            };
        };
        case "track": {
            SC_shot params ["", "_veh", "_off", ["_f", 0.7]];
            _fov = _f;
            if (!isNull _veh) then {
                _pos = AGLToASL (_veh modelToWorldVisual _off);
                _look = (getPosASLVisual _veh) vectorAdd [0, 0, 1.2];
            };
        };
        case "orbit": {
            SC_shot params ["", "_c", "_r", "_h", "_degps", ["_f", 0.7]];
            SC_orbitAng = SC_orbitAng + _degps * _dt;
            _pos = _c vectorAdd [_r * sin SC_orbitAng, _r * cos SC_orbitAng, _h];
            _look = _c; _fov = _f;
        };
    };
    // Never into the ground.
    _pos set [2, (_pos select 2) max ((getTerrainHeightASL _pos) + 1)];
    if (!SC_cut) then {
        private _k = 1 - exp (-9 * _dt);
        _pos = SC_camPos vectorAdd ((_pos vectorDiff SC_camPos) vectorMultiply _k);
        _look = SC_camLook vectorAdd ((_look vectorDiff SC_camLook) vectorMultiply _k);
    };
    SC_cut = false;
    SC_camPos = _pos;
    SC_camLook = _look;
    SC_cam camSetPos (ASLToAGL _pos);
    SC_cam camSetTarget (ASLToAGL _look);
    SC_cam camSetFov _fov;
    SC_cam camCommit 0;
}];

// --- Locations (found under the black screen, before recording) -------------------
private _ils = getArray (configFile >> "CfgWorlds" >> worldName >> "ilsPosition");
SC_base = [_ils select 0, _ils select 1, 0];
(([SC_base, 1500, 260] call SC_open)) params ["_p1", "_dir1"];
(([SC_base, 1200, 600, 30] call SC_open)) params ["_p2", "_dir2"];
(([SC_base getPos [1800, 20], 1800, 260] call SC_open)) params ["_p3", "_dir3"];
(([SC_base getPos [2000, 300], 1800, 220] call SC_open)) params ["_p4", "_dir4"];
(([SC_base getPos [1500, 100], 1800, 300, 80] call SC_open)) params ["_p5", "_dir5"];

// 1. Takeoff to kill ------------------------------------------------------------
private _tank1 = [_p1 getPos [230, _dir1], _dir1 + 160] call SC_tank;
private _d1 = [_p1, _dir1] call SC_drone;
private _cam1 = AGLToASL ((_p1 getPos [4.5, _dir1 + 130]) vectorAdd [0, 0, 2]);
["static", _cam1, _d1, 0.45] call SC_setShot;
uiSleep 10;   // past the Steam overlay's start-up toast
"BEGIN" call SC_log;
uiSleep 2;    // the recorder starts on BEGIN
"SCENE|takeoff" call SC_log;
("SC_black" call BIS_fnc_rscLayer) cutText ["", "BLACK IN", 1.5];
["FPV AI DRONES", "v1.2 - kamikaze drones that hunt on their own", 4] call SC_title;
uiSleep 2.5;
[_p1 getPos [6, _dir1 + 90], SC_AT, [_d1]] call SC_go;
[{ ((getPosATL _d1) select 2) > 6 || { !alive _d1 } }, 10] call SC_wait;
["chase", _d1, _tank1, 9, 2.2, 0.8] call SC_setShot;
["180 KM/H", "takes off, finds the target, hits it", 3.5] spawn SC_title;
[_d1, _tank1, 30, 0.25, 2.2] spawn SC_slowmo;
[{ !alive _d1 }, 25] call SC_wait;
uiSleep 2.5;

// 2. Moving target ---------------------------------------------------------------
// Straight across open ground on a forced path, already at speed; the drone waits in
// range off to the car's left, and the camera rides on its right.
private _car = createVehicle ["O_MRAP_02_F", _p2, [], 0, "CAN_COLLIDE"];
_car setDir _dir2;
createVehicleCrew _car;
private _cg = group effectiveCommander _car;
[_cg] call SC_passive;
_cg setSpeedMode "FULL";
_car limitSpeed 75;
private _path = [];
for "_i" from 1 to 12 do { _path pushBack (_p2 getPos [_i * 50, _dir2]); };
_car setDriveOnPath _path;
_car setVelocityModelSpace [0, 19, 0];
private _d2 = [(_p2 getPos [230, _dir2]) getPos [150, _dir2 - 90], _dir2 + 90] call SC_drone;
["track", _car, [15, 5, 2.6], 0.75] call SC_setShot;
"SCENE|moving" call SC_log;
["CATCHES MOVING VEHICLES", "aims where the target will be", 4] call SC_title;
[_p2, SC_AT, [_d2]] call SC_go;
[_d2, _car, 30, 0.25, 2.4] spawn SC_slowmo;
[{ !alive _d2 }, 30] call SC_wait;
uiSleep 2.5;

// 3. Over cover -------------------------------------------------------------------
private _tankPos3 = _p3 getPos [225, _dir3];
private _wall = createVehicle ["Land_Cargo_HQ_V1_F", _p3 getPos [214, _dir3], [], 0, "CAN_COLLIDE"];
_wall setDir _dir3;
private _tank3 = [_tankPos3, _dir3 + 180] call SC_tank;
private _d3 = [_p3, _dir3] call SC_drone;
private _mid3 = AGLToASL ((_p3 getPos [219, _dir3]) vectorAdd [0, 0, 5]);
private _cam3 = [_mid3, _dir3 + 90, 38, 5, [_wall, _tank3]] call SC_viewFrom;
["static", _cam3, _mid3, 0.6] call SC_setShot;
"SCENE|cover" call SC_log;
["DIVES OVER COVER", "tank parked behind a building", 4] call SC_title;
uiSleep 1;
[_p3 getPos [6, _dir3 + 90], SC_AT, [_d3]] call SC_go;
[_d3, _tank3, 45, 0.25, 2.8] spawn SC_slowmo;
[{ !alive _d3 }, 25] call SC_wait;
uiSleep 2.5;

// 4. Infantry ---------------------------------------------------------------------
// The squad walks across; the camera is behind it, so the drone dives at the lens.
private _squadPos = _p4 getPos [180, _dir4];
private _sg = createGroup [east, true];
for "_i" from 0 to 3 do {
    private _u = _sg createUnit ["O_Soldier_F", _squadPos getPos [_i * 3, _dir4 + 90], [], 0, "CAN_COLLIDE"];
    _u setDir (_dir4 + 90);
};
[_sg] call SC_passive;
_sg setBehaviour "SAFE";
_sg setSpeedMode "LIMITED";
_sg setFormation "LINE";
_sg addWaypoint [_squadPos getPos [200, _dir4 + 90], 0];
private _d4 = [_p4, _dir4, "B_Crocus_AP"] call SC_drone;
private _sq4 = AGLToASL (_squadPos vectorAdd [0, 0, 1.5]);
private _cam4 = [_sq4, _dir4, 16, 3, units _sg] call SC_viewFrom;
["static", _cam4, leader _sg, 0.6] call SC_setShot;   // pans with the squad as it walks
"SCENE|infantry" call SC_log;
["ANTI-PERSONNEL", "144 km/h, demo charge", 4] call SC_title;
uiSleep 1.5;
[_p4 getPos [6, _dir4 + 90], SC_AP, [_d4]] call SC_go;
[_d4, leader _sg, 40, 0.25, 2.6] spawn SC_slowmo;
[{ !alive _d4 }, 25] call SC_wait;
uiSleep 2.5;

// 5. Swarm -----------------------------------------------------------------------
// Camera behind the line of vehicles, looking back at the drones coming in.
private _drones5 = [];
private _targets5 = [];
for "_i" from 0 to 5 do {
    _drones5 pushBack ([_p5 getPos [(_i - 2.5) * 14, _dir5 + 90], _dir5] call SC_drone);
    private _tp = (_p5 getPos [220, _dir5]) getPos [(_i - 2.5) * 26, _dir5 + 90];
    _targets5 pushBack (if (_i % 2 == 0) then { [_tp, _dir5 + 180] call SC_tank } else {
        private _c = createVehicle ["O_MRAP_02_F", _tp, [], 0, "NONE"];
        _c setDir (_dir5 + 180); createVehicleCrew _c; [group effectiveCommander _c] call SC_passive; _c });
};
private _tc5 = AGLToASL ((_p5 getPos [220, _dir5]) vectorAdd [0, 0, 1]);
private _cam5 = [_tc5, _dir5, 55, 16, _targets5] call SC_viewFrom;
["static", _cam5, AGLToASL ((_p5 getPos [170, _dir5]) vectorAdd [0, 0, 4]), 0.9] call SC_setShot;
"SCENE|swarm" call SC_log;
["SWARMS", "6 drones pick 6 different targets", 4] call SC_title;
uiSleep 1.5;
[_p5 getPos [10, _dir5 + 180], SC_AT, _drones5] call SC_go;
[_drones5 select 2, _targets5 select 2, 50, 0.3, 3.5] spawn SC_slowmo;
[{ ({ alive _x } count _drones5) == 0 }, 30] call SC_wait;
uiSleep 1.5;

// End card ----------------------------------------------------------------------
["orbit", _tc5, 95, 45, 7, 0.8] call SC_setShot;
"SCENE|end" call SC_log;
["FPV AI DRONES v1.2", "Steam Workshop - works in Eden, Zeus and multiplayer", 6] call SC_title;
uiSleep 6.5;
("SC_black" call BIS_fnc_rscLayer) cutText ["", "BLACK OUT", 1.5];
uiSleep 2;
"END" call SC_log;
