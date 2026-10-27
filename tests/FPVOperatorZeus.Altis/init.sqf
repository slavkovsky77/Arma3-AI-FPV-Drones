/*
    FPV AI Drones - the UAV Operator module in Zeus, for a short video. Singleplayer.

    The real Zeus interface; the script does what a Zeus player would (drops the module
    onto a soldier, puts drones down next to him) and moves the Zeus camera. Recorded by
    tests\record_showcase.py --mission FPVOperatorZeus.Altis, which captures from
    SHOWCASE|BEGIN to SHOWCASE|END in the RPT.
*/
if (!isServer) exitWith {};

SC_log = { diag_log text format ["SHOWCASE|%1|%2", _this, diag_tickTime toFixed 2]; };

// --- Look -----------------------------------------------------------------
setDate [2035, 6, 24, 8, 30];
0 setOvercast 0.1; 0 setRain 0; 0 setFog 0; forceWeatherChange;
setViewDistance 3000;
enableEnvironment [false, true];
enableRadio false; enableSentences false; 0 fadeRadio 0;
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
SC_title = {
    params ["_big", ["_small", ""], ["_dur", 4]];
    private _txt = format ["<t font='PuristaBold' size='2.4' shadow='2' color='#ffffff'>%1</t>", _big];
    if (_small != "") then { _txt = _txt + format ["<br/><t font='PuristaMedium' size='1.4' shadow='2' color='#ffcc55'>%1</t>", _small]; };
    ("SC_title" call BIS_fnc_rscLayer) cutText [_txt, "PLAIN DOWN", 0.5, true, true];
    [_dur] spawn { params ["_d"]; uiSleep _d; ("SC_title" call BIS_fnc_rscLayer) cutFadeOut 0.7; };
};
SC_wait = {
    params ["_cond", "_max"];
    private _until = diag_tickTime + _max;
    waitUntil { uiSleep 0.05; (call _cond) || { diag_tickTime > _until } };
};
// A flat, open spot with nothing in the way for _len m along _dir.
SC_open = {
    params ["_near", "_radius", "_len"];
    private _best = [];
    private _bestScore = 1e9;
    for "_i" from 1 to 150 do {
        private _p = [_near, 0, _radius, 25, 0, 0.05, 0, [], [[-1, -1, 0], [-1, -1, 0]]] call BIS_fnc_findSafePos;
        if ((_p select 0) >= 0) then {
            _p = [_p select 0, _p select 1, 0];
            private _dir = random 360;
            private _end = _p getPos [_len, _dir];
            if (!surfaceIsWater _end && { abs ((getTerrainHeightASL _end) - (getTerrainHeightASL _p)) < 6 }) then {
                private _score = count nearestTerrainObjects [_p getPos [_len / 2, _dir], ["TREE", "SMALL TREE", "BUILDING", "HOUSE", "WALL", "FENCE", "POWER LINES", "ROCK", "ROCKS", "FOREST"], (_len / 2) + 40, false, true];
                if (_score < _bestScore) then { _bestScore = _score; _best = [_p, _dir]; };
            };
        };
        if (_bestScore == 0) exitWith {};
    };
    _best
};

// --- Zeus -------------------------------------------------------------------
SC_curator = (createGroup sideLogic) createUnit ["ModuleCurator_F", [0, 0, 0], [], 0, "NONE"];
player assignCurator SC_curator;
SC_curator addCuratorAddons activatedAddons;
SC_editable = { SC_curator addCuratorEditableObjects [_this, true]; };

// The Zeus camera, moved every frame towards what SC_cam returns: [posASL, lookAtASL].
SC_cam = {};
SC_camPos = [];
SC_camLook = [];
addMissionEventHandler ["EachFrame", {
    if (isNull curatorCamera) exitWith {};
    private _goal = call SC_cam;
    if (isNil "_goal" || { !(_goal isEqualType []) } || { count _goal < 2 }) exitWith {};
    _goal params ["_p", "_l"];
    if (SC_camPos isEqualTo []) then { SC_camPos = _p; SC_camLook = _l; };
    private _k = 1 - exp (-(diag_deltaTime max 0.001) * 1.8);
    SC_camPos = SC_camPos vectorAdd ((_p vectorDiff SC_camPos) vectorMultiply _k);
    SC_camLook = SC_camLook vectorAdd ((_l vectorDiff SC_camLook) vectorMultiply _k);
    private _dir = vectorNormalized (SC_camLook vectorDiff SC_camPos);
    private _up = vectorNormalized ((_dir vectorCrossProduct [0, 0, 1]) vectorCrossProduct _dir);
    if ((_up select 2) < 0) then { _up = _up vectorMultiply -1; };
    curatorCamera setPosASL SC_camPos;
    curatorCamera setVectorDirAndUp [_dir, _up];
}];
// Behind and above _obj, looking at it. _back/_up in m, _side turns the view.
SC_follow = {
    params ["_obj", "_back", "_up", ["_side", 0]];
    SC_followArgs = [_obj, _back, _up, _side];
    SC_cam = {
        SC_followArgs params ["_o", "_b", "_u", "_s"];
        private _p = getPosASL _o;
        private _c = (ASLToAGL _p) getPos [_b, SC_viewDir + 180 + _s];
        [AGLToASL (_c vectorAdd [0, 0, _u]), _p vectorAdd [0, 0, 1.5]]
    };
};

[] spawn {
    // A clear stretch of ground for the operator's walk and the drones' runs.
    private _spot = [[14600, 16700, 0], 2500, 500] call SC_open;
    _spot params ["_p0", "_dir"];
    SC_viewDir = _dir;
    format ["spot %1 dir %2", _p0, round _dir] call SC_log;
    player setPosATL (_p0 getPos [300, _dir + 180]);

    // The drone module: takes over every Crocus AT on the map, as placed in Zeus.
    private _atPos = _p0 getPos [30, _dir - 90];
    // The real AT module class: it knows its drone types (Crocus AT) for "Control All Drones Of This Type".
    SC_at = (createGroup sideLogic) createUnit ["FPV_AI_Drones_AT_Module", _atPos, [], 0, "CAN_COLLIDE"];
    {
        SC_at setVariable [_x select 0, _x select 1, true];
    } forEach [["UnitKinds", "LandVehicle,Car,Tank"], ["TargetSource", "vehicles"], ["InitialSearchHeight", 30],
        ["TargetDetectionRange", 280], ["AllowObjectParent", true], ["CustomAmmo", "SatchelCharge_Remote_Ammo"],
        ["EnableChatMessages", false], ["TakeOverAllOfType", true], ["AttackSpeed", 180]];
    [SC_at, [], true] call FPV_AI_Drones_fnc_initModule;

    // The operator and his squad.
    private _grp = createGroup [west, true];
    SC_op = _grp createUnit ["B_soldier_UAV_F", _p0, [], 0, "CAN_COLLIDE"];
    SC_op setDir _dir;
    SC_op setBehaviour "CARELESS";
    SC_op setSpeedMode "LIMITED";
    SC_op allowDamage true;
    [SC_op, SC_at] call SC_editable;

    uiSleep 1;
    openCuratorInterface;
    uiSleep 1;
    [SC_op, 22, 14, 30] call SC_follow;
    ("SC_black" call BIS_fnc_rscLayer) cutText ["", "BLACK IN", 1.5];
    "BEGIN" call SC_log;
    uiSleep 1.5;
    ["UAV Operator module", "FPV AI Drones 1.4 - in Zeus", 4] call SC_title;
    uiSleep 4.5;

    // 1. Dropped onto a soldier, as a Zeus player does: he is the operator now.
    "SCENE|drop" call SC_log;
    ["Drop it onto a soldier", "he becomes the drone operator", 4] call SC_title;
    uiSleep 1;
    SC_opModule = (createGroup sideLogic) createUnit ["FPV_AI_Drones_Operator_Module", getPosATL SC_op, [], 0, "CAN_COLLIDE"];
    SC_opModule attachTo [SC_op, [0, 0, 0]];
    [SC_opModule] call SC_editable;
    [SC_curator, SC_opModule] call FPV_AI_Drones_fnc_curatorPlaced;
    uiSleep 4;

    // 2. He walks - the module goes with him.
    "SCENE|walk" call SC_log;
    ["It moves with him", "", 4] call SC_title;
    private _walkTo = _p0 getPos [140, _dir];
    SC_op doMove _walkTo;
    [{ (SC_op distance2D _walkTo) < 8 }, 40] call SC_wait;
    doStop SC_op;
    uiSleep 1;

    // 3. Drones put down next to him become his.
    "SCENE|drones" call SC_log;
    ["Drones put down next to him", "become his", 4] call SC_title;
    SC_drones = [];
    {
        private _d = createVehicle ["B_Crocus_AT", SC_op getPos [12 + _forEachIndex * 6, SC_viewDir + 60 - _forEachIndex * 120], [], 0, "CAN_COLLIDE"];
        createVehicleCrew _d;
        [_d] call SC_editable;
        SC_drones pushBack _d;
        uiSleep 0.8;
    } forEach [0, 1, 2];
    [{ ({ (SC_op in (_x getVariable ["FPV_AI_Drones_operators", []])) } count SC_drones) == 3 }, 12] call SC_wait;
    format ["his drones: %1", { SC_op in (_x getVariable ["FPV_AI_Drones_operators", []]) } count SC_drones] call SC_log;
    uiSleep 1.5;

    // 4. Enemy armour. While he lives, his drones attack.
    "SCENE|attack" call SC_log;
    private _tankPos = SC_op getPos [240, SC_viewDir];
    SC_tanks = [];
    {
        private _t = createVehicle ["O_MBT_02_cannon_F", _tankPos getPos [_x, SC_viewDir + 90], [], 0, "NONE"];
        _t setDir (SC_viewDir + 180);
        createVehicleCrew _t;
        [group effectiveCommander _t] call SC_passive;
        { _x disableAI "MOVE"; } forEach crew _t;
        [_t] call SC_editable;
        SC_tanks pushBack _t;
    } forEach [-25, 25];
    ["Enemy armour", "his drones take off", 3.5] call SC_title;
    SC_cam = {
        private _p = getPosASL SC_op;
        private _t = getPosASL (SC_tanks select 0);
        private _mid = (_p vectorAdd _t) vectorMultiply 0.5;
        private _c = (ASLToAGL _mid) getPos [190, SC_viewDir + 115];
        [AGLToASL (_c vectorAdd [0, 0, 95]), _mid]
    };
    // 5. Once they are on their way, the operator is hit.
    [{ ({ alive _x && { ((getPosATL _x) select 2) > 12 } } count SC_drones) >= 2 }, 20] call SC_wait;
    uiSleep 2.2;
    "SCENE|operator_killed" call SC_log;
    [SC_op, 14, 7, 20] call SC_follow;
    uiSleep 0.6;
    SC_op setDamage 1;
    ["Operator killed", "his drones lose their pilot and come down", 5] call SC_title;
    uiSleep 1.2;
    private _falling = (SC_drones select { alive _x }) param [0, objNull];
    if (!isNull _falling) then {
        SC_fallArgs = [_falling];
        SC_cam = {
            private _d = SC_fallArgs select 0;
            private _p = getPosASL _d;
            private _c = (ASLToAGL _p) getPos [45, SC_viewDir + 120];
            [AGLToASL (_c vectorAdd [0, 0, 18]), _p]
        };
    };
    [{ ({ alive _x && { ((getPosATL _x) select 2) > 2 } } count SC_drones) == 0 }, 12] call SC_wait;
    uiSleep 3;
    format ["tanks alive %1 | drones still up %2", { alive _x && { ({ alive _x } count crew _x) > 0 } } count SC_tanks,
        { alive _x && { ((getPosATL _x) select 2) > 2 } } count SC_drones] call SC_log;

    ["FPV AI Drones 1.4", "Zeus: Modules > FPV AI Drones - UAV Operator", 5] call SC_title;
    uiSleep 5;
    ("SC_black" call BIS_fnc_rscLayer) cutText ["", "BLACK OUT", 1.5];
    uiSleep 2;
    "END" call SC_log;
};
