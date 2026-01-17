-- factory.lua
-- One-file MineColonies automation controller:
--   Colony Requests -> RS (craft if needed) -> Export to Stash -> Courier delivers
--
-- Hardware:
--   * Computer (CC:Tweaked)
--   * RS Bridge (Advanced Peripherals) connected to production RS network
--   * Stash (MineColonies) adjacent to RS Bridge (logistics intake)
--   * Colony Integrator (Advanced Peripherals)
--   * Monitor (optional but recommended)
--
-- Your proven physical layout:
--   Computer -> (right) RS Bridge -> (right of bridge) Stash

--------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------

-- Sides relative to the COMPUTER
local BRIDGE_SIDE  = "right"   -- RS Bridge is on right of computer
local MONITOR_SIDE = nil       -- e.g. "top" if monitor attached to computer; nil disables
local MONITOR_TEXT_SCALE = 0.5

-- Side relative to the RS BRIDGE
local STASH_TARGET = "right"   -- stash is on right of RS bridge

-- Scan cadence
local SECONDS_BETWEEN_SCANS = 30

-- Safety: pause at night (colonists sleep)
local PAUSE_AT_NIGHT = true

-- Optional: write raw request data to file each scan
local LOG_REQUESTS_TO_FILE = false
local LOG_FILE = "factory_requests.log"

-- Skip categories / requests that are commonly NBT-specific or better done manually
local SKIP_NAMES_EXACT = {
  ["Compostable"] = true,
  ["Fertilizer"] = true,
  ["Flowers"] = true,
  ["Food"] = true,
  ["Fuel"] = true,
  ["Smeltable Ore"] = true,
  ["Stack List"] = true,
  ["Crafter"] = true,
  ["Rallying Banner"] = true,
}

local function shouldSkip(displayName, desc)
  if desc and string.find(desc, "Tool of class") then return true end

  local equipment = {
    "Hoe","Shovel","Axe","Pickaxe","Bow","Sword","Shield",
    "Helmet","Leather Cap","Chestplate","Tunic","Pants","Leggings","Boots"
  }
  for _, k in ipairs(equipment) do
    if displayName and string.find(displayName, k) then return true end
  end

  if displayName and SKIP_NAMES_EXACT[displayName] then return true end
  return false
end

--------------------------------------------------------------------
-- OUTPUT / UI
--------------------------------------------------------------------

local function getOutputTerm()
  if MONITOR_SIDE then
    local mon = peripheral.wrap(MONITOR_SIDE)
    if mon and peripheral.getType(MONITOR_SIDE) == "monitor" then
      mon.setTextScale(MONITOR_TEXT_SCALE)
      mon.setBackgroundColor(colors.black)
      mon.setTextColor(colors.white)
      mon.clear()
      mon.setCursorPos(1,1)
      mon.setCursorBlink(false)
      return mon
    end
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1,1)
  return term
end

local out = getOutputTerm()

local function cls()
  out.setBackgroundColor(colors.black)
  out.setTextColor(colors.white)
  out.clear()
  out.setCursorPos(1,1)
end

local function wLine(y, text, color)
  local w, _ = out.getSize()
  out.setCursorPos(1, y)
  out.setTextColor(color or colors.white)
  if #text > w then text = text:sub(1, w) end
  out.write(text .. string.rep(" ", math.max(0, w - #text)))
end

local function log(msg)
  local line = string.format("[%.2f] %s", os.clock(), msg)
  print(line)
end

--------------------------------------------------------------------
-- PERIPHERALS
--------------------------------------------------------------------

local function die(msg)
  wLine(1, "ERROR: " .. msg, colors.red)
  error(msg, 0)
end

local rs = peripheral.wrap(BRIDGE_SIDE)
if not rs then die("RS Bridge not found on computer side '" .. BRIDGE_SIDE .. "'.") end
local rsType = peripheral.getType(BRIDGE_SIDE)
if rsType ~= "rs_bridge" then die("Peripheral on '" .. BRIDGE_SIDE .. "' is '" .. tostring(rsType) .. "', expected 'rs_bridge'.") end

local colony =
  peripheral.find("colonyIntegrator") or
  peripheral.find("colony_integrator")
if not colony then die("Colony Integrator not found. Place it touching the computer (and inside colony).") end
if colony.isInColony and not colony.isInColony() then
  die("Colony Integrator cannot detect colony. Check placement inside colony bounds.")
end

--------------------------------------------------------------------
-- RS COMPAT / HELPERS
--------------------------------------------------------------------

local function exportToStash(stack)
  if rs.exportItem then
    return rs.exportItem(stack, STASH_TARGET) or 0
  end
  if rs.exportItemToPeripheral then
    -- Only used if your RS bridge doesn’t support direction export (rare)
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
  local outMap = {}
  local items = rs.getItems()

  for name, data in pairs(items) do
    -- RS Bridge getItems() does not include NBT variants
    outMap[name] = data.amount or 0
  end

  return outMap
end

--------------------------------------------------------------------
-- REQUEST HANDLING
--------------------------------------------------------------------

local function maybeLogRequests(reqs)
  if not LOG_REQUESTS_TO_FILE then return end
  local f = fs.open(LOG_FILE, "w")
  if f then
    f.write(textutils.serialize(reqs))
    f.close()
  end
end

local function fmtTime()
  return textutils.formatTime(os.time(), false)
end

local function isNight()
  local t = os.time()
  return (t >= 19.5 or t < 5)
end

local function getItemId(r)
  if r.items and r.items[1] and r.items[1].name then
    return r.items[1].name
  end
  return nil
end

local function scanAndAct()
  cls()
  wLine(1, "MineColonies Factory Controller (tap monitor = rescan)", colors.yellow)
  wLine(2, "Updated: " .. fmtTime() .. "   Scan interval: " .. tostring(SECONDS_BETWEEN_SCANS) .. "s", colors.lightGray)

  local reqs = colony.getRequests()
  maybeLogRequests(reqs)

  if not reqs or next(reqs) == nil then
    wLine(4, "No open requests.", colors.green)
    return {total=0, fulfilled=0, scheduled=0, skipped=0, failed=0}
  end

  local inv = listItemsNoNBT()

  local total, fulfilled, scheduled, skipped, failed = 0, 0, 0, 0, 0
  local row = 4
  local w, h = out.getSize()

  for _, r in pairs(reqs) do
    total = total + 1

    local displayName = r.name or "unknown"
    local desc = r.desc or ""
    local needed = r.count or 0
    local target = r.target or "unknown-target"
    local itemId = getItemId(r)

    local lineLeft = string.format("%d %s", needed, displayName)
    local lineRight = target

    if shouldSkip(displayName, desc) or not itemId or needed <= 0 then
      skipped = skipped + 1
      if row <= h then
        wLine(row, lineLeft, colors.blue)
        row = row + 1
        if row <= h then wLine(row, "  SKIP  -> " .. lineRight, colors.blue) row = row + 1 end
      end
    else
      -- attempt immediate export if present
      local provided = 0
      if inv[itemId] and inv[itemId] > 0 then
        provided = exportToStash({name=itemId, count=needed})
      end

      if provided >= needed then
        fulfilled = fulfilled + 1
        if row <= h then
          wLine(row, lineLeft, colors.green) row = row + 1
          if row <= h then wLine(row, "  OK    -> " .. lineRight, colors.green) row = row + 1 end
        end
      else
        -- schedule crafting if possible
        if isCrafting(itemId) then
          scheduled = scheduled + 1
          if row <= h then
            wLine(row, lineLeft, colors.yellow) row = row + 1
            if row <= h then wLine(row, "  CRAFT -> " .. lineRight, colors.yellow) row = row + 1 end
          end
        else
          local ok = craft(itemId, needed)
          if ok then
            scheduled = scheduled + 1
            if row <= h then
              wLine(row, lineLeft, colors.yellow) row = row + 1
              if row <= h then wLine(row, "  SCHED -> " .. lineRight, colors.yellow) row = row + 1 end
            end
          else
            failed = failed + 1
            if row <= h then
              wLine(row, lineLeft, colors.red) row = row + 1
              if row <= h then wLine(row, "  FAIL  -> " .. lineRight, colors.red) row = row + 1 end
            end
          end
        end
      end
    end

    row = row + 1
    if row > h then break end
  end

  -- Summary footer
  local footer = string.format("Total:%d  Fulfilled:%d  Crafting/Scheduled:%d  Skipped:%d  Failed:%d",
    total, fulfilled, scheduled, skipped, failed
  )
  wLine(h, footer, colors.lightGray)

  return {total=total, fulfilled=fulfilled, scheduled=scheduled, skipped=skipped, failed=failed}
end

--------------------------------------------------------------------
-- COMMAND MODE (same file)
--   factory send <item> <count>
--------------------------------------------------------------------

local args = {...}
if args[1] == "send" then
  local itemId = args[2]
  local count = tonumber(args[3] or "")
  if not itemId or not count or count <= 0 then
    print("Usage: factory send <item_id> <count>")
    print("Example: factory send minecraft:cobblestone 16")
    return
  end
  local moved = exportToStash({name=itemId, count=count})
  print(("Exported %d / %d of %s to stash"):format(moved, count, itemId))
  return
end

--------------------------------------------------------------------
-- MAIN LOOP (daemon mode)
--------------------------------------------------------------------

local remaining = SECONDS_BETWEEN_SCANS
scanAndAct()

local timer = os.startTimer(1)
while true do
  local e = { os.pullEvent() }

  if e[1] == "timer" and e[2] == timer then
    if (not PAUSE_AT_NIGHT) or (not isNight()) then
      remaining = remaining - 1
      if remaining <= 0 then
        scanAndAct()
        remaining = SECONDS_BETWEEN_SCANS
      end
    else
      -- show paused indicator
      wLine(3, "Night detected: paused (tap monitor to scan anyway)", colors.red)
    end
    timer = os.startTimer(1)

  elseif e[1] == "monitor_touch" then
    scanAndAct()
    remaining = SECONDS_BETWEEN_SCANS
    timer = os.startTimer(1)
  end
end
