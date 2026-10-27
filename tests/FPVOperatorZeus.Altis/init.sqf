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
showChat false;   // the Crocus mod writes "Deleteing !" when its drones blow up
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

// Path of the first tree item whose text contains _needle, or [].
SC_tvFind = {
    params ["_tv", "_path", "_needle"];
    private _found = [];
    for "_i" from 0 to ((_tv tvCount _path) - 1) do {
        private _p = _path + [_i];
        if (((_tv tvText _p) find _needle) >= 0) exitWith { _found = _p; };
        private _sub = [_tv, _p, _needle] call SC_tvFind;
        if (_sub isNotEqualTo []) exitWith { _found = _sub; };
    };
    _found
};
// Zeus' Create panel: press the mode button whose class name has _mode in it ("module", "unit").
SC_zeusMode = {
    params ["_mode"];
    private _disp = findDisplay 312;
    private _btn = (allControls _disp) select { private _c = toLower ctrlClassName _x; (_c find "mode") >= 0 && { (_c find _mode) >= 0 } };
    format ["ui mode %1: %2", _mode, _btn apply { [ctrlIDC _x, ctrlClassName _x] }] call SC_log;
    if (_btn isNotEqualTo []) then { ctrlActivate (_btn select 0); };
};
// Picks the module in Zeus' Create panel, as a player does before placing it.
SC_pickModule = {
    private _disp = findDisplay 312;
    if (isNull _disp) exitWith { "ui no curator display" call SC_log; };
    ["module"] call SC_zeusMode;
    uiSleep 0.4;
    private _hit = false;
    // The tree on screen first: the unit trees are big.
    private _trees = (allControls _disp) select { ctrlType _x == 12 };
    _trees = (_trees select { ctrlShown _x }) + (_trees select { !ctrlShown _x });
    {
        private _tv = _x;
        private _path = [_tv, [], "UAV Operator"] call SC_tvFind;
        if (_path isNotEqualTo []) exitWith {
            for "_i" from 1 to ((count _path) - 1) do { _tv tvExpand (_path select [0, _i]); };
            _tv tvSetCurSel _path;
            uiNamespace setVariable ["SC_pickedTree", _tv];   // a control in missionNamespace pops an engine warning
            _hit = true;
            format ["ui module in tree %1 (%2) at %3, shown %4", ctrlIDC _tv, ctrlClassName _tv, _path, ctrlShown _tv] call SC_log;
        };
    } forEach _trees;
    if (!_hit) then { "ui module not found in any tree" call SC_log; };
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
    SC_op setSpeedMode "FULL";
    SC_op allowDamage true;
    [SC_op, SC_at] call SC_editable;

    uiSleep 1;
    openCuratorInterface;
    uiSleep 1;
    [SC_op, 13, 6.5, 30] call SC_follow;
    ("SC_black" call BIS_fnc_rscLayer) cutText ["", "BLACK IN", 1.5];
    "BEGIN" call SC_log;
    uiSleep 1.5;
    ["UAV Operator module", "FPV AI Drones 1.4 - in Zeus", 4] call SC_title;
    uiSleep 4.5;

    // 1. Dropped onto a soldier, as a Zeus player does: he is the operator now.
    "SCENE|drop" call SC_log;
    ["Drop it onto a soldier", "Zeus: Modules > Effects > FPV AI Drones - UAV Operator", 4] call SC_title;
    call SC_pickModule;
    uiSleep 2.2;
    SC_opModule = (createGroup sideLogic) createUnit ["FPV_AI_Drones_Operator_Module", getPosATL SC_op, [], 0, "CAN_COLLIDE"];
    SC_opModule attachTo [SC_op, [0, 0, 0]];
    [SC_opModule] call SC_editable;
    [SC_curator, SC_opModule] call FPV_AI_Drones_fnc_curatorPlaced;
    private _tree = uiNamespace getVariable ["SC_pickedTree", controlNull];
    if (!isNull _tree) then { _tree tvSetCurSel [-1]; };
    ["he is the drone operator now", "", 3] call SC_title;
    uiSleep 3.5;
    ["unit"] call SC_zeusMode;

    // 2. He walks - the module goes with him.
    "SCENE|walk" call SC_log;
    ["It moves with him", "", 4] call SC_title;
    private _walkTo = _p0 getPos [70, _dir];
    SC_op doMove _walkTo;
    [{ (SC_op distance2D _walkTo) < 8 }, 22] call SC_wait;
    doStop SC_op;
    uiSleep 1;

    // 3. Drones put down next to him become his.
    "SCENE|drones" call SC_log;
    [SC_op, 26, 13, 30] call SC_follow;
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
    // Behind the operator, looking past him towards the tanks.
    SC_cam = {
        private _p = getPosATL SC_op;
        private _c = _p getPos [45, SC_viewDir + 200];
        private _l = _p getPos [90, SC_viewDir];
        [AGLToASL [_c select 0, _c select 1, 26], AGLToASL [_l select 0, _l select 1, 8]]
    };
    // 5. Once they are on their way, the operator is hit.
    [{ ({ alive _x && { ((getPosATL _x) select 2) > 12 } } count SC_drones) >= 2 }, 20] call SC_wait;
    uiSleep 2.2;
    "SCENE|operator_killed" call SC_log;
    [SC_op, 12, 6, 20] call SC_follow;
    uiSleep 1.2;
    SC_op setDamage 1;
    SC_killedAt = diag_tickTime;
    ["Operator killed", "his drones lose their pilot and come down", 5] call SC_title;
    uiSleep 1.6;
    // The drones, at their own height, from the side: they follow them down.
    SC_cam = {
        private _up = SC_drones select { alive _x };
        if (_up isEqualTo []) exitWith { [SC_camPos, SC_camLook] };
        private _m = [0, 0, 0];
        { _m = _m vectorAdd (getPosASL _x); } forEach _up;
        _m = _m vectorMultiply (1 / count _up);
        private _c = (ASLToAGL _m) getPos [70, SC_viewDir + 105];
        private _z = ((getTerrainHeightASL _c) + 5) max ((_m select 2) + 6);
        [[_c select 0, _c select 1, _z], _m]
    };
    [{ ({ alive _x && { ((getPosATL _x) select 2) > 2 } } count SC_drones) == 0 }, 25] call SC_wait;
    format ["drones down %1 s after the operator", (diag_tickTime - SC_killedAt) toFixed 1] call SC_log;
    uiSleep 3;
    format ["tanks alive %1 | drones still up %2", { alive _x && { ({ alive _x } count crew _x) > 0 } } count SC_tanks,
        { alive _x && { ((getPosATL _x) select 2) > 2 } } count SC_drones] call SC_log;

    ["FPV AI Drones 1.4", "Zeus: Modules > Effects > FPV AI Drones - UAV Operator", 5] call SC_title;
    uiSleep 5.5;
    "END" call SC_log;
};
