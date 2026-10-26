class CfgPatches {
    class fpv_ai_drones {
        units[] = {
            "FPV_AI_Drones_Module",
            "FPV_AI_Drones_AT_Module",
            "FPV_AI_Drones_AP_Module"
        };
        weapons[] = {};
        magazines[] = {};
        requiredVersion = 1.0;
        requiredAddons[] = {"A3_Modules_F"};
    };
};

class CfgFunctions {
    class FPV_AI_Drones {
        class Functions {
            file = "\fpv_ai_drones\functions";
            class initModule {};
            class fpvLogic {};
            class curatorHook { postInit = 1; };   // starts FPV modules placed in Zeus
            class curatorPlaced {};
        };
    };
};

class CfgVehicles {
    class Logic;
    class Module_F: Logic {
        class AttributesBase {
            class Default;
            class Edit;
            class Combo;
            class Checkbox;
            class NumberState;
        };
        class ModuleDescription;
    };

    class FPV_AI_Drones_Module: Module_F {
        scope = 2;
        // Zeus: scopeCurator puts the module in the curator module tree, and
        // curatorCanAttach lets it be dropped directly onto a specific drone.
        // The AT and AP modules inherit both from here.
        scopeCurator = 2;
        curatorCanAttach = 1;
        displayName = "FPV AI Drones";
        icon = "\A3\Modules_F_Curator\Data\iconSmoke_ca.paa";
        category = "Effects";

        function = "FPV_AI_Drones_fnc_initModule";
        functionPriority = 1;
        isGlobal = 1;
        isTriggerActivated = 0;
        isDisposable = 0;
        is3DEN = 0;

        class Attributes: AttributesBase {
            class UnitKinds: Edit {
                property = "FPV_AI_Drones_UnitKinds";
                displayName = "Target Unit Types";
                tooltip = "Array of unit types to target (e.g., LandVehicle,Car,Tank)";
                defaultValue = """LandVehicle,Car,Tank""";
            };
            class TargetSides: Combo {
                property = "FPV_AI_Drones_TargetSides";
                displayName = "Target Sides";
                tooltip = "Who the drones attack. 'Mission's enemies' follows the mission's side relations for the drone's own side. The other options attack that side whatever the relations say. Civilians are never targets.";
                defaultValue = """ENEMIES""";
                class Values {
                    class Enemies { name = "Mission's enemies"; value = "ENEMIES"; };
                    class East    { name = "OPFOR only"; value = "EAST"; };
                    class West    { name = "BLUFOR only"; value = "WEST"; };
                    class Guer    { name = "Independent only"; value = "GUER"; };
                    class NotOwn  { name = "Everyone except own side"; value = "NOTOWN"; };
                };
            };
            class EnableChatMessages: Checkbox {
                property = "FPV_AI_Drones_EnableChatMessages";
                displayName = "Enable Chat Messages";
                tooltip = "Show system chat notifications for drone events";
                defaultValue = "false";
            };
            class TakeOverAllOfType: Checkbox {
                property = "FPV_AI_Drones_TakeOverAllOfType";
                displayName = "Control All Drones Of This Type";
                tooltip = "Also take over every other drone of the same type on the map, including ones spawned later (e.g. in Zeus). Turn off to control only the drones this module is synced to or placed on - leaves players' own drones alone.";
                defaultValue = "true";
            };
            class TargetSource: Combo {
                property = "FPV_AI_Drones_TargetSource";
                displayName = "Target Source";
                tooltip = "Source of targets";
                defaultValue = """vehicles""";
                class Values {
                    class AllUnits { name = "All Units"; value = "allUnits"; };
                    class Vehicles { name = "Vehicles"; value = "vehicles"; };
                };
            };
            class InitialSearchHeight: Edit {
                property = "FPV_AI_Drones_InitialSearchHeight";
                displayName = "Initial Search Height";
                tooltip = "Starting height the drone will fly at when searching for targets";
                typeName = "NUMBER";
                defaultValue = "50";
            };
            class TargetDetectionRange: Edit {
                property = "FPV_AI_Drones_TargetDetectionRange";
                displayName = "Target Detection Range";
                tooltip = "Target must be closer than this distance for drone to begin pursuit";
                typeName = "NUMBER";
                defaultValue = "200";
            };
            class AttackSpeed: Edit {
                property = "FPV_AI_Drones_AttackSpeed";
                displayName = "Attack Speed (km/h)";
                tooltip = "Top speed of the attack run once the drone has a target. Default 180 km/h for Anti-Tank, 144 for Anti-Personnel. Slower is easier to dodge or shoot down; faster turns wider.";
                typeName = "NUMBER";
                defaultValue = "180";
            };
            class CruiseSpeed: Edit {
                property = "FPV_AI_Drones_CruiseSpeed";
                displayName = "Cruise Speed (km/h)";
                tooltip = "Speed on waypoints, before the drone has found a target. Default 126 km/h.";
                typeName = "NUMBER";
                defaultValue = "126";
            };
            class BrakingTime: Edit {
                property = "FPV_AI_Drones_BrakingTime";
                displayName = "Braking Time (s)";
                tooltip = "Seconds the drone needs to stop from full speed - how heavy it feels. Higher: slower to brake and turn, wider turns at waypoints, and a target that swerves late can get away. Lower: more agile. Default 2.";
                typeName = "NUMBER";
                defaultValue = "2";
            };
            class HitChance: Edit {
                property = "FPV_AI_Drones_HitChance";
                displayName = "Accuracy (%)";
                tooltip = "Chance that an attack run is aimed at the target itself. The others miss: the drone comes down beside the target, a few blast radii away, and its payload goes off there. 100 = no planned misses (a swerving target can still make it miss). Default 100.";
                typeName = "NUMBER";
                defaultValue = "100";
            };
            class SecondPassChance: Edit {
                property = "FPV_AI_Drones_SecondPassChance";
                displayName = "Second Pass Chance (%)";
                tooltip = "When an attack run misses (Accuracy below 100): the chance that the drone flies low past the target and comes round for another run, instead of going down beside it. Every new run rolls Accuracy again. Default 50.";
                typeName = "NUMBER";
                defaultValue = "50";
            };
            class DeleteDrone: Checkbox {
                property = "FPV_AI_Drones_DeleteDrone";
                displayName = "Delete Drone After Detonation";
                tooltip = "Remove the drone when its payload goes off instead of leaving a wreck - few FPV drones have a proper destroyed model, and very little is left of a real one. Default on.";
                defaultValue = "true";
            };
            class AttackEmptyVehicles: Checkbox {
                property = "FPV_AI_Drones_AttackEmptyVehicles";
                displayName = "Attack Empty Vehicles";
                tooltip = "Also attack vehicles with nobody inside (parked or abandoned), if their faction belongs to a side the drone attacks (civilian vehicles never). Crewed targets still come first; a vehicle whose crew was killed is not attacked again. Default on.";
                defaultValue = "true";
            };
            class OperatorRequired: Checkbox {
                property = "FPV_AI_Drones_OperatorRequired";
                displayName = "UAV Operator Required";
                tooltip = "Synchronise one or more soldiers to this module as the drones' operators. When the last of them is killed, the drones lose their pilot: engines off, and they come down. Eden editor only (Zeus can't synchronise). Default off.";
                defaultValue = "false";
            };
            class AllowObjectParent: Checkbox {
                property = "FPV_AI_Drones_AllowObjectParent";
                displayName = "Allow Object Parent";
                tooltip = "Allow targeting units in vehicles";
                defaultValue = "true";
            };
            class CustomAmmo: Edit {
                property = "FPV_AI_Drones_CustomAmmo";
                displayName = "Custom Ammo Types";
                tooltip = "Types of ammunition to use (comma-separated, e.g., 'SatchelCharge_Remote_Ammo,DemoCharge_Remote_Ammo')";
                defaultValue = """SatchelCharge_Remote_Ammo""";
            };
        };

        class ModuleDescription: ModuleDescription {
            description = "FPV AI Drones Module";
            sync[] = {"All"};
        };
    };

    class FPV_AI_Drones_AT_Module: FPV_AI_Drones_Module {
        scope = 2;
        displayName = "FPV AI Drones - Anti-Tank";
        // Drone types this module controls by default (with "Control All Drones Of This Type").
        fpvDefaultDroneTypes[] = {"B_Crocus_AT", "O_Crocus_AT", "I_Crocus_AT"};
        icon = "\A3\Modules_F_Curator\Data\iconSmoke_ca.paa";

        class Attributes: AttributesBase {
            class UnitKinds: Edit {
                property = "FPV_AI_Drones_UnitKinds";
                displayName = "Target Unit Types";
                tooltip = "Array of unit types to target";
                defaultValue = """LandVehicle,Car,Tank""";
            };
            class TargetSides: Combo {
                property = "FPV_AI_Drones_TargetSides";
                displayName = "Target Sides";
                tooltip = "Who the drones attack. 'Mission's enemies' follows the mission's side relations for the drone's own side. The other options attack that side whatever the relations say. Civilians are never targets.";
                defaultValue = """ENEMIES""";
                class Values {
                    class Enemies { name = "Mission's enemies"; value = "ENEMIES"; };
                    class East    { name = "OPFOR only"; value = "EAST"; };
                    class West    { name = "BLUFOR only"; value = "WEST"; };
                    class Guer    { name = "Independent only"; value = "GUER"; };
                    class NotOwn  { name = "Everyone except own side"; value = "NOTOWN"; };
                };
            };
            class EnableChatMessages: Checkbox {
                property = "FPV_AI_Drones_EnableChatMessages";
                displayName = "Enable Chat Messages";
                tooltip = "Show system chat notifications for drone events";
                defaultValue = "false";
            };
            class TakeOverAllOfType: Checkbox {
                property = "FPV_AI_Drones_TakeOverAllOfType";
                displayName = "Control All Drones Of This Type";
                tooltip = "Also take over every other drone of the same type on the map, including ones spawned later (e.g. in Zeus). Turn off to control only the drones this module is synced to or placed on - leaves players' own drones alone.";
                defaultValue = "true";
            };
            class TargetSource: Combo {
                property = "FPV_AI_Drones_TargetSource";
                displayName = "Target Source";
                tooltip = "Source of targets";
                defaultValue = """vehicles""";
                class Values {
                    class AllUnits { name = "All Units"; value = "allUnits"; };
                    class Vehicles { name = "Vehicles"; value = "vehicles"; };
                };
            };
            class InitialSearchHeight: Edit {
                property = "FPV_AI_Drones_InitialSearchHeight";
                displayName = "Initial Search Height";
                tooltip = "Starting height the drone will fly at when searching for targets";
                typeName = "NUMBER";
                defaultValue = "30";
            };
            class TargetDetectionRange: Edit {
                property = "FPV_AI_Drones_TargetDetectionRange";
                displayName = "Target Detection Range";
                tooltip = "Target must be closer than this distance for drone to begin pursuit";
                typeName = "NUMBER";
                defaultValue = "200";
            };
            class AttackSpeed: Edit {
                property = "FPV_AI_Drones_AttackSpeed";
                displayName = "Attack Speed (km/h)";
                tooltip = "Top speed of the attack run once the drone has a target. Default 180 km/h for Anti-Tank, 144 for Anti-Personnel. Slower is easier to dodge or shoot down; faster turns wider.";
                typeName = "NUMBER";
                defaultValue = "180";
            };
            class CruiseSpeed: Edit {
                property = "FPV_AI_Drones_CruiseSpeed";
                displayName = "Cruise Speed (km/h)";
                tooltip = "Speed on waypoints, before the drone has found a target. Default 126 km/h.";
                typeName = "NUMBER";
                defaultValue = "126";
            };
            class BrakingTime: Edit {
                property = "FPV_AI_Drones_BrakingTime";
                displayName = "Braking Time (s)";
                tooltip = "Seconds the drone needs to stop from full speed - how heavy it feels. Higher: slower to brake and turn, wider turns at waypoints, and a target that swerves late can get away. Lower: more agile. Default 2.";
                typeName = "NUMBER";
                defaultValue = "2";
            };
            class HitChance: Edit {
                property = "FPV_AI_Drones_HitChance";
                displayName = "Accuracy (%)";
                tooltip = "Chance that an attack run is aimed at the target itself. The others miss: the drone comes down beside the target, a few blast radii away, and its payload goes off there. 100 = no planned misses (a swerving target can still make it miss). Default 100.";
                typeName = "NUMBER";
                defaultValue = "100";
            };
            class SecondPassChance: Edit {
                property = "FPV_AI_Drones_SecondPassChance";
                displayName = "Second Pass Chance (%)";
                tooltip = "When an attack run misses (Accuracy below 100): the chance that the drone flies low past the target and comes round for another run, instead of going down beside it. Every new run rolls Accuracy again. Default 50.";
                typeName = "NUMBER";
                defaultValue = "50";
            };
            class DeleteDrone: Checkbox {
                property = "FPV_AI_Drones_DeleteDrone";
                displayName = "Delete Drone After Detonation";
                tooltip = "Remove the drone when its payload goes off instead of leaving a wreck - few FPV drones have a proper destroyed model, and very little is left of a real one. Default on.";
                defaultValue = "true";
            };
            class AttackEmptyVehicles: Checkbox {
                property = "FPV_AI_Drones_AttackEmptyVehicles";
                displayName = "Attack Empty Vehicles";
                tooltip = "Also attack vehicles with nobody inside (parked or abandoned), if their faction belongs to a side the drone attacks (civilian vehicles never). Crewed targets still come first; a vehicle whose crew was killed is not attacked again. Default on.";
                defaultValue = "true";
            };
            class OperatorRequired: Checkbox {
                property = "FPV_AI_Drones_OperatorRequired";
                displayName = "UAV Operator Required";
                tooltip = "Synchronise one or more soldiers to this module as the drones' operators. When the last of them is killed, the drones lose their pilot: engines off, and they come down. Eden editor only (Zeus can't synchronise). Default off.";
                defaultValue = "false";
            };
            class AllowObjectParent: Checkbox {
                property = "FPV_AI_Drones_AllowObjectParent";
                displayName = "Allow Object Parent";
                tooltip = "Allow targeting units in vehicles";
                defaultValue = "true";
            };
            class CustomAmmo: Edit {
                property = "FPV_AI_Drones_CustomAmmo";
                displayName = "Custom Ammo Types";
                tooltip = "Types of ammunition to use (comma-separated, e.g., 'SatchelCharge_Remote_Ammo,DemoCharge_Remote_Ammo')";
                defaultValue = """SatchelCharge_Remote_Ammo""";
            };
        };

        class ModuleDescription: ModuleDescription {
            description = "FPV AI Drones Module - Anti-Tank Variant";
            sync[] = {"All"};
        };
    };

    class FPV_AI_Drones_AP_Module: FPV_AI_Drones_Module {
        scope = 2;
        displayName = "FPV AI Drones - Anti-Personnel";
        fpvDefaultDroneTypes[] = {"B_Crocus_AP", "O_Crocus_AP", "I_Crocus_AP"};
        icon = "\A3\Modules_F_Curator\Data\iconSmoke_ca.paa";

        class Attributes: AttributesBase {
            class UnitKinds: Edit {
                property = "FPV_AI_Drones_UnitKinds";
                displayName = "Target Unit Types";
                tooltip = "Array of unit types to target";
                defaultValue = """Man""";
            };
            class TargetSides: Combo {
                property = "FPV_AI_Drones_TargetSides";
                displayName = "Target Sides";
                tooltip = "Who the drones attack. 'Mission's enemies' follows the mission's side relations for the drone's own side. The other options attack that side whatever the relations say. Civilians are never targets.";
                defaultValue = """ENEMIES""";
                class Values {
                    class Enemies { name = "Mission's enemies"; value = "ENEMIES"; };
                    class East    { name = "OPFOR only"; value = "EAST"; };
                    class West    { name = "BLUFOR only"; value = "WEST"; };
                    class Guer    { name = "Independent only"; value = "GUER"; };
                    class NotOwn  { name = "Everyone except own side"; value = "NOTOWN"; };
                };
            };
            class EnableChatMessages: Checkbox {
                property = "FPV_AI_Drones_EnableChatMessages";
                displayName = "Enable Chat Messages";
                tooltip = "Show system chat notifications for drone events";
                defaultValue = "false";
            };
            class TakeOverAllOfType: Checkbox {
                property = "FPV_AI_Drones_TakeOverAllOfType";
                displayName = "Control All Drones Of This Type";
                tooltip = "Also take over every other drone of the same type on the map, including ones spawned later (e.g. in Zeus). Turn off to control only the drones this module is synced to or placed on - leaves players' own drones alone.";
                defaultValue = "true";
            };
            class TargetSource: Combo {
                property = "FPV_AI_Drones_TargetSource";
                displayName = "Target Source";
                tooltip = "Source of targets";
                defaultValue = """allUnits""";
                class Values {
                    class AllUnits { name = "All Units"; value = "allUnits"; };
                    class Vehicles { name = "Vehicles"; value = "vehicles"; };
                };
            };
            class InitialSearchHeight: Edit {
                property = "FPV_AI_Drones_InitialSearchHeight";
                displayName = "Initial Search Height";
                tooltip = "Starting height the drone will fly at when searching for targets";
                typeName = "NUMBER";
                defaultValue = "50";
            };
            class TargetDetectionRange: Edit {
                property = "FPV_AI_Drones_TargetDetectionRange";
                displayName = "Target Detection Range";
                tooltip = "Target must be closer than this distance for drone to begin pursuit";
                typeName = "NUMBER";
                defaultValue = "200";
            };
            class AttackSpeed: Edit {
                property = "FPV_AI_Drones_AttackSpeed";
                displayName = "Attack Speed (km/h)";
                tooltip = "Top speed of the attack run once the drone has a target. Default 180 km/h for Anti-Tank, 144 for Anti-Personnel. Slower is easier to dodge or shoot down; faster turns wider.";
                typeName = "NUMBER";
                defaultValue = "144";
            };
            class CruiseSpeed: Edit {
                property = "FPV_AI_Drones_CruiseSpeed";
                displayName = "Cruise Speed (km/h)";
                tooltip = "Speed on waypoints, before the drone has found a target. Default 126 km/h.";
                typeName = "NUMBER";
                defaultValue = "126";
            };
            class BrakingTime: Edit {
                property = "FPV_AI_Drones_BrakingTime";
                displayName = "Braking Time (s)";
                tooltip = "Seconds the drone needs to stop from full speed - how heavy it feels. Higher: slower to brake and turn, wider turns at waypoints, and a target that swerves late can get away. Lower: more agile. Default 2.";
                typeName = "NUMBER";
                defaultValue = "2";
            };
            class HitChance: Edit {
                property = "FPV_AI_Drones_HitChance";
                displayName = "Accuracy (%)";
                tooltip = "Chance that an attack run is aimed at the target itself. The others miss: the drone comes down beside the target, a few blast radii away, and its payload goes off there. 100 = no planned misses (a swerving target can still make it miss). Default 100.";
                typeName = "NUMBER";
                defaultValue = "100";
            };
            class SecondPassChance: Edit {
                property = "FPV_AI_Drones_SecondPassChance";
                displayName = "Second Pass Chance (%)";
                tooltip = "When an attack run misses (Accuracy below 100): the chance that the drone flies low past the target and comes round for another run, instead of going down beside it. Every new run rolls Accuracy again. Default 50.";
                typeName = "NUMBER";
                defaultValue = "50";
            };
            class DeleteDrone: Checkbox {
                property = "FPV_AI_Drones_DeleteDrone";
                displayName = "Delete Drone After Detonation";
                tooltip = "Remove the drone when its payload goes off instead of leaving a wreck - few FPV drones have a proper destroyed model, and very little is left of a real one. Default on.";
                defaultValue = "true";
            };
            class AttackEmptyVehicles: Checkbox {
                property = "FPV_AI_Drones_AttackEmptyVehicles";
                displayName = "Attack Empty Vehicles";
                tooltip = "Also attack vehicles with nobody inside (parked or abandoned), if their faction belongs to a side the drone attacks (civilian vehicles never). Crewed targets still come first; a vehicle whose crew was killed is not attacked again. Default on.";
                defaultValue = "true";
            };
            class OperatorRequired: Checkbox {
                property = "FPV_AI_Drones_OperatorRequired";
                displayName = "UAV Operator Required";
                tooltip = "Synchronise one or more soldiers to this module as the drones' operators. When the last of them is killed, the drones lose their pilot: engines off, and they come down. Eden editor only (Zeus can't synchronise). Default off.";
                defaultValue = "false";
            };
            class AllowObjectParent: Checkbox {
                property = "FPV_AI_Drones_AllowObjectParent";
                displayName = "Allow Object Parent";
                tooltip = "Allow targeting units in vehicles";
                defaultValue = "false";
            };
            class CustomAmmo: Edit {
                property = "FPV_AI_Drones_CustomAmmo";
                displayName = "Custom Ammo Types";
                tooltip = "Types of ammunition to use (comma-separated, e.g., 'SatchelCharge_Remote_Ammo,DemoCharge_Remote_Ammo')";
                defaultValue = """DemoCharge_Remote_Ammo""";
            };
        };

        class ModuleDescription: ModuleDescription {
            description = "FPV AI Drones Module - Anti-Personnel Variant";
            sync[] = {"All"};
        };
    };
}; 
// Example scenarios shipped with the mod (VR). They show up under Scenarios, and
// the Zeus one also in the multiplayer mission list. Editable copies are in the
// mod's examples\ folder (copied there by build.py).
class CfgMissions {
    class Showcases {
        class FPV_AI_Drones_EdenExample {
            briefingName = "FPV AI Drones - Editor example";
            directory = "fpv_ai_drones\missions\FPV_EdenExample.VR";
        };
        class FPV_AI_Drones_ZeusExample {
            briefingName = "FPV AI Drones - Zeus example";
            directory = "fpv_ai_drones\missions\FPV_ZeusExample.VR";
        };
    };
    class MPMissions {
        class FPV_AI_Drones_ZeusExample {
            briefingName = "FPV AI Drones - Zeus example";
            directory = "fpv_ai_drones\missions\FPV_ZeusExample.VR";
        };
    };
};
