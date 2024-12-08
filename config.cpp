class CfgPatches {
    class ai_killer_drones {
        units[] = {"AI_Killer_Drones_Module"};
        weapons[] = {};
        magazines[] = {};
        requiredVersion = 1.0;
        requiredAddons[] = {"A3_Modules_F"};
    };
};

class CfgFunctions {
    class AI_Killer_Drones {
        class Functions {
            file = "\ai_killer_drones\functions";
            class initModule {};
            class fpvLogic {};
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

    class AI_Killer_Drones_Module: Module_F {
        scope = 2;
        displayName = "AI Killer Drones";
        icon = "\A3\Modules_F_Curator\Data\iconSmoke_ca.paa";
        category = "Effects";
        
        function = "AI_Killer_Drones_fnc_initModule";
        functionPriority = 1;
        isGlobal = 1;
        isTriggerActivated = 0;
        isDisposable = 0;
        is3DEN = 0;

        class Attributes: AttributesBase {
            class UnitKinds: Edit {
                property = "AI_Killer_Drones_UnitKinds";
                displayName = "Target Unit Types";
                tooltip = "Array of unit types to target (e.g., LandVehicle,Car,Tank)";
                defaultValue = """LandVehicle,Car,Tank""";
            };
            class TargetSource: Combo {
                property = "AI_Killer_Drones_TargetSource";
                displayName = "Target Source";
                tooltip = "Source of targets";
                defaultValue = """vehicles""";
                class Values {
                    class AllUnits { name = "All Units"; value = "allUnits"; };
                    class Vehicles { name = "Vehicles"; value = "vehicles"; };
                };
            };
            class MaxDistance: Edit {
                property = "AI_Killer_Drones_MaxDistance";
                displayName = "Max Attack Distance";
                tooltip = "Maximum distance for attack";
                typeName = "NUMBER";
                defaultValue = "7";
            };
            class MaxDistance2D: Edit {
                property = "AI_Killer_Drones_MaxDistance2D";
                displayName = "Max 2D Distance";
                tooltip = "Maximum 2D distance";
                typeName = "NUMBER";
                defaultValue = "3";
            };
            class FinalHeight: Edit {
                property = "AI_Killer_Drones_FinalHeight";
                displayName = "Final Attack Height";
                tooltip = "Final height for attack";
                typeName = "NUMBER";
                defaultValue = "5";
            };
            class AllowObjectParent: Checkbox {
                property = "AI_Killer_Drones_AllowObjectParent";
                displayName = "Allow Object Parent";
                tooltip = "Allow targeting units in vehicles";
                defaultValue = "true";
            };
            class CustomAmmo: Edit {
                property = "AI_Killer_Drones_CustomAmmo";
                displayName = "Custom Ammo Type";
                tooltip = "Type of ammunition to use";
                defaultValue = """SatchelCharge_Remote_Ammo""";
            };
            class MinTargetDistance: Edit {
                property = "AI_Killer_Drones_MinTargetDistance";
                displayName = "Min Target Distance";
                tooltip = "Minimum distance to target";
                typeName = "NUMBER";
                defaultValue = "200";
            };
            class Debug: Checkbox {
                property = "AI_Killer_Drones_Debug";
                displayName = "Enable Debug";
                tooltip = "Show debug messages in system chat";
                defaultValue = "false";
            };
        };

        class ModuleDescription: ModuleDescription {
            description = "AI Killer Drones Module";
            sync[] = {"All"};
        };
    };
}; 