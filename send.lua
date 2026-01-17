-- RSStashWarehouse.lua
-- MineColonies + CC:Tweaked + Advanced Peripherals + Refined Storage
-- Auto-fulfill open work requests by crafting (if patterns exist) and exporting to a MineColonies STASH.
--
-- You already proved this pipeline works:
--   Production RS -> RS Bridge -> Stash -> Courier -> (Warehouse/Builder/etc.)
--
-- REQUIRED SETUP (physical):
--   * CC:Tweaked Computer
--   * One or more Monitors (recommended 3x3) touching the computer
--   * Advanced Peripherals RS Bridge connected to your production RS cable network
--   * Advanced Peripherals Colony Integrator in your colony
--   * MineColonies Stash adjacent to the RS Bridge (this is your logistics intake)
--
-- IMPORTANT RULES (to prevent warehouse pollution):
--   * DO NOT connect External Storage/Importers to the Warehouse/Racks/etc.
--   * DO NOT let RS treat MineColonies storage as a storage backend
--   * Only export explicitly to the Stash.

--------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------

-- Direction from the RS BRIDGE to the STASH inventory.
-- Your confirmed layout is: Computer -> Bridge -> Stash
-- That usually means STASH_TARGET = "right" (from the bridge).
local STASH_TARGET = "right"

-- Seconds between scans (monitor-touch triggers an immediate scan)
local SECONDS_BETWEEN_SCANS = 30

-- Optional: write the current request JSON to a file each scan (can get big)
local LOG_REQUESTS_TO_FILE = false
local LOG_FILE = "RSStashWarehouse.log"

-- Skip supplying these “generic categories” / special requests via RS automation.
-- You can expand this list over time.
local SKIP_NAMES_EXACT = {
  ["Compostable"] = true,
  ["Fertilizer"] = true,
  ["Flowers"] = true,
  ["Food"] = true,
  ["Fuel"] = true,
  ["Smeltable Ore"] = true,
  ["Stack List"] = true,
  ["Crafter"] = true,          -- historically bugged in some alpha MineColonies builds
  ["Rallying Banner"] = true,  -- historically bugged in some alpha MineColonies builds
}

-- Skip “tools/armor/weapons/NBT” class requests (player/manual supply)
local function shouldSkipByDescriptionOrName(displayName, desc)
  if desc and string.find(desc, "Tool of class") then return true end

  -- Common equipment keywords MineColonies requests (usually needs NBT or specific material/level)
  local equipment = {
    "Hoe","Shovel","Axe","Pickaxe","Bow","Sword","Shield",
    "Helmet","Leather Cap","Chestplate","Tunic","Pants","Leggings","Boots"
  }
  for _, k in ipairs(equipment) do
    if displayName and string.find(displayName, k) then return true end
  end

  -- Exact names
  if displayName and SKIP_NAMES_EXACT[displayName] then return true end
  return false
end

--------------------------------------------------------------------
-- PERIPHERAL INIT
--------------------------------------------------------------------

local monitor = peripheral.find("monitor")
if not monitor then error("Monitor not found. Place a monitor touching the computer.") end
monitor.setTextScale(0.5)
monitor.clear()
monitor.setCursorPos(1,1)
monitor.setCursorBlink(false)

-- Advanced Peripherals naming differs by version/modpack:
-- Many ATM10 installs expose rs_bridge (snake case).
local rs =
  peripheral.find("rs_bridge") or
  peripheral.find("rsBridge")  or
  peripheral.find("rsbridge")
if not rs then error("RS Bridge not found. Ensure it's placed and connected to the RS network.") end

local colony =
  peripheral.find("colonyIntegrator") or
  peripheral.find("colony_integrator")
if not colony then error("Colony Integrator not found. Place it touching the computer and inside the colony.") end
if colony.isInColony and not colony.isInColony() then
  error("Colony Integrator is not in a colony (or cannot detect colony). Check placement.")
end

--------------------------------------------------------------------
-- MONITOR HELPERS
--------------------------------------------------------------------

local function mPrintRowJustified(mon, y, pos, text, fg, bg)
  local w, _ = mon.getSize()
  local oldFg = mon.getTextColor()
  local oldBg = mon.getBackgroundColor()

  local x = 1
  if pos == "center" then x = math.max(1, math.floor((w - #text) / 2)) end
  if pos == "right"  then x = math.max(1, w - #text) end

  if fg then mon.setTextColor(fg) end
  if bg then mon.setBackgroundColor(bg) end

  mon.setCursorPos(x, y)
  mon.write(text)

  mon.setTextColor(oldFg)
  mon.setBackgroundColor(oldBg)
end

local function isdigit(c)
  return c == "0" or c == "1" or c == "2" or c == "3" or c == "4" or
         c == "5" or c == "6" or c == "7" or c == "8" or c == "9"
end

local function displayTimer(mon, remaining)
  local now = os.time()

  local cycle, cycleColor = "day", colors.yellow
  if now >= 4 and now < 6 then
    cycle, cycleColor = "sunrise", colors.orange
  elseif now >= 6 and now < 18 then
    cycle, cycleColor = "day", colors.yellow
  elseif now >= 18 and now < 19.5 then
    cycle, cycleColor = "sunset", colors.orange
  else
    cycle, cycleColor = "night", colors.red
  end

  local timerColor = colors.orange
  if remaining < 15 then timerColor = colors.yellow end
  if remaining < 5  then timerColor = colors.red end

  mPrintRowJustified(mon, 1, "left",
    string.format("Time: %s [%s] ", textutils.formatTime(now, false), cycle),
    cycleColor
  )

  if cycle ~= "night" then
    mPrintRowJustified(mon, 1, "right",
      string.format(" Remaining: %ss", remaining),
      timerColor
    )
  else
    mPrintRowJustified(mon, 1, "right",
      " Remaining: PAUSED",
      colors.red
    )
  end
end

--------------------------------------------------------------------
-- RS BRIDGE COMPAT LAYER
--------------------------------------------------------------------

-- Some versions expose exportItem(stack, direction)
-- Others expose exportItemToPeripheral(stack, peripheralName)
-- Your setup works with direction-based export, so we default to that.
local function exportToStash(stack)
  if rs.exportItem then
    return rs.exportItem(stack, STASH_TARGET) or 0
  end
  if rs.exportItemToPeripheral then
    -- If your bridge only supports exportItemToPeripheral, you must set STASH_TARGET
    -- to the *peripheral name* of the stash inventory (rare). Direction export is preferred.
    return rs.exportItemToPeripheral(stack, STASH_TARGET) or 0
  end
  return 0
end

local function isCrafting(itemId)
  if rs.isItemCrafting then return rs.isItemCrafting(itemId) end
  return false
end

local function craft(itemId, count)
  if rs.craftItem then
    return rs.craftItem({ name = itemId, count = count }) == true
  end
  return false
end

local function listItemsNoNBT()
  local out = {}
  local items = rs.listItems()
  for _, it in ipairs(items) do
    -- Ignore NBT items; MineColonies often requests specific NBT variants.
    if not it.nbt then
      out[it.name] = it.amount
    end
  end
  return out
end

--------------------------------------------------------------------
-- REQUEST SCAN + DISPLAY
--------------------------------------------------------------------

local function maybeLogRequests(reqs)
  if not LOG_REQUESTS_TO_FILE then return end
  local f = fs.open(LOG_FILE, "w")
  if f then
    f.write(textutils.serialize(reqs))
    f.close()
  end
end

local function parseTarget(target)
  -- Original script tries to shorten target into a nicer display.
  -- We'll keep similar behavior but safe.
  local words = {}
  for w in string.gmatch(target or "", "%S+") do table.insert(words, w) end

  local n = #words
  if n == 0 then return "", "" end
  if n < 3 then return target, target end

  local targetName = words[n-2] .. " " .. words[n]
  local targetType = table.concat(words, " ", 1, math.max(1, n-3))
  return targetType, targetName
end

local function scanWorkRequests(mon)
  local builder_list, nonbuilder_list, equipment_list = {}, {}, {}

  -- Scan RS for inventory snapshot
  local inv = listItemsNoNBT()

  -- Pull colony requests
  local reqs = colony.getRequests()
  maybeLogRequests(reqs)

  for _, r in pairs(reqs) do
    local displayName = r.name
    local target = r.target or ""
    local desc = r.desc or ""
    local needed = r.count or 0

    -- MineColonies request format: items[1].name is the actual item id.
    local itemId = nil
    if r.items and r.items[1] and r.items[1].name then itemId = r.items[1].name end

    local targetType, targetName = parseTarget(target)

    local provided = 0
    local useRS = 1

    if shouldSkipByDescriptionOrName(displayName, desc) then
      useRS = 0
    end

    local color = colors.blue

    if useRS == 1 and itemId and needed > 0 then
      -- If we have any in RS, export what we can directly to STASH
      if inv[itemId] and inv[itemId] > 0 then
        provided = exportToStash({ name = itemId, count = needed })
      end

      color = colors.green
      if provided < needed then
        -- Not fully satisfied; schedule crafting if possible
        if isCrafting(itemId) then
          color = colors.yellow
          print("[Crafting]", itemId)
        else
          if craft(itemId, needed) then
            color = colors.yellow
            print("[Scheduled]", needed, "x", itemId)
          else
            color = colors.red
            print("[Failed]", itemId)
          end
        end
      end
    else
      -- Skipped/manual category
      color = colors.blue
      print("[Skipped]", tostring(displayName), "[" .. tostring(target) .. "]")
    end

    -- Bucket into display lists
    if desc and string.find(desc, "of class") then
      -- Equipment list display
      local level = "Any Level"
      if string.find(desc, "with maximal level:Leather") then level = "Leather" end
      if string.find(desc, "with maximal level:Gold") then level = "Gold" end
      if string.find(desc, "with maximal level:Chain") then level = "Chain" end
      if string.find(desc, "with maximal level:Wood or Gold") then level = "Wood or Gold" end
      if string.find(desc, "with maximal level:Stone") then level = "Stone" end
      if string.find(desc, "with maximal level:Iron") then level = "Iron" end
      if string.find(desc, "with maximal level:Diamond") then level = "Diamond" end

      local newName = (level == "Any Level") and (displayName .. " of any level") or (level .. " " .. displayName)
      local newTarget = (targetType ~= "" and (targetType .. " " .. targetName)) or targetName
      table.insert(equipment_list, {
        name = newName, target = newTarget,
        needed = needed, provided = provided, color = color
      })

    elseif target and string.find(target, "Builder") then
      table.insert(builder_list, {
        name = displayName, item = itemId,
        target = targetName, needed = needed, provided = provided, color = color
      })
    else
      local newTarget = target
      if #targetName > 0 and #targetType > 0 then
        newTarget = targetType .. " " .. targetName
      end
      table.insert(nonbuilder_list, {
        name = displayName, target = newTarget,
        needed = needed, provided = provided, color = color
      })
    end
  end

  -- Render on monitor
  mon.clear()
  local row = 3

  local function renderSection(title, list, makeLeftText, makeRightText)
    if #list == 0 then return end
    mPrintRowJustified(mon, row, "center", title)
    row = row + 1
    for _, it in ipairs(list) do
      local left = makeLeftText(it)
      local right = makeRightText(it)
      mPrintRowJustified(mon, row, "left", left, it.color)
      mPrintRowJustified(mon, row, "right", " " .. right, it.color)
      row = row + 1
    end
    row = row + 1
  end

  renderSection("Equipment", equipment_list,
    function(it) return string.format("%d %s", it.needed, it.name) end,
    function(it) return it.target end
  )

  renderSection("Builder Requests", builder_list,
    function(it) return string.format("%d/%s", it.provided, it.name) end,
    function(it) return it.target end
  )

  renderSection("Nonbuilder Requests", nonbuilder_list,
    function(it)
      local text = string.format("%d %s", it.needed, it.name)
      if isdigit((it.name or ""):sub(1,1)) then
        text = string.format("%d/%s", it.provided, it.name)
      end
      return text
    end,
    function(it) return it.target end
  )

  if row == 3 then
    mPrintRowJustified(mon, row, "center", "No Open Requests")
  end

  print("Scan completed at", textutils.formatTime(os.time(), false) .. " (" .. os.time() .. ").")
end

--------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------

local timeBetween = SECONDS_BETWEEN_SCANS
local remaining = timeBetween

-- Initial scan
scanWorkRequests(monitor)

displayTimer(monitor, remaining)
local TIMER = os.startTimer(1)

while true do
  local e = { os.pullEvent() }

  if e[1] == "timer" and e[2] == TIMER then
    local now = os.time()

    -- Pause at night (MineColonies sleeps; avoids churn)
    local isNight = (now >= 19.5 or now < 5)

    if not isNight then
      remaining = remaining - 1
      if remaining <= 0 then
        scanWorkRequests(monitor)
        remaining = timeBetween
      end
    end

    displayTimer(monitor, remaining)
    TIMER = os.startTimer(1)

  elseif e[1] == "monitor_touch" then
    os.cancelTimer(TIMER)
    scanWorkRequests(monitor)
    remaining = timeBetween
    displayTimer(monitor, remaining)
    TIMER = os.startTimer(1)
  end
end
