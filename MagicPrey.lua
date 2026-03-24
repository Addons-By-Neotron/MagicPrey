--[[
**********************************************************************
MagicPrey - Prey Hunt Tracker (LDB Data Source)
**********************************************************************
This file is part of MagicPrey, a World of Warcraft Addon

MagicPrey is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

MagicPrey is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details.
**********************************************************************
]]

local L = LibStub("AceLocale-3.0"):GetLocale("MagicPrey")
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0", true)
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfig-3.0")

local mod = LibStub("AceAddon-3.0"):NewAddon("MagicPrey", "AceEvent-3.0", "AceTimer-3.0", "AceConsole-3.0", "LibMagicUtil-1.0")
MagicPrey = mod
LibStub("LibLogger-1.0"):Embed(mod)

local C_Map = C_Map
local C_QuestLog = C_QuestLog
local C_Spell = C_Spell
local C_TaskQuest = C_TaskQuest
local C_Texture = C_Texture
local C_TooltipInfo = C_TooltipInfo
local C_UIWidgetManager = C_UIWidgetManager
local C_UnitAuras = C_UnitAuras
local Enum = Enum
local EventRegistry = EventRegistry
local InCombatLockdown = InCombatLockdown
local IsInInstance = IsInInstance
local OpenWorldMap = OpenWorldMap
local GetQuestUiMapID = C_TaskQuest and C_TaskQuest.GetQuestZoneID or QuestUtil and QuestUtil.GetQuestMapID
local fmt = string.format

-- State
local preyWidgetID = nil
local currentState = nil -- nil, "Cold", "Warm", "Hot", "Final"
local currentQuestID = nil
local currentQuestName = nil
local currentHuntZone = nil -- zone name when away from hunt
local tooltipText = nil
local preyModifiers = {} -- { {name, icon, description}, ... }
local hiddenWidgetFrames = {} -- frames we've hidden for the Blizzard tracker

-- AceDB defaults
local defaults = {
	profile = {
		colors = {
			Cold  = { 0.4, 0.53, 0.8, 1 },
			Warm  = { 1, 0.53, 0, 1 },
			Hot   = { 1, 0, 0, 1 },
			Final = { 0, 1, 0, 1 },
			Away  = { 0.6, 0.6, 0.6, 1 },
		},
		hideBlizzardTracker = false,
		minimapIcon = { hide = false },
	},
	char = {
		lastHuntQuestID = nil,
		lastHuntZone = nil,
	}
}

-- State display labels (without color)
local STATE_LABELS = {
	Cold  = L["Cold"],
	Warm  = L["Warm"],
	Hot   = L["Hot!"],
	Final = L["Found!"],
	Away  = L["Away"],
}

-- convert color table {r,g,b,a} to hex string
local function ColorToHex(c)
	return fmt("%02x%02x%02x", c[1]*255, c[2]*255, c[3]*255)
end

-- Build colored state text from profile colors
local function GetStateText(state)
	if not state or not STATE_LABELS[state] then return nil end
	local c = mod.db and mod.db.profile.colors[state]
	if not c then return STATE_LABELS[state] end
	return fmt("|cff%s%s|r", ColorToHex(c), STATE_LABELS[state])
end

-- Resolve default icon from atlas
local DEFAULT_ICON = "Interface\\Icons\\Tracking_WildPet"
local DEFAULT_ICON_COORDS = nil
do
	local atlasInfo = C_Texture.GetAtlasInfo("UI-prey-Scoutingmap")
	if atlasInfo and atlasInfo.file then
		DEFAULT_ICON = atlasInfo.file
		DEFAULT_ICON_COORDS = { atlasInfo.leftTexCoord, atlasInfo.rightTexCoord, atlasInfo.topTexCoord, atlasInfo.bottomTexCoord }
	end
end
local currentIcon = DEFAULT_ICON
local currentIconCoords = DEFAULT_ICON_COORDS

-- LDB data object
local dataObj = LDB:NewDataObject("Magic Prey", {
	type = "data source",
	icon = DEFAULT_ICON,
	iconCoords = DEFAULT_ICON_COORDS,
	label = L["Prey"],
	text = L["No Hunt"],
	OnClick = function(_, button)
		if button == "LeftButton" then
			mod:OnLeftClick()
		elseif button == "RightButton" then
			mod:OnRightClick()
		end
	end,
	OnTooltipShow = function(tooltip)
		mod:OnTooltipShow(tooltip)
	end,
})

-- Widget scanning: prey widget lives in the PowerBar widget set
function mod:ScanForPreyWidget()
	preyWidgetID = nil

	local setID = C_UIWidgetManager.GetPowerBarWidgetSetID and C_UIWidgetManager.GetPowerBarWidgetSetID()
	if not setID then return false end

	local targetType = Enum.UIWidgetVisualizationType.PreyHuntProgress
	local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(setID)
	if widgets then
		for _, widgetInfo in ipairs(widgets) do
			if widgetInfo.widgetType == targetType then
				preyWidgetID = widgetInfo.widgetID
 			    self:debug("Found prey widget %d in PowerBar set %d", widgetInfo.widgetID, setID)
				return true
			end
		end
	end

	return false
end

-- Scan player debuffs for prey modifiers (torments/affixes)
-- Only called out of combat; results cached until hunt ends

function mod:ScanPreyModifiers()
	if InCombatLockdown() or IsInInstance() then return end

	preyModifiers = {}
	if not currentQuestID then return end

	for i = 1, 40 do
		local auraData = C_UnitAuras.GetDebuffDataByIndex("player", i)
		if not auraData then break end

		local desc = C_Spell.GetSpellDescription(auraData.spellId) or ""
		local name = auraData.name or ""
		if (desc:find("Torment") or name == "Torment") and auraData.duration == 0 then
			-- Extract modifier details from tooltip lines
			local tooltipData = C_TooltipInfo.GetUnitDebuff("player", i)
			local modifierText = nil
			if tooltipData and tooltipData.lines then
				for j = 2, #tooltipData.lines do
					local text = tooltipData.lines[j].leftText
					if text and text ~= "" then
						text = text:gsub("|[Cc]%x%x%x%x%x%x%x%x", ""):gsub("|[Rr]", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
						text = text:match("^%s*(.-)%s*$")
						if text ~= "" then
							modifierText = text
						end
					end
				end
			end

			preyModifiers[#preyModifiers + 1] = {
				name = auraData.name,
				icon = auraData.icon,
				tooltipText = modifierText,
				spellId = auraData.spellId,
				stacks = auraData.applications or 0,
			}
		end
	end

end



-- Scan zone-level world quests on the player's current continent for a "Prey: ..." quest.
-- Returns the zone name string if found, nil otherwise.
function mod:FindPreyWorldQuestZone()
	if not (C_TaskQuest and C_TaskQuest.GetQuestsOnMap and C_TaskQuest.GetQuestZoneID) then return nil end

	-- Walk up to continent level from player's position
	local contMapID
	local playerMap = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local cur = playerMap
	while cur do
		local info = C_Map.GetMapInfo(cur)
		if not info then break end
		if info.mapType == Enum.UIMapType.Continent then
			contMapID = cur
			break
		end
		cur = info.parentMapID
	end
	if not contMapID then return nil end

	local zones = C_Map.GetMapChildrenInfo and C_Map.GetMapChildrenInfo(contMapID, Enum.UIMapType.Zone, true)
	if not zones then return nil end

	for _, zoneInfo in ipairs(zones) do
		local quests = C_TaskQuest.GetQuestsOnMap(zoneInfo.mapID)
		if quests then
			for _, questInfo in ipairs(quests) do
				local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questInfo.questID)
				if title and title:find("^Prey") then
					self:debug("Found Prey world quest %d (%s) in zone %s", questInfo.questID, title, zoneInfo.name)
					return zoneInfo.name
				end
			end
		end
	end
	return nil
end

-- Update state from the prey widget
function mod:UpdatePreyState()
	-- Check for active prey quest
	local questID = C_QuestLog.GetActivePreyQuest and C_QuestLog.GetActivePreyQuest()
	local isOutOfZone = false
	if questID and questID > 0 then
		currentQuestID = questID
		local questInfo = C_QuestLog.GetQuestInfo and C_QuestLog.GetQuestInfo(questID)
		if type(questInfo) == "table" then
			currentQuestName = questInfo.title or questInfo.questTitle
		elseif type(questInfo) == "string" then
			currentQuestName = questInfo
		else
			currentQuestName = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
		end
	else
		currentQuestID = nil
		currentQuestName = nil
		currentHuntZone = nil
		currentState = nil
		tooltipText = nil
		self:ApplyBlizzardTrackerVisibility()
		self:UpdateDisplay()
		return
	end

	-- Determine if we're out of zone: either fallback found it, or we have quest but no widget
	if not isOutOfZone and preyWidgetID then
		local info = C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo(preyWidgetID)
		if not info or info.shownState ~= 1 then
			isOutOfZone = true
		end
	elseif not isOutOfZone and not preyWidgetID then
		-- Have quest from GetActivePreyQuest but no widget found
		self:ScanForPreyWidget()
		if not preyWidgetID then
			isOutOfZone = true
		end
	end

	if isOutOfZone then
		currentState = "Away"
		tooltipText = nil
		-- Load persisted per-character zone (cached while in hunt zone)
		if not currentHuntZone and self.db and self.db.char.lastHuntQuestID == currentQuestID then
			currentHuntZone = self.db.char.lastHuntZone
		end
		-- Detect zone by finding the companion "Prey: ..." world quest
		if not currentHuntZone then
			currentHuntZone = self:FindPreyWorldQuestZone()
		end
		currentIcon = DEFAULT_ICON
		currentIconCoords = DEFAULT_ICON_COORDS
		self:debug("Out of zone: quest=%s zone=%s", tostring(currentQuestName), tostring(currentHuntZone))
		self:UpdateDisplay()
		return
	end

	-- In zone with active widget — read hunt state
	local info = C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo(preyWidgetID)
	if info and info.shownState == 1 then
		local progressState = info.progressState

		-- Map progressState enum to our state names
		if progressState == Enum.PreyHuntProgressState.Final or progressState == Enum.PreyHuntProgressState.Found then
			currentState = "Final"
		elseif progressState == Enum.PreyHuntProgressState.Hot then
			currentState = "Hot"
		elseif progressState == Enum.PreyHuntProgressState.Warm then
			currentState = "Warm"
		else
			currentState = "Cold"
		end

		tooltipText = info.tooltip

		-- Resolve icon from PreyIndicator atlas per state
		local stateAtlas = {
			Cold = "threatindicator-cold", Warm = "threatindicator-warm",
			Hot = "threatindicator-hot", Final = "UI-prey-targeticon-Final",
		}
		local atlasName = stateAtlas[currentState]
		if atlasName then
			local atlasInfo = C_Texture.GetAtlasInfo(atlasName)
			if atlasInfo and atlasInfo.file then
				currentIcon = atlasInfo.file
				currentIconCoords = { atlasInfo.leftTexCoord, atlasInfo.rightTexCoord, atlasInfo.topTexCoord, atlasInfo.bottomTexCoord }
			end
		end

		self:ApplyBlizzardTrackerVisibility()

		-- Cache the zone name while we're in the hunt zone
		-- Walk up from subzone to find the Zone-level map
		local playerMap = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
		while playerMap do
			local mapInfo = C_Map.GetMapInfo(playerMap)
			if not mapInfo then break end
			if mapInfo.mapType == Enum.UIMapType.Zone then
				currentHuntZone = mapInfo.name
				if mod.db then
					mod.db.char.lastHuntQuestID = currentQuestID
					mod.db.char.lastHuntZone = mapInfo.name
				end
				break
			end
			playerMap = mapInfo.parentMapID
		end
	end

	-- Scan modifiers: immediately if out of combat, otherwise deferred to regen
	if currentQuestID and not InCombatLockdown() then
		self:ScanPreyModifiers()
	end
	self:UpdateDisplay()
end

-- Update the LDB display
function mod:UpdateDisplay()
	local stateText = GetStateText(currentState)
	if stateText then
		if currentState == "Away" and currentHuntZone then
			dataObj.text = fmt("%s (%s)", stateText, currentHuntZone)
		else
			dataObj.text = stateText
		end
		dataObj.label = currentQuestName or L["Prey"]
		dataObj.icon = currentIcon
		dataObj.iconCoords = currentIconCoords
	else
		dataObj.text = L["No Hunt"]
		dataObj.label = L["Prey"]
		dataObj.icon = DEFAULT_ICON
		dataObj.iconCoords = DEFAULT_ICON_COORDS
		currentIcon = DEFAULT_ICON
		currentIconCoords = DEFAULT_ICON_COORDS
	end
end

-- Left click handler: open world map to prey quest
function mod:OnLeftClick()
	if not currentQuestID then return end

	local mapID
	if C_TaskQuest and C_TaskQuest.GetQuestZoneID then
		mapID = C_TaskQuest.GetQuestZoneID(currentQuestID)
	end
	if not mapID or mapID == 0 then
		mapID = GetQuestUiMapID and GetQuestUiMapID(currentQuestID, true)
	end
	if not mapID or mapID == 0 then
		mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	end

	if mapID and mapID > 0 then
		OpenWorldMap(mapID)
		if EventRegistry then
			EventRegistry:TriggerEvent("MapCanvas.PingQuestID", currentQuestID)
		end
	end
end

-- Right click handler: open config in Blizzard settings
function mod:OnRightClick()
	self:InterfaceOptionsFrame_OpenToCategory(self.optionsEnd)
	self:InterfaceOptionsFrame_OpenToCategory(self.optionsMain)
end

-- Tooltip handler
function mod:OnTooltipShow(tooltip)
	tooltip:AddLine(currentQuestName or L["Prey Hunt"], 1, 1, 1)

	if currentState then
		local c = self.db and self.db.profile.colors[currentState] or { 1, 1, 1, 1 }
		if currentState == "Away" then
			if currentHuntZone then
				tooltip:AddLine(fmt(L["Hunt active in %s"], currentHuntZone), c[1], c[2], c[3])
			else
				tooltip:AddLine(L["Hunt active - not in hunt zone"], c[1], c[2], c[3])
			end
		else
			tooltip:AddLine(fmt(L["State: %s"], currentState), c[1], c[2], c[3])
		end
	else
		tooltip:AddLine(L["No active prey hunt"], 0.5, 0.5, 0.5)
	end

	if tooltipText and tooltipText ~= "" then
		tooltip:AddLine(" ")
		tooltip:AddLine(tooltipText, 1, 1, 1, true)
	end

	if #preyModifiers > 0 then
		tooltip:AddLine(" ")
		for _, m in ipairs(preyModifiers) do
			-- Header: debuff name with stack count
			local header = m.name
			if m.stacks and m.stacks > 0 then
				header = fmt("%s (x%d)", header, m.stacks)
			end
			tooltip:AddLine(header, 1, 0.82, 0)

			-- Body: parse modifier entries (each starts with "- Name")
			if m.tooltipText then
				-- Split on "- " at start of line to get individual modifiers
				for block in m.tooltipText:gmatch("%-?%s*([^\n].-\n[^%-]*)") do
					local title, desc = block:match("^(.-)%\n(.+)$")
					if title and desc then
						title = title:match("^%s*(.-)%s*$")
						desc = desc:match("^%s*(.-)%s*$")
						if title ~= "" then
							tooltip:AddLine("- " .. title, 1, 0.4, 0.4)
						end
						if desc ~= "" then
							tooltip:AddLine(desc, 0.8, 0.8, 0.8, true)
						end
					else
						block = block:match("^%s*(.-)%s*$")
						if block ~= "" then
							tooltip:AddLine(block, 0.8, 0.8, 0.8, true)
						end
					end
				end
			end
		end
	end

	tooltip:AddLine(" ")
	tooltip:AddLine(L["Left-click: Open World Map"], 0.5, 0.5, 0.5)
	tooltip:AddLine(L["Right-click: Options"], 0.5, 0.5, 0.5)
end

-- Hide/show Blizzard's built-in prey tracker widget
-- Find the prey widget frame in the PowerBar (Encounter Bar) container
local function FindPreyWidgetFrame()
	if not preyWidgetID then return nil end
	local container = UIWidgetPowerBarContainerFrame
	if not container then return nil end

	local children = { container:GetChildren() }
	for _, child in ipairs(children) do
		if child.widgetID and child.widgetID == preyWidgetID then
			return child
		end
	end
	return nil
end

function mod:ApplyBlizzardTrackerVisibility()
	local shouldHide = self.db and self.db.profile.hideBlizzardTracker and preyWidgetID
	local frame = FindPreyWidgetFrame()
	if not frame then return end

	if shouldHide then
		local container = UIWidgetPowerBarContainerFrame
		-- Hide the prey frame and any sibling frames (e.g. glow overlays for Final state)
		local toHide = { frame }
		if container then
			for _, child in ipairs({ container:GetChildren() }) do
				if child ~= frame and child:IsShown() then
					toHide[#toHide + 1] = child
				end
			end
		end
		for _, f in ipairs(toHide) do
			f:Hide()
			f:SetScript("OnShow", function(self)
				if mod.db and mod.db.profile.hideBlizzardTracker then
					self:Hide()
				end
			end)
			hiddenWidgetFrames[f] = true
		end
	else
		if hiddenWidgetFrames[frame] then
			for f in pairs(hiddenWidgetFrames) do
				f:SetScript("OnShow", nil)
				f:Show()
			end
			hiddenWidgetFrames = {}
		end
	end
end

-- Restore all hidden widget frames
function mod:RestoreBlizzardTracker()
	for frame in pairs(hiddenWidgetFrames) do
		frame:SetScript("OnShow", nil)
		frame:Show()
	end
	hiddenWidgetFrames = {}
end

-- Profile change handler
function mod:ApplySettings()
	self:ApplyBlizzardTrackerVisibility()
	if LDBIcon then
		LDBIcon:Refresh("Magic Prey", self.db.profile.minimapIcon)
	end
	self:UpdateDisplay()
end

-- Options helper: register a table, optionally as a subcategory of "Magic Prey"
function mod:OptReg(optname, tbl, dispname)
	if dispname then
		optname = "Magic Prey" .. optname
		AceConfigRegistry:RegisterOptionsTable(optname, tbl)
		return AceConfigDialog:AddToBlizOptions(optname, dispname, "Magic Prey")
	else
		AceConfigRegistry:RegisterOptionsTable(optname, tbl)
		return AceConfigDialog:AddToBlizOptions(optname, "Magic Prey")
	end
end

-- Option tables (built in OnInitialize after db is ready)
local options = {}

local function BuildOptions()
	options.general = {
		type = "group",
		name = L["Magic Prey"],
		args = {
			ldbNote = {
				type = "description",
				name = function()
					if LDBIcon then
						return L["Magic Prey displays hunt status on the minimap button and any LibDataBroker display addon such as Button Bin, ChocolateBar, or Titan Panel."]
					else
						return L["Magic Prey is a LibDataBroker data source. It requires an LDB display addon such as Button Bin, ChocolateBar, or Titan Panel to show hunt status."]
					end
				end,
				order = 0,
				fontSize = "medium",
			},
			hideMinimapButton = {
				type = "toggle",
				name = L["Hide minimap button"],
				desc = L["Hide the minimap button. The addon is still accessible via LDB display addons."],
				width = "full",
				order = 1,
				get = function() return mod.db.profile.minimapIcon.hide end,
				set = function(_, val)
					mod.db.profile.minimapIcon.hide = val
					if LDBIcon then
						LDBIcon:Refresh("Magic Prey", mod.db.profile.minimapIcon)
					end
				end,
				hidden = function() return not LDBIcon end,
			},
			hideBlizzardTracker = {
				type = "toggle",
				name = L["Hide built-in prey tracker"],
				desc = L["Hide the Blizzard prey tracker crystal widget from the top of the screen."],
				width = "full",
				order = 2,
				get = function() return mod.db.profile.hideBlizzardTracker end,
				set = function(_, val)
					mod.db.profile.hideBlizzardTracker = val
					mod:ApplyBlizzardTrackerVisibility()
				end,
			},
		},
	}

	options.colors = {
		type = "group",
		name = L["Colors"],
		args = {
			desc = {
				type = "description",
				name = L["Customize the colors used for each hunt state in the LDB display and tooltip."],
				order = 0,
			},
			Cold = {
				type = "color",
				name = L["Cold"],
				desc = L["Color for the Cold hunt state."],
				hasAlpha = true,
				order = 1,
				get = function()
					local c = mod.db.profile.colors.Cold
					return c[1], c[2], c[3], c[4]
				end,
				set = function(_, r, g, b, a)
					mod.db.profile.colors.Cold = { r, g, b, a }
					mod:UpdateDisplay()
				end,
			},
			Warm = {
				type = "color",
				name = L["Warm"],
				desc = L["Color for the Warm hunt state."],
				hasAlpha = true,
				order = 2,
				get = function()
					local c = mod.db.profile.colors.Warm
					return c[1], c[2], c[3], c[4]
				end,
				set = function(_, r, g, b, a)
					mod.db.profile.colors.Warm = { r, g, b, a }
					mod:UpdateDisplay()
				end,
			},
			Hot = {
				type = "color",
				name = L["Hot!"],
				desc = L["Color for the Hot hunt state."],
				hasAlpha = true,
				order = 3,
				get = function()
					local c = mod.db.profile.colors.Hot
					return c[1], c[2], c[3], c[4]
				end,
				set = function(_, r, g, b, a)
					mod.db.profile.colors.Hot = { r, g, b, a }
					mod:UpdateDisplay()
				end,
			},
			Final = {
				type = "color",
				name = L["Found"],
				desc = L["Color for the Found/Final hunt state."],
				hasAlpha = true,
				order = 4,
				get = function()
					local c = mod.db.profile.colors.Final
					return c[1], c[2], c[3], c[4]
				end,
				set = function(_, r, g, b, a)
					mod.db.profile.colors.Final = { r, g, b, a }
					mod:UpdateDisplay()
				end,
			},
			Away = {
				type = "color",
				name = L["Away"],
				desc = L["Color shown when you have an active hunt but are not in the hunt zone."],
				hasAlpha = true,
				order = 5,
				get = function()
					local c = mod.db.profile.colors.Away
					return c[1], c[2], c[3], c[4]
				end,
				set = function(_, r, g, b, a)
					mod.db.profile.colors.Away = { r, g, b, a }
					mod:UpdateDisplay()
				end,
			},
		},
	}

	options.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(mod.db)
end

-- AceAddon lifecycle
function mod:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("MagicPreyDB", defaults, "Default")
	self.db.RegisterCallback(self, "OnProfileChanged", "ApplySettings")
	self.db.RegisterCallback(self, "OnProfileCopied", "ApplySettings")
	self.db.RegisterCallback(self, "OnProfileReset", "ApplySettings")
	-- self:SetLogLevel(self.logLevels.DEBUG)
	if LDBIcon then
		LDBIcon:Register("Magic Prey", dataObj, self.db.profile.minimapIcon)
	end

	BuildOptions()

	-- Register parent category, then subcategories
	self.optionsMain = self:OptReg("Magic Prey", options.general)
	self:OptReg(": Colors", options.colors, L["Colors"])
	self.optionsEnd = self:OptReg(": Profiles", options.profiles, L["Profiles"])
end

function mod:OnEnable()
	self:RegisterEvent("UPDATE_UI_WIDGET")
	self:RegisterEvent("UPDATE_ALL_UI_WIDGETS")
	self:RegisterEvent("QUEST_ACCEPTED")
	self:RegisterEvent("QUEST_REMOVED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	self:RegisterEvent("UNIT_AURA")

	-- Initial scan after a short delay to let widgets load
	self:ScheduleTimer("InitialScan", 2)
end

function mod:InitialScan()
	self:ScanForPreyWidget()
	self:UpdatePreyState()
end

function mod:UPDATE_UI_WIDGET(_, widgetInfo)
	if not widgetInfo then return end
	-- If it's our tracked widget, update
	if widgetInfo.widgetID == preyWidgetID then
		self:UpdatePreyState()
	elseif widgetInfo.widgetType == Enum.UIWidgetVisualizationType.PreyHuntProgress then
		-- Might be a new prey widget
		self:ScanForPreyWidget()
		self:UpdatePreyState()
	end
end

function mod:UPDATE_ALL_UI_WIDGETS()
	self:ScanForPreyWidget()
	self:UpdatePreyState()
end

function mod:QUEST_ACCEPTED(_, questID)
	-- Check if this is a prey quest
	if C_QuestLog.GetActivePreyQuest then
		local preyQuest = C_QuestLog.GetActivePreyQuest()
		if preyQuest and preyQuest == questID then
			self:ScheduleTimer("InitialScan", 1)
		end
	end
end

function mod:QUEST_REMOVED(_, questID)
	if currentQuestID == questID then
		preyWidgetID = nil
		currentQuestID = nil
		currentQuestName = nil
		currentHuntZone = nil
		if self.db then
			self.db.char.lastHuntQuestID = nil
			self.db.char.lastHuntZone = nil
		end
		currentState = nil
		tooltipText = nil
		preyModifiers = {}
		-- Clear OnShow scripts but don't force-show frames: Blizzard will hide the widget
		-- naturally as the hunt ends. Force-showing caused a flash of the crystal on kill.
		for frame in pairs(hiddenWidgetFrames) do
			frame:SetScript("OnShow", nil)
		end
		hiddenWidgetFrames = {}
		self:UpdateDisplay()
	end
end

function mod:PLAYER_REGEN_ENABLED()
	if currentQuestID then
		self:ScanPreyModifiers()
	end
end

function mod:UNIT_AURA(_, unit)
	if unit ~= "player" or not currentQuestID or InCombatLockdown() then return end
	self:ScanPreyModifiers()
end

function mod:PLAYER_ENTERING_WORLD()
	self:ScheduleTimer("InitialScan", 3)
end
