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
            class MaxDistance: Edit {
                property = "FPV_AI_Drones_MaxDistance";
                displayName = "Max Attack Distance";
                tooltip = "Maximum distance for attack";
                typeName = "NUMBER";
                defaultValue = "7";
            };
            class MaxDistance2D: Edit {
                property = "FPV_AI_Drones_MaxDistance2D";
                displayName = "Max 2D Distance";
                tooltip = "Maximum 2D distance";
                typeName = "NUMBER";
                defaultValue = "3";
            };
            class FinalHeight: Edit {
                property = "FPV_AI_Drones_FinalHeight";
                displayName = "Final Attack Height";
                tooltip = "Final height for attack";
                typeName = "NUMBER";
                defaultValue = "5";
            };
            class AllowObjectParent: Checkbox {
                property = "FPV_AI_Drones_AllowObjectParent";
                displayName = "Allow Object Parent";
                tooltip = "Allow targeting units in vehicles";
                defaultValue = "true";
            };
            class CustomAmmo: Edit {
                property = "FPV_AI_Drones_CustomAmmo";
                displayName = "Custom Ammo Type";
                tooltip = "Type of ammunition to use";
                defaultValue = """SatchelCharge_Remote_Ammo""";
            };
            class MinTargetDistance: Edit {
                property = "FPV_AI_Drones_MinTargetDistance";
                displayName = "Min Target Distance";
                tooltip = "Minimum distance to target";
                typeName = "NUMBER";
                defaultValue = "200";
            };
            class Debug: Checkbox {
                property = "FPV_AI_Drones_Debug";
                displayName = "Enable Debug";
                tooltip = "Show debug messages in system chat";
                defaultValue = "false";
            };
            class HeightAdjustmentDelay: Edit {
                property = "FPV_AI_Drones_HeightAdjustmentDelay";
                displayName = "Height Adjustment Delay";
                tooltip = "Base delay(seconds) for height adjustments (will be multiplied by height difference ratio)";
                typeName = "NUMBER";
                defaultValue = "0.5";
            };
            class StuckCheckInterval: Edit {
                property = "FPV_AI_Drones_StuckCheckInterval";
                displayName = "Stuck Check Interval";
                tooltip = "Time between stuck checks (seconds)";
                typeName = "NUMBER";
                defaultValue = "10";
            };
            class StuckThreshold: Edit {
                property = "FPV_AI_Drones_StuckThreshold";
                displayName = "Stuck Detection Threshold";
                tooltip = "Minimum relative change required to not be considered stuck (0.1 = 10%)";
                typeName = "NUMBER";
                defaultValue = "0.1";
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
        icon = "\A3\Modules_F_Curator\Data\iconSmoke_ca.paa";

        class Attributes: AttributesBase {
            class UnitKinds: Edit {
                property = "FPV_AI_Drones_UnitKinds";
                displayName = "Target Unit Types";
                tooltip = "Array of unit types to target";
                defaultValue = """LandVehicle,Car,Tank""";
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
            class MaxDistance: Edit {
                property = "FPV_AI_Drones_MaxDistance";
                displayName = "Max Attack Distance";
                tooltip = "Maximum distance for attack";
                typeName = "NUMBER";
                defaultValue = "7";
            };
            class MaxDistance2D: Edit {
                property = "FPV_AI_Drones_MaxDistance2D";
                displayName = "Max 2D Distance";
                tooltip = "Maximum 2D distance";
                typeName = "NUMBER";
                defaultValue = "3";
            };
            class FinalHeight: Edit {
                property = "FPV_AI_Drones_FinalHeight";
                displayName = "Final Attack Height";
                tooltip = "Final height for attack";
                typeName = "NUMBER";
                defaultValue = "5";
            };
            class AllowObjectParent: Checkbox {
                property = "FPV_AI_Drones_AllowObjectParent";
                displayName = "Allow Object Parent";
                tooltip = "Allow targeting units in vehicles";
                defaultValue = "true";
            };
            class CustomAmmo: Edit {
                property = "FPV_AI_Drones_CustomAmmo";
                displayName = "Custom Ammo Type";
                tooltip = "Type of ammunition to use";
                defaultValue = """SatchelCharge_Remote_Ammo""";
            };
            class MinTargetDistance: Edit {
                property = "FPV_AI_Drones_MinTargetDistance";
                displayName = "Min Target Distance";
                tooltip = "Minimum distance to target";
                typeName = "NUMBER";
                defaultValue = "200";
            };
            class HeightAdjustmentDelay: Edit {
                property = "FPV_AI_Drones_HeightAdjustmentDelay";
                displayName = "Height Adjustment Delay";
                tooltip = "Base delay for height adjustments (will be multiplied by height difference ratio)";
                typeName = "NUMBER";
                defaultValue = "0.1";
            };
            class StuckCheckInterval: Edit {
                property = "FPV_AI_Drones_StuckCheckInterval";
                displayName = "Stuck Check Interval";
                tooltip = "Time between stuck checks (seconds)";
                typeName = "NUMBER";
                defaultValue = "20";
            };
            class StuckThreshold: Edit {
                property = "FPV_AI_Drones_StuckThreshold";
                displayName = "Stuck Detection Threshold";
                tooltip = "Minimum relative change required to not be considered stuck (0.1 = 10%)";
                typeName = "NUMBER";
                defaultValue = "0.05";
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
        icon = "\A3\Modules_F_Curator\Data\iconSmoke_ca.paa";

        class Attributes: AttributesBase {
            class UnitKinds: Edit {
                property = "FPV_AI_Drones_UnitKinds";
                displayName = "Target Unit Types";
                tooltip = "Array of unit types to target";
                defaultValue = """Man""";
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
            class MaxDistance: Edit {
                property = "FPV_AI_Drones_MaxDistance";
                displayName = "Max Attack Distance";
                tooltip = "Maximum distance for attack";
                typeName = "NUMBER";
                defaultValue = "30";
            };
            class MaxDistance2D: Edit {
                property = "FPV_AI_Drones_MaxDistance2D";
                displayName = "Max 2D Distance";
                tooltip = "Maximum 2D distance";
                typeName = "NUMBER";
                defaultValue = "8";
            };
            class FinalHeight: Edit {
                property = "FPV_AI_Drones_FinalHeight";
                displayName = "Final Attack Height";
                tooltip = "Final height for attack";
                typeName = "NUMBER";
                defaultValue = "8";
            };
            class AllowObjectParent: Checkbox {
                property = "FPV_AI_Drones_AllowObjectParent";
                displayName = "Allow Object Parent";
                tooltip = "Allow targeting units in vehicles";
                defaultValue = "false";
            };
            class CustomAmmo: Edit {
                property = "FPV_AI_Drones_CustomAmmo";
                displayName = "Custom Ammo Type";
                tooltip = "Type of ammunition to use";
                defaultValue = """DemoCharge_Remote_Ammo""";
            };
            class MinTargetDistance: Edit {
                property = "FPV_AI_Drones_MinTargetDistance";
                displayName = "Min Target Distance";
                tooltip = "Minimum distance to target";
                typeName = "NUMBER";
                defaultValue = "200";
            };
            class HeightAdjustmentDelay: Edit {
                property = "FPV_AI_Drones_HeightAdjustmentDelay";
                displayName = "Height Adjustment Delay";
                tooltip = "Base delay for height adjustments (will be multiplied by height difference ratio)";
                typeName = "NUMBER";
                defaultValue = "0.25";
            };
            class StuckCheckInterval: Edit {
                property = "FPV_AI_Drones_StuckCheckInterval";
                displayName = "Stuck Check Interval";
                tooltip = "Time between stuck checks (seconds)";
                typeName = "NUMBER";
                defaultValue = "15";
            };
            class StuckThreshold: Edit {
                property = "FPV_AI_Drones_StuckThreshold";
                displayName = "Stuck Detection Threshold";
                tooltip = "Minimum relative change required to not be considered stuck (0.1 = 10%)";
                typeName = "NUMBER";
                defaultValue = "0.1";
            };
        };

        class ModuleDescription: ModuleDescription {
            description = "FPV AI Drones Module - Anti-Personnel Variant";
            sync[] = {"All"};
        };
    };
}; 