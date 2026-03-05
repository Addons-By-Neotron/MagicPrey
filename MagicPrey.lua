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

local LDB = LibStub("LibDataBroker-1.1")

local mod = LibStub("AceAddon-3.0"):NewAddon("MagicPrey", "AceEvent-3.0", "AceTimer-3.0", "AceConsole-3.0")

LibStub("LibLogger-1.0"):Embed(mod)

-- Upvalues
local C_UIWidgetManager = C_UIWidgetManager
local C_QuestLog = C_QuestLog
local GetQuestUiMapID = C_TaskQuest and C_TaskQuest.GetQuestZoneID or QuestUtil and QuestUtil.GetQuestMapID
local OpenWorldMap = OpenWorldMap
local fmt = string.format

-- State
local preyWidgetID = nil
local currentState = nil -- nil, "Cold", "Warm", "Hot", "Final"
local currentQuestID = nil
local currentQuestName = nil
local tooltipText = nil
local preyModifiers = {} -- { {name, icon, description}, ... }

-- State display configuration
local STATE_DISPLAY = {
	Cold  = "|cff6688ccCold|r",
	Warm  = "|cffff8800Warm|r",
	Hot   = "|cffff0000Hot!|r",
	Final = "|cff00ff00Found!|r",
}

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
local dataobj = LDB:NewDataObject("Magic Prey", {
	type = "data source",
	icon = DEFAULT_ICON,
	iconCoords = DEFAULT_ICON_COORDS,
	label = "Prey",
	text = "No Hunt",
	OnClick = function(_, button)
		if button == "LeftButton" then
			mod:OnLeftClick()
		end
	end,
	OnTooltipShow = function(tooltip)
		mod:OnTooltipShow(tooltip)
	end,
})

-- Widget scanning: search known widget sets for PreyHuntProgress widgets
function mod:ScanForPreyWidget()
	preyWidgetID = nil

	local widgetSetIDs = {}
	local topCenter = C_UIWidgetManager.GetTopCenterWidgetSetID()
	if topCenter then widgetSetIDs[#widgetSetIDs + 1] = topCenter end
	local belowMinimap = C_UIWidgetManager.GetBelowMinimapWidgetSetID()
	if belowMinimap then widgetSetIDs[#widgetSetIDs + 1] = belowMinimap end
	local objectiveTracker = C_UIWidgetManager.GetObjectiveTrackerWidgetSetID()
	if objectiveTracker then widgetSetIDs[#widgetSetIDs + 1] = objectiveTracker end

	-- Also check the power bar widget set
	local powerBar = C_UIWidgetManager.GetPowerBarWidgetSetID and C_UIWidgetManager.GetPowerBarWidgetSetID()
	if powerBar then widgetSetIDs[#widgetSetIDs + 1] = powerBar end

	local targetType = Enum.UIWidgetVisualizationType.PreyHuntProgress

	for _, setID in ipairs(widgetSetIDs) do
		local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(setID)
		if widgets then
			for _, widgetInfo in ipairs(widgets) do
				if widgetInfo.widgetType == targetType then
					preyWidgetID = widgetInfo.widgetID
					return true
				end
			end
		end
	end

	return false
end

-- Scan player debuffs for prey modifiers (torments/affixes)
-- Only called out of combat; results cached until hunt ends

function mod:ScanPreyModifiers()
	if InCombatLockdown() then return end
	if IsInInstance() then return end

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

-- Update state from the prey widget
function mod:UpdatePreyState()
	-- Check for active prey quest
	local questID = C_QuestLog.GetActivePreyQuest and C_QuestLog.GetActivePreyQuest()
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
		currentState = nil
		tooltipText = nil
		self:UpdateDisplay()
		return
	end

	-- Try to get widget info
	if preyWidgetID then
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


		else
			-- Widget not showing, maybe hunt ended
			if not currentQuestID then
				currentState = nil
				tooltipText = nil
			end
		end
	else
		-- No widget found yet, but we have a quest - try scanning
		if currentQuestID then
			self:ScanForPreyWidget()
			if preyWidgetID then
				-- Retry now that we found it
				self:UpdatePreyState()
				return
			else
				-- Have quest but no widget yet
				currentState = "Cold"
				tooltipText = nil
			end
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
	if currentState and STATE_DISPLAY[currentState] then
		dataobj.text = STATE_DISPLAY[currentState]
		dataobj.label = currentQuestName or "Prey"
		dataobj.icon = currentIcon
		dataobj.iconCoords = currentIconCoords
	else
		dataobj.text = "No Hunt"
		dataobj.label = "Prey"
		dataobj.icon = DEFAULT_ICON
		dataobj.iconCoords = DEFAULT_ICON_COORDS
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

-- Tooltip handler
function mod:OnTooltipShow(tooltip)
	tooltip:AddLine(currentQuestName or "Prey Hunt", 1, 1, 1)

	if currentState then
		local stateColor = {
			Cold  = { 0.4, 0.53, 0.8 },
			Warm  = { 1, 0.53, 0 },
			Hot   = { 1, 0, 0 },
			Final = { 0, 1, 0 },
		}
		local c = stateColor[currentState] or { 1, 1, 1 }
		tooltip:AddLine(fmt("State: %s", currentState), c[1], c[2], c[3])
	else
		tooltip:AddLine("No active prey hunt", 0.5, 0.5, 0.5)
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
	tooltip:AddLine("Left-click: Open World Map", 0.5, 0.5, 0.5)
end

-- AceAddon lifecycle
function mod:OnInitialize()
end

function mod:OnEnable()
	self:RegisterEvent("UPDATE_UI_WIDGET")
	self:RegisterEvent("UPDATE_ALL_UI_WIDGETS")
	self:RegisterEvent("QUEST_ACCEPTED")
	self:RegisterEvent("QUEST_REMOVED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")

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
	if preyWidgetID and widgetInfo.widgetID == preyWidgetID then
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
	if currentQuestID and currentQuestID == questID then
		preyWidgetID = nil
		currentQuestID = nil
		currentQuestName = nil
		currentState = nil
		tooltipText = nil
		preyModifiers = {}
		self:UpdateDisplay()
	end
end

function mod:PLAYER_REGEN_ENABLED()
	if currentQuestID then
		self:ScanPreyModifiers()
	end
end

function mod:PLAYER_ENTERING_WORLD()
	self:ScheduleTimer("InitialScan", 3)
end
