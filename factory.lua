-- factory.lua
-- One-file MineColonies automation controller
-- Colony Requests -> RS (craft if needed) -> Export to Stash -> Courier delivers
--
-- Physical layout (confirmed):
--   Computer -> (right) RS Bridge -> (right of bridge) Stash
--   Computer -> (left) Colony Integrator
--   Monitor wall connected via Wired Modem + Network Cable
--
-- Monitor network name (confirmed): monitor_0

--------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------

local BRIDGE_SIDE = "right"          -- RS Bridge on computer
local COLONY_SIDE = "left"           -- Colony Integrator on computer
local STASH_TARGET = "right"         -- From RS Bridge to Stash

local MONITOR_NAME = "monitor_0"     -- Networked monitor name
local MONITOR_TEXT_SCALE = 0.5

local SECONDS_BETWEEN_SCANS = 30
local PAUSE_AT_NIGHT = true

local LOG_REQUESTS_TO_FILE = false
local LOG_FILE = "factory_requests.log"

--------------------------------------------------------------------
-- SKIP RULES
--------------------------------------------------------------------

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

local function shouldSkip(name, desc)
  if desc and string.find(desc, "Tool of class") then return true end

  local equipment = {
    "Hoe","Shovel","Axe","Pickaxe","Bow","Sword","Shield",
    "Helmet","Leather Cap","Chestplate","Tunic","Pants","Leggings","Boots"
  }
  for _, k in ipairs(equipment) do
    if name and string.find(name, k) then return true end
  end

  return SKIP_NAMES_EXACT[name] or false
end

--------------------------------------------------------------------
-- OUTPUT / UI
--------------------------------------------------------------------

local function getOutput()
  local mon = peripheral.wrap(MONITOR_NAME)
  if mon and peripheral.getType(MONITOR_NAME) == "monitor" then
    mon.setTextScale(MONITOR_TEXT_SCALE)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.clear()
    mon.setCursorPos(1,1)
    mon.setCursorBlink(false)
    return mon
  end

  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1,1)
  return term
end

local out = getOutput()

local function cls()
  out.clear()
  out.setCursorPos(1,1)
end

local function writeLine(y, text, color)
  local w,_ = out.getSize()
  out.setCursorPos(1,y)
  out.setTextColor(color or colors.white)
  if #text > w then text = text:sub(1,w) end
  out.write(text .. string.rep(" ", w - #text))
end

--------------------------------------------------------------------
-- PERIPHERALS
--------------------------------------------------------------------

local function die(msg)
  writeLine(1, "ERROR: "..msg, colors.red)
  error(msg,0)
end

local rs = peripheral.wrap(BRIDGE_SIDE)
if not rs then die("RS Bridge not found on "..BRIDGE_SIDE) end
if peripheral.getType(BRIDGE_SIDE) ~= "rs_bridge" then
  die("Peripheral on "..BRIDGE_SIDE.." is not rs_bridge")
end

local colony = peripheral.wrap(COLONY_SIDE)
if not colony then die("Colony Integrator not found on "..COLONY_SIDE) end

--------------------------------------------------------------------
-- RS HELPERS (ATM10)
--------------------------------------------------------------------

local function exportToStash(stack)
  return rs.exportItem(stack, STASH_TARGET) or 0
end

local function isCrafting(item)
  return rs.isItemCrafting and rs.isItemCrafting(item) or false
end

local function craft(item, count)
  return rs.craftItem and rs.craftItem({name=item, count=count}) == true
end

local function listItems()
  local map = {}
  local items = rs.getItems()
  for name,data in pairs(items) do
    map[name] = data.amount or 0
  end
  return map
end

--------------------------------------------------------------------
-- REQUEST SCAN
--------------------------------------------------------------------

local function isNight()
  local t = os.time()
  return t >= 19.5 or t < 5
end

local function getItemId(r)
  return r.items and r.items[1] and r.items[1].name or nil
end

local function scan()
  cls()
  writeLine(1,"MineColonies Factory Controller",colors.yellow)
  writeLine(2,"Updated: "..textutils.formatTime(os.time(),false),colors.lightGray)

  local reqs = colony.getRequests()
  if not reqs or next(reqs)==nil then
    writeLine(4,"No open requests.",colors.green)
    return
  end

  local inv = listItems()
  local row = 4
  local w,h = out.getSize()

  for _,r in pairs(reqs) do
    if row > h-1 then break end

    local name = r.name or "unknown"
    local desc = r.desc or ""
    local count = r.count or 0
    local target = r.target or "unknown"
    local item = getItemId(r)

    writeLine(row, count.." "..name, colors.white)
    row=row+1

    if shouldSkip(name,desc) or not item then
      writeLine(row,"  SKIP -> "..target,colors.blue)
      row=row+1
    else
      local provided = 0
      if inv[item] and inv[item] > 0 then
        provided = exportToStash({name=item,count=count})
      end

      if provided >= count then
        writeLine(row,"  OK -> "..target,colors.green)
        row=row+1
      else
        if not isCrafting(item) then
          craft(item,count)
        end
        writeLine(row,"  CRAFT -> "..target,colors.yellow)
        row=row+1
      end
    end

    row=row+1
  end
end

--------------------------------------------------------------------
-- COMMAND MODE
--------------------------------------------------------------------

local args={...}
if args[1]=="send" then
  local item=args[2]
  local cnt=tonumber(args[3] or "")
  if not item or not cnt then
    print("Usage: factory send <item> <count>")
    return
  end
  local moved=exportToStash({name=item,count=cnt})
  print("Exported "..moved.." / "..cnt.." "..item)
  return
end

--------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------

local remaining=SECONDS_BETWEEN_SCANS
scan()

local timer=os.startTimer(1)
while true do
  local e={os.pullEvent()}

  if e[1]=="timer" and e[2]==timer then
    if not PAUSE_AT_NIGHT or not isNight() then
      remaining=remaining-1
      if remaining<=0 then
        scan()
        remaining=SECONDS_BETWEEN_SCANS
      end
    end
    timer=os.startTimer(1)

  elseif e[1]=="monitor_touch" and e[2]==MONITOR_NAME then
    scan()
    remaining=SECONDS_BETWEEN_SCANS
    timer=os.startTimer(1)
  end
end
