local isSilent = true
--@debug@
isSilent = false
--@end-debug@

local L = LibStub("AceLocale-3.0"):NewLocale("MagicPrey", "enUS", true, isSilent)

-- State labels
L["Cold"] = true
L["Warm"] = true
L["Hot!"] = true
L["Found!"] = true
L["Away"] = true

-- LDB display
L["No Hunt"] = true
L["Prey"] = true

-- Options: General
L["Magic Prey"] = true
L["Magic Prey is a LibDataBroker data source. It requires an LDB display addon such as Button Bin, ChocolateBar, or Titan Panel to show hunt status."] = true
L["Magic Prey displays hunt status on the minimap button and any LibDataBroker display addon such as Button Bin, ChocolateBar, or Titan Panel."] = true
L["Hide minimap button"] = true
L["Hide the minimap button. The addon is still accessible via LDB display addons."] = true
L["Hide built-in prey tracker"] = true
L["Hide the Blizzard prey tracker crystal widget from the top of the screen."] = true

-- Options: Colors
L["Colors"] = true
L["Customize the colors used for each hunt state in the LDB display and tooltip."] = true
L["Color for the Cold hunt state."] = true
L["Color for the Warm hunt state."] = true
L["Color for the Hot hunt state."] = true
L["Color for the Found/Final hunt state."] = true
L["Color shown when you have an active hunt but are not in the hunt zone."] = true
L["Found"] = true

-- Options: Profiles
L["Profiles"] = true

-- Tooltip
L["Prey Hunt"] = true
L["Hunt active in %s"] = true
L["Hunt active - not in hunt zone"] = true
L["State: %s"] = true
L["No active prey hunt"] = true
L["Left-click: Open World Map"] = true
L["Right-click: Options"] = true
