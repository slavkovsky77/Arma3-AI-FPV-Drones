/*
    FPV AI Drones - automated test harness (watching client).

    A chase camera behind whichever drone the server is testing, looking past it
    at the target, plus a running scoreboard. Hands control back to you when the
    run is finished.
*/

player allowDamage false;

// Manual session (run_tests.ps1 -Manual): no stages to watch, so run none of the
// camera/caption code on this machine at all - just hand over to the player.
FPVT_startStage = 1;
if (fileExists "testconfig.sqf") then { call compile preprocessFileLineNumbers "testconfig.sqf"; };
if (FPVT_startStage >= 99) exitWith {};

private _cam = "camera" camCreate [2000, 1930, 30];
_cam cameraEffect ["internal", "back"];
showCinemaBorder false;

private _lastCam = [2000, 1930, 30];
private _lastCaption = "";
private _lastResultCount = -1;
private _nextHint = 0;

while { !(missionNamespace getVariable ["FPVT_finished", false]) } do {
    private _caption = missionNamespace getVariable ["FPVT_caption", "Waiting for the server..."];
    private _focus = missionNamespace getVariable ["FPVT_focus", objNull];
    private _target = missionNamespace getVariable ["FPVT_target", objNull];
    private _results = missionNamespace getVariable ["FPVT_results", []];

    // --- scoreboard ---
    if (_caption != _lastCaption || { count _results != _lastResultCount } || { time > _nextHint }) then {
        if (_caption != _lastCaption) then {
            titleText [format ["<t size='1.3' shadow='2'>%1</t>", _caption], "PLAIN DOWN", 0.5, true, true];
        };
        _lastCaption = _caption;
        _lastResultCount = count _results;
        _nextHint = time + 10;

        private _lines = _results apply {
            _x params ["_check", "_status", "_detail"];
            format ["<t color='%1'>%2</t>  %3", ["#ff5050", "#7cfc00"] select (_status == "PASS"), _status, _check]
        };
        hintSilent parseText format ["<t size='1.1'>FPV AI Drones test</t><br/>%1<br/><br/>%2",
            _caption, _lines joinString "<br/>"];
    };

    // --- camera ---
    private _camPos = _lastCam;
    private _lookAt = _target;
    if (!isNull _focus && { alive _focus }) then {
        private _fp = getPosASL _focus;
        private _away = [0, -1, 0];
        if (!isNull _target) then {
            private _d = _fp vectorDiff (getPosASL _target);
            _d set [2, 0];
            if (vectorMagnitude _d > 1) then { _away = vectorNormalized _d; };
        } else {
            _lookAt = _focus;
        };
        // Behind the drone relative to its target and a little above it, so the
        // run-in and the impact are both in frame.
        _camPos = ASLToAGL (_fp vectorAdd (_away vectorMultiply 18) vectorAdd [0, 0, 6]);
    } else {
        // Drone gone (or none in this stage): hold the shot on the target, and
        // jump over to it if the last shot was somewhere else entirely.
        if (!isNull _target && { _lastCam distance2D _target > 300 }) then {
            _camPos = (getPosATL _target) vectorAdd [0, -45, 25];
        };
    };

    private _jump = (_camPos distance _lastCam) > 300;
    _cam camSetPos _camPos;
    if (!isNull _lookAt) then { _cam camSetTarget _lookAt; };
    _cam camCommit ([0.4, 0] select _jump);
    _lastCam = _camPos;

    sleep 0.1;
};

_cam cameraEffect ["terminate", "back"];
camDestroy _cam;

private _results = missionNamespace getVariable ["FPVT_results", []];
private _lines = _results apply {
    _x params ["_check", "_status", "_detail"];
    format ["<t color='%1'>%2</t>  %3<br/><t size='0.8' color='#bbbbbb'>%4</t>",
        ["#ff5050", "#7cfc00"] select (_status == "PASS"), _status, _check, _detail]
};
hint parseText format ["<t size='1.1'>%1</t><br/><br/>%2",
    missionNamespace getVariable ["FPVT_caption", ""], _lines joinString "<br/>"];
