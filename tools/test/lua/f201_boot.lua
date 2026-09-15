-- RSF-F201 boot fixture: engine-side input globals must exist BEFORE main.lua
-- loads, because MasterHUD installs its wrappers at module load. Loaded through
-- --!load: after f201_model_binding.lua and before the production files.
F201Model.installEngine({ "MH_TOGGLE_ALL_HUDS", "MH_EDIT_HUDS" })
F201Boot = { nativeCalls = 0 }
PlayerInputComponent.registerActionEvents = function() F201Boot.nativeCalls = F201Boot.nativeCalls + 1 end
F201Boot.nativePlayer = PlayerInputComponent.registerActionEvents
F201Boot.nativeVehicle = InputBinding.endActionEventsModification
