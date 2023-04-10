-----------------------------------------------------------------------------
--  World of Warcraft addon to: 
--	1.	Investigate problems with hunter pet detection
--	2.	...
--
--  (c) March 2023 Duncan Baxter
--
--  License: All available rights reserved to the author
-----------------------------------------------------------------------------
-- SECTION 1: Constant/Variable definitions
-----------------------------------------------------------------------------
-- Define some local "constants" (WoW uses Lua 5.1 which does not include 5.4's <const> attribute)
local addonName = "Pets"

-- Lua forward definitions for the parent frames
local pet -- Pet information frame
local info -- Enemies information frame

-- Define the various pet states (the Texture and FontString attributes .tex and .fs are populated in Section 4)
local ALIVE, EXISTS, NO_DEBUFF, HEALTHY = 1, 2, 3, 4 -- Lua "enumeration" to access arbitrary records in the state table
local shown = 1 -- Record currently shown on icon (defaults to highest priority if the other states are all OK)

local state = {} -- "false" indicates a problem, record sequence reflects descending order of priority
	state[ALIVE] = { tex, fs, icon = 237274, status = true, txt = {} }
	state[ALIVE].txt[true] = "Alive"
	state[ALIVE].txt[false] = "Dead"
	state[EXISTS] = { tex, fs, icon = 1386549, status = true, txt = {} }
	state[EXISTS].txt[true] = "Exists"
	state[EXISTS].txt[false] = "Does not exist"
	state[NO_DEBUFF] = { tex, fs, icon = 135739, status = true, txt = {} }
	state[NO_DEBUFF].txt[true] = "No debuffs"
	state[NO_DEBUFF].txt[false] = " debuff" -- Replaced by (Dispel Type .. " debuff") if there is a problem
	state[HEALTHY] = { tex, fs, icon = 237586, status = true, txt = {}, health = 0 , maxHealth = 0}
	state[HEALTHY].txt[true] = "Healthy"
	state[HEALTHY].txt[false] = "Injured"

-- Define the other major tables
local petEvents = {} -- Table of system events that we monitor
local infoEvents = {} -- Table of system events that we monitor
local slots = {} -- List of displayed nameplates (keyed by slot from left to right), stored as indexes to the links list
local links = {} -- List of nameplates (keyed by nameplate number), stored as indexes to the slots list (except -1 (invalid nameplate) and 0 (not displayed))

-- Collect some text strings into a handy table
local text = {
	txtTooltip = addonName .. ":\nWhat a lovely tooltip!",
	txtLoaded = addonName .. ": Addon has loaded.",
	txtLogout = addonName .. ": Time for a break ...",
}

-----------------------------------------------------------------------------
-- SECTION 1.1: Debugging utilities (remove before release)
-----------------------------------------------------------------------------
-- Debugging function to recursively print the contents of a table (eg. a frame)
local function dumpTable(tbl, p) -- Parameters are the table(tbl) and (optionally) a prefix to indicate the recursion level (p)
	p = tostring(p or ".") -- If no prefix is provided then set it to "."
	for k, v in pairs(tbl) do 
		print(p, k, " = ", v) -- Each recursion level is indented (by p) relative to the level that called it
		if (type(v) == "table") then 
			dumpTable(v, p .. k .. ".")
		end
	end
end

-- Research function to print the spellbook
local function dumpSpellbook()
	print("Unit exists: ", tostring(UnitExists("pet")))
	print("Override spell for Revive Pet: ", C_SpellBook.GetOverrideSpell(982))

	for i = 1, GetNumSpellTabs() do
		local _, _, offset, numSlots = GetSpellTabInfo(i)
		for j = offset + 1, offset + numSlots do
			local spellType, id = GetSpellBookItemInfo(j, BOOKTYPE_SPELL)
			if (spellType == "FLYOUT") then 
				local name, description, numSlots, flyoutIsKnown = GetFlyoutInfo(id)
				print(format("[%s:%d (%s)] %s (%d slots) -%s-", spellType, id, name, description, numSlots, tostring(flyoutIsKnown)))
				for k = 1, numSlots do
					local flyoutSpellID, overrideSpellID, spellIsKnown, spellName, slotSpecID = GetFlyoutSlotInfo(id, k)
					print(format("[%s:%d.%d] %s/%s (%s) -%s-", name, id, slotSpecID, flyoutSpellID, overrideSpellID, spellName, tostring(spellIsKnown)))
				end
			end
		end
	end
end

-- Research function to print the pet spellbook
local function dumpPetSpellbook()
local numPetSpells, petToken = HasPetSpells()
	if (numPetSpells == nil) then print("There is no pet spellbook.  You idiot.")
	else
		print("Number of pet spells:", numPetSpells)
		print("Pet token:", petToken)
		
		for i = 1, numPetSpells do
			local spellName, spellSubName, spellID = GetSpellBookItemName(i, BOOKTYPE_PET)
			if ((spellID ~= nil) and (spellSubName ~= "Passive")) then
				print("Index:", i)
				print("Name of spell:", spellName)  -- eg. "Dash"
				print("Type of spell:", spellSubName) -- eg. "Basic Ability" or "Pet Stance"
				print("Spell ID:", spellID) -- Don't need to apply the 0xFFFFFF mask like you do for GetSpellBookItemInfo
			end
		end
	end
end

-- Research function to print the metatable methods for an object
local function dumpMethods(object)
	if (object == nil) then print("Object does not exist")
	else
		local tbl = {}
		local meta = getmetatable(object).__index;
		if (meta == nil) then print("Object does not have a metatable")
		else
			for k, v in pairs(meta) do table.insert(tbl, format("%s: %s", type(v), k)) end
			table.sort(tbl)
			for _, v in ipairs(tbl) do print(v) end
		end
	end
end

-- Research function to recursively print the attributes and methods of an object
local function dumpAttributes(object, prefix)
	if (type(prefix) ~= "string") then prefix = "." end -- If no valid prefix is provided (ie. omitted or not a string) then initialise to "."
	if (type(object) == nil) then print("Object does not exist")
	else
		if (type(object) == "table") then 
			for k, v in pairs(object) do
				if (type(v) == "table") then dumpAttributes(v, format("%s%s.", prefix, k))
				else print(format("%s%s (%s) = %s", prefix, k, type(v), tostring(v or "N/a")))
				end
			end
		else print(format("%s(%s) ", prefix, type(object), tostring(object or "N/a")))
		end
	end
end

-----------------------------------------------------------------------------
-- SECTION 2: Create the parent frames
-----------------------------------------------------------------------------
--[[ Create an example secure-code unit frame
local function createSecure()
	local f = CreateFrame("Button", "secure", UIParent, "SecureUnitButtonTemplate")
	 
	-- Tell it which unit to represent (in this case "player":
	f:SetAttribute("unit", "player")
	 
	-- Tell the game to "look after it"
	RegisterUnitWatch(f) 
	 
	-- Give it the standard click actions:
	f:RegisterForClicks("AnyDown")
	f:SetAttribute("*type1", "target") -- Target unit on left click
	f:SetAttribute("*type2", "togglemenu") -- Toggle units menu on right click
	f:SetAttribute("*type3", "assist") -- On middle click, target the target of the clicked unit
	 
	-- Make it visible for testing purposes:
	f:SetPoint("CENTER", UIParent, "CENTER", 300, 100)
	f:SetSize(100, 100)
	f.texBg = f:CreateTexture(nil, "BACKGROUND", nil, -8) -- Sub-layers run from -8 to +7: -8 puts our background at the lowest level
	f.texBg:SetPoint("TOPLEFT")
	f.texBg:SetPoint("BOTTOMRIGHT")
	f.texBg:SetAtlas("spec-background", false)
	 
	-- Then add other objects (such as font strings and status bars), register events (such as UNIT_HEALTH), and add scripts to update the objects in response to the events.
end--]]

-- Create a frame for pet information
local function createPet()
	pet = CreateFrame("Frame", addonName, UIParent, "")

	pet.textHeight = 15 -- Height of text FontString
	pet.barHeight = pet.textHeight -- Height (thickness) of health bar
	pet.iconSize = 64 -- Use 64 x 64 icons
	pet.ringSize = 88 -- Use 80 x 80 portrait rings
	pet.barLength = pet.ringSize -- Length of health bar
	pet.gap = pet.iconSize / 4 -- Allow 1/4 of an icon as a margin around and between the icons
	pet.width = pet.iconSize + (pet.gap * 2) -- Allow horizontal space for a single column of icons and the Fontstring
	pet.height = pet.iconSize + pet.textHeight + pet.barHeight + (pet.gap * 3) -- Allow vertical space for up to 4 icons

	if (pet:GetNumPoints() == 0) then -- No existing location found so position frame at CENTER of screen and reset its size to the default
		pet:SetPoint("CENTER")
		pet:SetSize(pet.width, pet.height)
	end

	-- Set the background to an Atlas texture
	pet.texBg = pet:CreateTexture(nil, "BACKGROUND", nil, -8) -- Sub-layers run from -8 to +7: -8 puts our background at the lowest level
	pet.texBg:SetPoint("TOPLEFT")
	pet.texBg:SetSize(pet.width, pet.height)
	pet.texBg:SetAtlas("spec-background", false)
	pet.texBg:SetAlpha(0.75)

	-- Make the frame movable
	pet:SetMovable(true)
	pet:SetScript("OnMouseDown", function(self, button) self:StartMoving() end)
	pet:SetScript("OnMouseUp", function(self, button) self:StopMovingOrSizing() end)
	
	-- Display the mouseover tooltip
	pet:SetScript("OnEnter", function(self, motion)
		GameTooltip:SetOwner(self, "ANCHOR_PRESERVE") -- Keeps the tooltip text in its default position
		GameTooltip:AddLine(text.txtTooltip)
		GameTooltip:Show()
	end)
	pet:SetScript("OnLeave", function(self, motion) GameTooltip:Hide() end)

	-- Display the small Exit button (at top-right of frame)
	pet.exit = CreateFrame("Button", nil, pet, "UIPanelCloseButtonNoScripts") -- Button defined in SharedXML/SharedUIPanelTemplates.xml
	pet.exit:SetPoint("TOPRIGHT")
	pet.exit:SetSize(20, 20)
	pet.exit:SetScript("OnClick", function(self, button, down) pet:Hide() end)

	-- Set the parameters for the pet information containers
	local texX, texY = pet.gap, -pet.gap
	local ringX, ringY = texX + (pet.iconSize - pet.ringSize)/2, texY - (pet.iconSize - pet.ringSize)/2
	local fsX, fsY = 0, ringY - pet.ringSize
	local barX, barY = 0, fsY - pet.textHeight - (pet.gap/2)
	
	-- Create the "state" icons
	for i = 1, #state do
		local p = state[i]
		p.tex = pet:CreateTexture(nil, "ARTWORK", nil, -8) -- Draw icons on the lowest level of the ARTWORK layer
		p.tex:SetPoint("TOPLEFT", pet, "TOPLEFT", texX, texY)
		p.tex:SetSize(pet.iconSize, pet.iconSize)
		if (i == 1) then SetPortraitTexture(p.tex, "pet")
		else SetPortraitToTexture(p.tex, p.icon) end
		p.tex:Hide()
		
		-- Create Fontstring for a pet state name
		p.fs = pet:CreateFontString(nil, "ARTWORK", nil)
		p.fs:SetPoint("TOP", pet, "TOP", 0, fsY)
		p.fs:SetWidth(pet.width)
		p.fs:SetJustifyH("CENTER")
		p.fs:SetJustifyV("MIDDLE")
		p.fs:SetTextColor( 1.0, 1.0, 1.0, 1.0 )
		p.fs:SetFont("Fonts\\ARIALN.TTF", 12, "")
		p.fs:SetText(p.txt[true])
		p.fs:Hide()
	end

	-- Create icon for a portrait ring
	local ring = pet:CreateTexture(nil, "ARTWORK", nil, -7) -- Draw ring on the level just above the icons
	ring:SetPoint("TOPLEFT", pet, "TOPLEFT", ringX, ringY)
	ring:SetSize(pet.ringSize, pet.ringSize)
	ring:SetAtlas("auctionhouse-itemicon-border-artifact", false)

	-- Create the health bar
	pet.bar = CreateFrame("StatusBar", nil, pet)
	pet.bar:SetPoint("TOP", pet, "TOP", barX, barY)
	pet.bar:SetSize(pet.barLength, pet.barHeight)
	pet.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar", "ARTWORK", -7)
	pet.bar:SetStatusBarColor(0, 1, 0, 1)
end

-- Create a frame for unit information
local function createInfo()
	info = CreateFrame("Frame", "info", UIParent)

	info.textHeight = 24 -- Vertical space provided for unit name FontStrings
	info.numIcons = 5 -- Allow space for 5 icons
	info.iconSize = 64 -- Use 64 x 64 icons
	info.ringSize = 88 -- Use 88 x 88 portrait rings
	info.targetSize = 88 -- Use an 88 x 88 portrait ring to indicate the player's target
	info.gap = info.iconSize / 4 -- Allow 1/4 of an icon as a margin around and between the icons
	info.width = (info.iconSize * info.numIcons) + (info.gap * (info.numIcons + 1)) -- Allow horizontal space for up to 5 icons
	info.height = info.textHeight + info.iconSize + (info.gap * 3) -- Allow vertical space for the FontString and a single row of icons

	if (info:GetNumPoints() == 0) then -- No existing location found so position frame at TOP of screen and reset its size to the default
		info:SetPoint("TOP", UIParent, "TOP", 0, -info.gap)
		info:SetSize(info.width, info.height)
	end

	-- Set the background to a nice Atlas texture
	info.texBg = info:CreateTexture(nil, "BACKGROUND", nil, -8) -- Sub-layers run from -8 to +7: -8 puts our background at the lowest level
	info.texBg:SetPoint("TOPLEFT")
	info.texBg:SetSize(info.width, info.height)
	info.texBg:SetAtlas("spec-background", false)
	info.texBg:SetAlpha(0.75)

	-- Make the frame movable
	info:SetMovable(true)
	info:SetScript("OnMouseDown", function(self, button) self:StartMoving() end)
	info:SetScript("OnMouseUp", function(self, button) self:StopMovingOrSizing() end)
	
	-- Set the parameters for the unit containers
	info.fs = {} -- FontString containers for unit names
	info.icon = {} -- Texture containers for portrait icons
	info.ring = {} -- Texture containers for "normal" portrait rings
	info.target = {} -- Texture containers for "target" portrait rings
	local fsX, fsY = 0, -info.gap
	local iconX, iconY = 0, -info.textHeight - (info.gap * 2)
	local ringX, ringY = 0, iconY + (info.ringSize - info.iconSize)/2
	local targetX, targetY = 0, iconY + (info.targetSize - info.iconSize)/2

	for i = 1, info.numIcons do
		-- Fontstring for a unit name
		fsX = (i - 3) * (info.iconSize + info.gap)
		info.fs[i] = info:CreateFontString(nil, "ARTWORK", nil)
		info.fs[i]:SetPoint("TOP", info, "TOP", fsX, fsY)
		info.fs[i]:SetWidth(info.iconSize + (info.gap * 2))
		info.fs[i]:SetWordWrap(true)
		info.fs[i]:SetJustifyH("CENTER")
		info.fs[i]:SetTextColor( 1.0, 1.0, 1.0, 1.0 )
		info.fs[i]:SetFont("Fonts\\ARIALN.TTF", 12, "")

		-- Icon for a portrait
		iconX = info.gap + ((i - 1) * (info.iconSize + info.gap))
		info.icon[i] = info:CreateTexture(nil, "ARTWORK", nil, -8) -- Draw portrait icons on the lowest level of the ARTWORK layer
		info.icon[i]:SetPoint("TOPLEFT", info, "TOPLEFT", iconX, iconY)
		info.icon[i]:SetSize(info.iconSize, info.iconSize)

		-- Icon for a "normal" portrait ring
		ringX = iconX - (info.ringSize - info.iconSize)/2
		info.ring[i] = info:CreateTexture(nil, "ARTWORK", nil, -7) -- Draw rings on the level just above the portraits
		info.ring[i]:SetPoint("TOPLEFT", info, "TOPLEFT", ringX, ringY)
		info.ring[i]:SetSize(info.ringSize, info.ringSize)
		info.ring[i]:SetAtlas("auctionhouse-itemicon-border-gray", false)
		info.ring[i]:Hide()

		-- Icon for a "target" portrait ring
		targetX = iconX - (info.targetSize - info.iconSize)/2
		info.target[i] = info:CreateTexture(nil, "ARTWORK", nil, -6) -- Draw target rings on the level just above the normal rings
		info.target[i]:SetPoint("TOPLEFT", info, "TOPLEFT", targetX, targetY)
		info.target[i]:SetSize(info.targetSize, info.targetSize)
		info.target[i]:SetAtlas("auctionhouse-itemicon-border-artifact", false)
		info.target[i]:Hide()
	end
end

-----------------------------------------------------------------------------
-- SECTION 3: Create the other interactable objects
-----------------------------------------------------------------------------
--[[ Display the larger Close button (at bottom of frame)
frame.btnClose = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate") -- Button defined in SharedXML/SharedUIPanelTemplates.xml
frame.btnClose:SetPoint("BOTTOM", frame, "BOTTOM", 0, insets.bottom)
frame.btnClose:SetSize(60, 20)
frame.btnClose:SetText("Close")
frame.btnClose:SetScript("OnClick", function(self, button, down) frame:Hide() end)--]]

-----------------------------------------------------------------------------
-- SECTION 4: Define and register OnEvent handlers for the parent frames
-----------------------------------------------------------------------------
-- SECTION 4.1: Callback and support functions for pet event handlers
-----------------------------------------------------------------------------
-- Update state icons and fontstrings
local function updateStatus()
	local newshown = 1 -- Default to highest priority state
	for i, v in ipairs(state) do
		if (v.status == false) then newshown = i break end
	end
	state[shown].tex:Hide()
	state[shown].fs:Hide()
	state[newshown].tex:Show()
	state[newshown].fs:Show()
	shown = newshown
end

-- Every 0.25 seconds, check whether pet exists and is alive
local function cbTimer()	
	-- Does pet exist?
	local p = state[EXISTS]
	local newstatus = UnitExists("pet")
	if (newstatus ~= p.status) then -- If status is unchanged, we have nothing to do
		p.fs:SetText(p.txt[newstatus])
		if (newstatus) then p.tex:SetAlpha(1)
		else p.tex:SetAlpha(0) end
		p.status = newstatus
		updateStatus()
	end
	
	-- Is pet alive?
	p = state[ALIVE]
	if (state[EXISTS].status) then -- The "UnitIsDead()" API function does not work for despawned pets
		newstatus = (not UnitIsDead("pet"))
		if (newstatus ~= p.status) then 
			p.fs:SetText(p.txt[newstatus])
			p.status = newstatus
			updateStatus()
		end
	end
end

-- Callback function to check for dispellable pet debuffs
local function cbDebuffs(name, _, _, dispelType, ...)
	if (name ~= nil) then
		dispelType = (dispelType or "Curse") -- The dispelType may be "nil" (eg. many boss mechanics): if so, treat it as "Curse"
		if (dispelType ~= "Curse") then -- Is the dispelType "Disease", "Magic" or "Poison" (all dispellable by a Spirit Beast)
			state[NO_DEBUFF].status = false
			state[NO_DEBUFF].txt[false] = (dispelType .. " debuff")
			return true
		end
	end
end

-----------------------------------------------------------------------------
-- SECTION 4.2: Callback and support functions for info event handlers
-----------------------------------------------------------------------------
-- Convert an index to the Nameplate table into the corresponding unitID
local function toUnitID(index)
	return "Nameplate" .. index
end

-- Convert a unitID into an index to the links list
local function toIndex(unitID)
	return tonumber(strsub(unitID, 10))
end

-- Show the icon, a "normal" ring and (if needed) also a "target" ring
local function showTexture(slot, unitID)
	SetPortraitTexture(info.icon[slot], unitID)
	if (info.icon[slot] == nil) then print(unitID, " icon failed to load") end
	info.icon[slot]:Show()
	info.ring[slot]:Show()
	if(UnitIsUnit("target", unitID)) then info.target[slot]:Show()
	else info.target[slot]:Hide()
	end
end

-----------------------------------------------------------------------------
-- SECTION 4.3: Pet event handlers
-----------------------------------------------------------------------------
function petEvents:ADDON_LOADED(name)
	if (name == addonName) then
		-- Initialise the "pets" table in Saved Variables (not needed currently)
		if (pets == nil) then pets = {} end

		-- Does the pet exist?
		local p = state[EXISTS]
		p.status = UnitExists("pet")
		p.fs:SetText(p.txt[p.status])
		if (p.status) then p.tex:SetAlpha(1)
		else p.tex:SetAlpha(0) end

		-- Is the pet alive?
		p = state[ALIVE]
		if (state[EXISTS].status) then
			p.status = (not UnitIsDead("pet"))
			p.fs:SetText(p.txt[p.status])
		end
		
		-- Does the pet have any dispellable debuffs
		p = state[NO_DEBUFF]
		p.status = true
		AuraUtil.ForEachAura("pet", "HARMFUL", nil, cbDebuffs)
		p.fs:SetText(p.txt[p.status])

		-- Set the health bar values
		local p = state[HEALTHY]
		p.maxHealth = UnitHealthMax("pet")
		p.health = UnitHealth("pet")
		pet.bar:SetMinMaxValues(0, p.maxHealth)
		pet.bar:SetValue(p.health)

		-- Set the health bar color and description
		local h = (p.health/p.maxHealth)
		p.status = (h > 0.9)
		p.fs:SetText(p.txt[p.status])
		if (p.status) then -- Pet is regarded as "healthy" above 90% health
			pet.bar:SetStatusBarColor(0, 132/255, 80/255, 1) -- Traffic Light Green
		else
			if (h < 0.25) then pet.bar:SetStatusBarColor(187/255, 30/255, 16/255, 1) -- Below 25% health, bar is Traffic Light Red
			else pet.bar:SetStatusBarColor(1, 192/255, 0, 1) end -- Between 25% and 90% health, bar is Traffic Light Amber
		end
		updateStatus()

		-- Show the appropriate state icon and description
		shown = 1 -- Default to highest priority state if the other states are all "OK"
		for i, v in ipairs(state) do
			if (v.status == false) then shown = i break end
		end
		state[shown].tex:Show()
		state[shown].fs:Show()
		
		-- Start tracking the various pet states specified in the "state" table
		local timer = C_Timer.NewTicker(0.25, cbTimer) -- Start the tracking timer ("timer" has :IsCancelled() and :Cancel() methods)

		pet:UnregisterEvent("ADDON_LOADED")
		print(text.txtLoaded)
	end
end

-- Wait for a new pet debuff and check whether dispellable
function petEvents:UNIT_AURA(unitTarget, updateInfo)
	if (unitTarget == "pet") then
		if (updateInfo.addedAuras ~= nil) then 
			local p = state[NO_DEBUFF]
			local newstatus = true
			for i, v in ipairs(updateInfo.addedAuras) do 
				if ((v.isHarmful == true) and ((v.dispelName or "Curse") ~=  "Curse")) then 
					newstatus = false 
					p.txt[false] = (v.dispelName .. " debuff")
					break 
				end
			end
			if (newstatus ~= p.status) then 
				p.fs:SetText(p.txt[newstatus])
				p.status = newstatus
				updateStatus()
			end
		end
	end	
end

-- Get the maximum health and current health of pet, then update the health bar, status and description as necessary
local function updateHealth()
	-- Update health bar values
	local p = state[HEALTHY]
	p.maxHealth = UnitHealthMax("pet")
	p.health = UnitHealth("pet")
	pet.bar:SetMinMaxValues(0, p.maxHealth)
	pet.bar:SetValue(p.health)

	-- Update health bar color
	local h = (p.health/p.maxHealth)
	local newstatus = (h > 0.9)
	if (newstatus) then -- Pet is regarded as "healthy" above 90% health
		pet.bar:SetStatusBarColor(0, 132/255, 80/255, 1) -- Traffic Light Green
	else
		if (h < 0.25) then pet.bar:SetStatusBarColor(187/255, 30/255, 16/255, 1) -- Below 25% health, bar is Traffic Light Red
		else pet.bar:SetStatusBarColor(1, 192/255, 0, 1) end -- Between 25% and 90% health, bar is Traffic Light Amber
	end

	-- Update status and description
	if (newstatus ~= p.status) then 
		p.fs:SetText(p.txt[newstatus])
		p.status = newstatus
		updateStatus()
	end
end

-- Handle change in pet's current health
function petEvents:UNIT_HEALTH(unitTarget)
	if (unitTarget == "pet") then updateHealth() end
end

-- Handle change in pet's maximum health
function petEvents:UNIT_MAXHEALTH(unitTarget)
	if (unitTarget == "pet") then updateHealth() end
end

-- Update the pet's portrait on the pet frame, or a unit's portrait on the info frame
function petEvents:UNIT_PORTRAIT_UPDATE(unitID)
	if (unitID == "pet") then SetPortraitTexture(state[1].tex, unitID)
	elseif (strlower(strsub(unitID, 1, 9)) == "nameplate") then
		local index = toIndex(unitID)
		local slot = links[index]
		if (slot > 0) then showTexture(slot, unitID) end
	end
end

function petEvents:PLAYER_LOGOUT()
	timer:Cancel() -- Stop the tracking timer	
	pet:UnregisterAllEvents()
	info:UnregisterAllEvents()
	print(text.txtLogout)
end

-----------------------------------------------------------------------------
-- SECTION 4.4: Info event handlers
-----------------------------------------------------------------------------
-- Add a (newly-created) empty nameplate to our "links" list
function infoEvents:NAME_PLATE_CREATED(namePlateFrame)
	table.insert(links, -1) -- indicates the new nameplate contains no data
end

-- Add a unit's nameplate to our "slot" and "links" lists
function infoEvents:NAME_PLATE_UNIT_ADDED(unitID)
	local plate = toIndex(unitID)
	if (#slots < info.numIcons) then -- Our display list has space for the new nameplate (will always be at the end)
		table.insert(slots, plate) -- Create a new slot in the free space
		local slot = #slots
		links[plate] = slot -- Point the links table entry for the nameplate to the new slot

		local name, _ = UnitName(unitID) -- Populate the slot with the name, an icon for the nameplate and a portrait ring, then display it
		info.fs[slot]:SetText(name)
		info.fs[slot]:Show()
		showTexture(slot, unitID)
	else
		links[plate] = 0
	end
end

-- Remove a unit's nameplate from our "slot" and "links" lists
function infoEvents:NAME_PLATE_UNIT_REMOVED(unitID)
	local plate = toIndex(unitID)
	if (links[plate] > 0) then
		local slot = links[plate]
		local replaced = false
		for i, v in ipairs(links) do
			if (v == 0) then -- This nameplate is valid but has no slot allocated (ie. is not being displayed)
				slots[slot] = i -- Replace unitID's nameplate with this one
				replaced = true
				break 
			end
		end
		if ((replaced == false) and (slot == #slots)) then -- unitID occupies the last display slot, so we can simply delete it
			info.fs[#slots]:Hide()
			info.icon[#slots]:Hide()
			info.ring[#slots]:Hide()
			info.target[#slots]:Hide()
			table.remove(slots, #slots)
		else
			if (replaced == false) then -- unitID is not in the last slot, so we need to copy the last slot into unitID's slot before we delete the last slot
				slots[slot] = slots[#slots]
				info.fs[#slots]:Hide()
				info.icon[#slots]:Hide()
				info.ring[#slots]:Hide()
				info.target[#slots]:Hide()
				table.remove(slots, #slots)
			end
			local newID = toUnitID(slots[slot])
			local name, _ = UnitName(newID) -- Update unitID's slot with the name and icon for the new nameplate
			info.fs[slot]:SetText(name)
			links[slots[slot]] = slot
			showTexture(slot, newID)
		end
	end	
	links[plate] = -1 -- Set links table entry for unitID to "invalid"
end				

-- Move the "target" ring from the previous target to the new one
function infoEvents:PLAYER_TARGET_CHANGED()
	for i, v in ipairs(slots) do
	local unitID = toUnitID(v)
		if (UnitIsUnit("target", unitID)) then info.target[i]:Show()
		else info.target[i]:Hide()
		end
	end
end
	
-----------------------------------------------------------------------------
-- SECTION 5: Set our slash commands
-----------------------------------------------------------------------------
-- Count the number of in-range enemy units in the player's field of view
local function countEnemies()
	local enemies = 0
	for i, v in ipairs(links) do
		if (v < 0) then print("links[", i, "] --removed--")
		else
			local unitID = toUnitID(i)
			local name = UnitName(unitID)
			print(format("links[%d] --> slot[%d]: %s (%s)", i, v, name, unitID))
			if (UnitCanAttack("player", unitID) and IsItemInRange(63427, unitID)) then enemies = enemies + 1 end
		end
	end
	return enemies
end

-- Define the callback handler for our slash commands
local function cbSlash(msg, editBox)
	local cmd = strlower(msg)

	-- List the pet debuffs (if any)
	if (cmd == "debuffs") then 
		local t = {UnitAuraSlots("pet", "HARMFUL")}
		if (t[2] == nil) then print("Pet has no debuffs")
		else
			for i = 2, #t do
				local aura = C_UnitAuras.GetAuraDataBySlot("pet", t[i])
				print(aura.name, (aura.dispelName or "N/a"))
			end
		end

	-- Print the number of in-range enemies in the player's field of view
	elseif (cmd == "enemies") then
		print(countEnemies())

	-- Hide the "pet" and "info" frames
	elseif (cmd == "hide") then 
		pet:Hide()
		info:Hide()

	-- List the contents of the "links" table
	elseif (cmd == "links") then
		for i, v in ipairs(links) do
			if (v < 0) then print("links[", i, "] --removed--")
			else
				local unitID = "Nameplate" .. i
				local name = UnitName(unitID)
				print(format("links[ %d ] --> slot[ %d ]: %s (%s)", i, v, name, unitID))
			end
		end

	-- List the nameplates in the player's field of view
	elseif (cmd == "plates") then
		local nameplates = C_NamePlate.GetNamePlates()
		if (#nameplates > 0) then
			for i, v in ipairs(nameplates) do 
				local unitID = v.namePlateUnitToken
				local name, server = UnitName(unitID)
				print(format("[ %d ]: %s (%s-%s)", i, unitID, name, (server or "local")))
			end
		end
		print(addonName, ": Found ", #nameplates, " nameplate(s) in the list")

	-- Print the player's renown level, and progress towards the next level, with the Obsidian Warders faction
	elseif (cmd == "renown") then
    local factionInfo = {GetFactionInfoByID(2524)} -- 2524 = Obsidian Warders
		print(factionInfo[1],": ", factionInfo[2])
		print("Standing: ", _G["FACTION_STANDING_LABEL"..factionInfo[3]])
		print("Progress to ", _G["FACTION_STANDING_LABEL"..(factionInfo[3] + 1)], ": ", (factionInfo[6] - factionInfo[4]), "/", (factionInfo[5]- factionInfo[4]))

	-- Reset the position of the "pet" and "info" frames
	elseif (cmd == "reset") then 
		pet:ClearAllPoints()
		pet:SetPoint("CENTER")
		pet:SetSize(pet.width, pet.height)
		info:ClearAllPoints()
		info:SetPoint("TOP", UIParent, "TOP", 0, -info.gap)
		info:SetSize(info.width, info.height)

	-- Show the "pet" and "info" frames
	elseif (cmd == "show") then 
		pet:Show()
		info:Show()

	-- List the contents of the "slots" table
	elseif (cmd == "slots") then
		for i, v in ipairs(slots) do
			local unitID = toUnitID(v)
			local name = UnitName(unitID)
			print(format("slots[%d] --> Links[%d]: %s (%s)", i, v, name, unitID))
		end

	-- List the contents of the player's spellbook
	elseif (cmd == "spells") then
		dumpSpellbook()
	end
	print(addonName .. ": Processed (" .. msg .. ") command")
end

-- Add our slash commands and callback handler to the global table
local function setSlash()
	_G["SLASH_" .. strupper(addonName) .. "1"] = "/" .. strlower(strsub(addonName, 1, 2))
	_G["SLASH_" .. strupper(addonName) .. "2"] = "/" .. strupper(strsub(addonName, 1, 2))
	_G["SLASH_" .. strupper(addonName) .. "3"] = "/" .. strlower(addonName)
	_G["SLASH_" .. strupper(addonName) .. "4"] = "/" .. strupper(addonName)

	SlashCmdList[strupper(addonName)] = cbSlash
end

-----------------------------------------------------------------------------
-- SECTION 6: Create our UI
-----------------------------------------------------------------------------
-- Create the parent frames
createPet()
createInfo{}

-- Register all the pet and info events for which we provide a separate handling function
pet:SetScript("OnEvent", function(self, event, ...) petEvents[event](self, ...) end)
for k, v in pairs(petEvents) do pet:RegisterEvent(k) end

info:SetScript("OnEvent", function(self, event, ...) infoEvents[event](self, ...) end)
for k, v in pairs(infoEvents) do info:RegisterEvent(k) end

-- Set our slash commands
setSlash()
