--
-- An FRSKY S.Port <passthrough protocol> based Telemetry script for the Horus X10 and X12 radios
--
-- Copyright (C) 2018-2021. Alessandro Apostoli
-- https://github.com/yaapu
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY, without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, see <http://www.gnu.org/licenses>.
--

--[[
  ALARM_TYPE_MIN needs arming (min has to be reached first), value below level for grace, once armed is periodic, reset on landing
  ALARM_TYPE_MAX no arming, value above level for grace, once armed is periodic, reset on landing
  ALARM_TYPE_TIMER no arming, fired periodically, spoken time, reset on landing
  ALARM_TYPE_BATT needs arming (min has to be reached first), value below level for grace, no reset on landing
{
  1 = notified,
  2 = alarm start,
  3 = armed,
  4 = type(0=min,1=max,2=timer,3=batt),
  5 = grace duration
  6 = ready
  7 = last alarm
}
--]]
local unitScale = getGeneralSettings().imperial == 0 and 1 or 3.28084
local unitLabel = getGeneralSettings().imperial == 0 and "m" or "ft"
local unitLongScale = getGeneralSettings().imperial == 0 and 1/1000 or 1/1609.34
local unitLongLabel = getGeneralSettings().imperial == 0 and "km" or "mi"


local currentModel = nil

------------------------------
-- TELEMETRY DATA
------------------------------
local telemetry = {}
-- GPS
telemetry.numSats = 0
telemetry.gpsStatus = 0
telemetry.gpsHdopC = 100
-- HOME
telemetry.homeDist = 0
telemetry.homeAlt = 0
telemetry.homeAngle = -1
-- VELANDYAW
telemetry.yaw = 0
-- GPS
telemetry.lat = nil
telemetry.lon = nil
telemetry.homeLat = nil
telemetry.homeLon = nil

-----------------------------------------------------------------
-- INAV like telemetry support
-----------------------------------------------------------------
local gpsHome = false
--------------------------------
-- STATUS DATA
--------------------------------
local status = {}
-- MAP
status.mapZoomLevel = nil

---------------------------
-- LIBRARY LOADING
---------------------------
local basePath = "/SCRIPTS/YAAPU/"
local libBasePath = basePath.."LIB/"

-- loadable modules
local drawLibFile = "mapsdraw"
local menuLibFile = "mapsconfig"

local drawLib = {}
local utils = {}
utils.colors = {}

-------------------------------
-- MAP SCREEN LAYOUT
-------------------------------
local mapLayout = nil

local customSensors = nil

local backlightLastTime = 0

-- Blinking bitmap support
local bitmaps = {}
local blinktime = getTime()
local blinkon = false


-- model and opentx version
local ver, radio, maj, minor, rev = getVersion()
-- widget selected page
local currentPage = 0
--------------------------------------------------------------------------------
-- CONFIGURATION MENU
--------------------------------------------------------------------------------
local conf = {
  mapType = "sat_tiles",
  enableMapGrid = true,
  mapWheelChannelId = nil, -- used as wheel emulator
  mapWheelChannelDelay = 20,
  mapTrailDots = 10,
  mapZoomLevel = -2, -- deprecated
  mapZoomMax = 17,
  mapZoomMin = -2,
  mapProvider = 1, -- 1 GMapCatcher, 2 Google
  headingSensor = "Hdg",
  headingSensorUnitScale = 1,
  sensorsConfigFileType = 0 -- model
}

local loadCycle = 0

utils.doLibrary = function(filename)
  local f = assert(loadScript(libBasePath..filename..".lua","c"))
  collectgarbage()
  collectgarbage()
  return f()
end

--[[
 for better performance we cache lcd.RGB()
--]]
utils.initColors = function()
  -- check if we have lcd.RGB() at init time
  local color = lcd.RGB(0,0,0)
  if color == nil then
    utils.colors.black = BLACK
    utils.colors.white = WHITE
    utils.colors.green = 0x1FEA
    utils.colors.blue = BLUE
    utils.colors.darkblue = 0x0AB1
    utils.colors.darkyellow = 0xFE60
    utils.colors.yellow = 0xFFE0
    utils.colors.orange = 0xFB60
    utils.colors.red = 0xF800
    utils.colors.lightgrey = 0x8C71
    utils.colors.grey = 0x7BCF
    utils.colors.darkgrey = 0x5AEB
    utils.colors.lightred = 0xF9A0
    utils.colors.bars2 = 0x10A3
  else
    -- EdgeTX
    utils.colors.black = BLACK
    utils.colors.white = WHITE
    utils.colors.green = lcd.RGB(00, 0xED, 0x32)
    utils.colors.blue = BLUE
    utils.colors.darkblue = lcd.RGB(8,84,136)
    utils.colors.darkyellow = lcd.RGB(255,206,0)
    utils.colors.yellow = lcd.RGB(255, 0xCE, 0)
    utils.colors.orange = lcd.RGB(248,109,0)
    utils.colors.red = RED
    utils.colors.lightgrey = lcd.RGB(138,138,138)
    utils.colors.grey = lcd.RGB(120,120,120)
    utils.colors.darkgrey = lcd.RGB(90,90,90)
    utils.colors.lightred = lcd.RGB(255,53,0)
    utils.colors.bars2 = lcd.RGB(16,20,25)
  end
end

-----------------------------
-- clears the loaded table
-- and recovers memory
-----------------------------
utils.clearTable = function(t)
  if type(t)=="table" then
    for i,v in pairs(t) do
      if type(v) == "table" then
        utils.clearTable(v)
      end
      t[i] = nil
    end
  end
  t = nil
  collectgarbage()
  collectgarbage()
  maxmem = 0
end

local function loadConfig()
  -- load menu library
  menuLib = dofile(basePath..menuLibFile..".luac")
  menuLib.loadConfig(conf)
  -- unload libraries
  utils.clearTable(menuLib)
  utils.clearTable(mapLayout)
  mapLayout = nil
  utils.clearTable(customSensors)
    -- load custom sensors
  utils.loadCustomSensors()
  collectgarbage()
  collectgarbage()
end

utils.getBitmap = function(name)
  if bitmaps[name] == nil then
    bitmaps[name] = Bitmap.open("/SCRIPTS/YAAPU/IMAGES/"..name..".png")
  end
  return bitmaps[name],Bitmap.getSize(bitmaps[name])
end

utils.unloadBitmap = function(name)
  if bitmaps[name] ~= nil then
    bitmaps[name] = nil
    -- force call to luaDestroyBitmap()
    collectgarbage()
    collectgarbage()
  end
end

utils.lcdBacklightOn = function()
  model.setGlobalVariable(8,0,1)
  backlightLastTime = getTime()/100 -- seconds
end


utils.getHomeFromAngleAndDistance = function(telemetry)
--[[
  la1,lo1 coordinates of first point
  d be distance (m),
  R as radius of Earth (m),
  Ad be the angular distance i.e d/R and
  θ be the bearing in deg

  la2 =  asin(sin la1 * cos Ad  + cos la1 * sin Ad * cos θ), and
  lo2 = lo1 + atan2(sin θ * sin Ad * cos la1 , cos Ad – sin la1 * sin la2)
--]]
  if telemetry.lat == nil or telemetry.lon == nil then
    return nil,nil
  end

  local lat1 = math.rad(telemetry.lat)
  local lon1 = math.rad(telemetry.lon)
  local Ad = telemetry.homeDist/(6371000) --meters
  local lat2 = math.asin( math.sin(lat1) * math.cos(Ad) + math.cos(lat1) * math.sin(Ad) * math.cos( math.rad(telemetry.homeAngle)) )
  local lon2 = lon1 + math.atan2( math.sin( math.rad(telemetry.homeAngle) ) * math.sin(Ad) * math.cos(lat1) , math.cos(Ad) - math.sin(lat1) * math.sin(lat2))
  return math.deg(lat2), math.deg(lon2)
end


utils.decToDMS = function(dec,lat)
  local D = math.floor(math.abs(dec))
  local M = (math.abs(dec) - D)*60
  local S = (math.abs((math.abs(dec) - D)*60) - M)*60
	return D .. string.format("\64%04.2f", M) .. (lat and (dec >= 0 and "E" or "W") or (dec >= 0 and "N" or "S"))
end

utils.decToDMSFull = function(dec,lat)
  local D = math.floor(math.abs(dec))
  local M = math.floor((math.abs(dec) - D)*60)
  local S = (math.abs((math.abs(dec) - D)*60) - M)*60
	return D .. string.format("\64%d'%04.1f", M, S) .. (lat and (dec >= 0 and "E" or "W") or (dec >= 0 and "N" or "S"))
end

utils.drawBlinkBitmap = function(bitmap,x,y)
  if blinkon == true then
      lcd.drawBitmap(utils.getBitmap(bitmap),x,y)
  end
end

local function isFileEmpty(filename)
  local file = io.open(filename,"r")
  if file == nil then
    return true
  end
  local str = io.read(file,10)
  io.close(file)
  if #str < 10 then
    return true
  end
  return false
end

local function getSensorsConfigFilename()
  local cfg = nil
  if conf.sensorsConfigFileType == 0 then
    local info = model.getInfo()
    cfg = "/SCRIPTS/YAAPU/CFG/" .. string.lower(string.gsub(info.name, "[%c%p%s%z]", "").."_sensors_maps.lua")
    -- help users with file name issues by creating an empty config file
    local file = io.open(cfg,"r")
    if file == nil then
      -- let's create the empty config file
      file = io.open(cfg,"w")
      io.close(file)
    else
      io.close(file)
    end

    -- we ignore empty config file
    if isFileEmpty(cfg) then
      cfg = "/SCRIPTS/YAAPU/CFG/default_sensors_maps.lua"
    end
  else
    cfg = "/SCRIPTS/YAAPU/CFG/profile_"..conf.sensorsConfigFileType.."_sensors_maps.lua"
  end
  return cfg
end

--------------------------
-- CUSTOM SENSORS SUPPORT
--------------------------

utils.loadCustomSensors = function()
  local success, sensorScript = pcall(loadScript,getSensorsConfigFilename())
  if success then
    if sensorScript == nil then
      customSensors = nil
      return
    end
    collectgarbage()
    customSensors = sensorScript()
    -- handle nil values for warning and critical levels
    for i=1,10
    do
      if customSensors.sensors[i] ~= nil then
        local sign = customSensors.sensors[i][6] == "+" and 1 or -1
        if customSensors.sensors[i][9] == nil then
          customSensors.sensors[i][9] = math.huge*sign
        end
        if customSensors.sensors[i][8] == nil then
          customSensors.sensors[i][8] = math.huge*sign
        end
      end
    end
    collectgarbage()
    collectgarbage()
  else
    customSensors = nil
  end
end

local function validGps(gpsPos)
  return type(gpsPos) == "table" and gpsPos.lat ~= nil and gpsPos.lon ~= nil
end

local function calcHomeDirection(gpsPos)
  if gpsHome == false then
    return false
  end
  -- Formula:	θ = atan2( sin Δλ ⋅ cos φ2 , cos φ1 ⋅ sin φ2 − sin φ1 ⋅ cos φ2 ⋅ cos Δλ )
  local lat2 = math.rad(gpsHome.lat)
  local lon2 = math.rad(gpsHome.lon)
  local lat1 = math.rad(gpsPos.lat)
  local lon1 = math.rad(gpsPos.lon)
  local y = math.sin(lon2-lon1) * math.cos(lat2);
  local x = math.cos(lat1)*math.sin(lat2) - math.sin(lat1)*math.cos(lat2)*math.cos(lon2-lon1)
  local hdg = math.deg(math.atan2(y,x))
  if (hdg < 0) then
    hdg = 360 + hdg
  end
  return hdg
end

local function processTelemetry()
  -- YAW
  telemetry.yaw = getValue(conf.headingSensor) * conf.headingSensorUnitScale
end

local function telemetryEnabled()
  if getRSSI() == 0 then
    return false
  end
  status.hideNoTelemetry = true
  return true
end

local function calcMinValue(value,min)
  return min == 0 and value or math.min(value,min)
end

-- returns the actual minimun only if both are > 0
local function getNonZeroMin(v1,v2)
  return v1 == 0 and v2 or ( v2 == 0 and v1 or math.min(v1,v2))
end

utils.drawTopBar = function()
  lcd.setColor(CUSTOM_COLOR,utils.colors.black)
  -- black bar
  lcd.drawFilledRectangle(0,0, LCD_W, 18, CUSTOM_COLOR)
  -- frametype and model name
  lcd.setColor(CUSTOM_COLOR,utils.colors.white)
  if status.modelString ~= nil then
    lcd.drawText(2, 0, status.modelString, CUSTOM_COLOR)
  end
  local time = getDateTime()
  local strtime = string.format("%02d:%02d:%02d",time.hour,time.min,time.sec)
  lcd.drawText(LCD_W, 0+4, strtime, SMLSIZE+RIGHT+CUSTOM_COLOR)
  -- RSSI
  if telemetryEnabled() == false then
    lcd.setColor(CUSTOM_COLOR,utils.colors.red)
    lcd.drawText(285-23, 0, "NO TELEM", 0+CUSTOM_COLOR)
  else
    lcd.drawText(285, 0, "RS:", 0+CUSTOM_COLOR)
    lcd.drawText(285 + 30,0, getRSSI(), 0+CUSTOM_COLOR)
  end
  lcd.setColor(CUSTOM_COLOR,utils.colors.white)
  -- tx voltage
  local vtx = string.format("Tx:%.1fv",getValue(getFieldInfo("tx-voltage").id))
  lcd.drawText(350,0, vtx, 0+CUSTOM_COLOR)
end

local function reset()
  utils.clearTable(customSensors)
  customSensors = nil
  -- TELEMETRY
  utils.clearTable(telemetry)
  -- GPS
  telemetry.numSats = 0
  telemetry.gpsStatus = 0
  telemetry.gpsHdopC = 100
  -- HOME
  telemetry.homeDist = 0
  telemetry.homeAlt = 0
  telemetry.homeAngle = -1
  -- VELANDYAW
  telemetry.yaw = 0
  -- GPS
  telemetry.lat = nil
  telemetry.lon = nil
  telemetry.homeLat = nil
  telemetry.homeLon = nil

  collectgarbage()
  collectgarbage()
  -- STATUS
  utils.clearTable(status)
  status.mapZoomLevel = nil
  collectgarbage()
  collectgarbage()
  -- CONFIG
  loadConfig()
  -- SENSORS
  utils.loadCustomSensors()
end

--------------------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------------------
--
local bgclock = 0

-------------------------------
-- running at 20Hz (every 50ms)
-------------------------------
local timer2Hz = getTime()
local timerWheel = getTime()

local function backgroundTasks(myWidget)
  processTelemetry()

  status.mapZoomLevel = utils.getMapZoomLevel(myWidget,conf,status,customSensors)

  -- SLOW: this runs around 2.5Hz
  if bgclock % 2 == 1 then
    -- update gps telemetry data
    local gpsData = getValue("GPS")

    if type(gpsData) == "table" and gpsData.lat ~= nil and gpsData.lon ~= nil then
      telemetry.lat = gpsData.lat
      telemetry.lon = gpsData.lon
    end

    if getTime() - timer2Hz > 50 then
      timer2Hz = getTime()

      -- frametype and model name
      local info = model.getInfo()
      -- model change event
      if currentModel ~= info.name then
        currentModel = info.name
        -- force a model string reset
        status.modelString = info.name
        -- trigger reset
        reset()
      end

    end

    if status.modelString == nil then
      local info = model.getInfo()
      status.modelString = info.name
    end
 end

  -- SLOWER: this runs around 1.25Hz but not when the previous block runs
  -- because bgclock%4 == 0 is always different than bgclock%2==1
  if bgclock % 4 == 0 then
    -- reset backlight panel
    if (model.getGlobalVariable(8,0) > 0 and getTime()/100 - backlightLastTime > 5) then
      model.setGlobalVariable(8,0,0)
    end

    -- reload config
    if (model.getGlobalVariable(8,7) > 0) then
      loadConfig()
      model.setGlobalVariable(8,7,0)
    end

    bgclock = 0
  end
  bgclock = bgclock+1

  -- blinking support
  if (getTime() - blinktime) > 65 then
    blinkon = not blinkon
    blinktime = getTime()
  end

  collectgarbage()
  collectgarbage()
  return 0
end

local function init()

-- load configuration at boot and only refresh if GV(8,8) = 1
  loadConfig()
  utils.initColors()
  -- zoom initialize
  status.mapZoomLevel = conf.mapZoomLevel
  -- load draw library
  drawLib = utils.doLibrary(drawLibFile)

  currentModel = model.getInfo().name
  -- load custom sensors
  utils.loadCustomSensors()
  -- fix for generalsettings lazy loading...
  unitScale = getGeneralSettings().imperial == 0 and 1 or 3.28084
  unitLabel = getGeneralSettings().imperial == 0 and "m" or "ft"

  unitLongScale = getGeneralSettings().imperial == 0 and 1/1000 or 1/1609.34
  unitLongLabel = getGeneralSettings().imperial == 0 and "km" or "mi"
end

--------------------------------------------------------------------------------

local options = {}
-- shared init flag
local initDone = 0

-- This function is runned once at the creation of the widget
local function create(zone, options)
  -- this vars are widget scoped, each instance has its own set
  local vars = {
  }
  -- all local vars are shared between widget instances
  -- init() needs to be called only once!
  if initDone == 0 then
    init()
    initDone = 1
  end
  --
  return { zone=zone, options=options, vars=vars }
end

-- This function allow updates when you change widgets settings
local function update(myWidget, options)
  myWidget.options = options
  -- reload menu settings
  loadConfig()
end

local function fullScreenRequired(myWidget)
  lcd.setColor(CUSTOM_COLOR,lcd.RGB(255, 0, 0))
  lcd.drawText(myWidget.zone.x,myWidget.zone.y,"YaapuMaps requires",SMLSIZE+CUSTOM_COLOR)
  lcd.drawText(myWidget.zone.x,myWidget.zone.y+16,"full screen",SMLSIZE+CUSTOM_COLOR)
end

utils.validateZoomLevel = function(newZoom,conf,status,zoomLevels)
  -- no valid zoom table, all levels are allowed
  if zoomLevels == nil then
    return newZoom
  end
  -- check against valid zoom levels table
  if zoomLevels ~= nil then
    if zoomLevels[newZoom] == true then
      -- ok this level is allowed
      return newZoom
    end
  end
  -- not allowed, stick with current zoom
  return status.mapZoomLevel
end

local zoomDelayStart = getTime()

utils.decZoomLevel = function(conf,status,zoomLevels)
  if getTime() - zoomDelayStart < conf.mapWheelChannelDelay*10 then
    return status.mapZoomLevel
  end
  zoomDelayStart = getTime()
  local newZoom = status.mapZoomLevel == nil and conf.mapZoomLevel or status.mapZoomLevel
  while newZoom > conf.mapZoomMin
  do
    newZoom = newZoom - 1
    if zoomLevels ~= nil then
      if zoomLevels[newZoom] == true then
        return newZoom
      end
    else
      return newZoom
    end
  end
  return utils.validateZoomLevel(newZoom,conf,status,zoomLevels)
end

utils.incZoomLevel = function(conf,status,zoomLevels)
  if getTime() - zoomDelayStart < conf.mapWheelChannelDelay*10 then
    return status.mapZoomLevel
  end
  zoomDelayStart = getTime()
  local newZoom = status.mapZoomLevel == nil and conf.mapZoomLevel or status.mapZoomLevel
  while newZoom < conf.mapZoomMax
  do
    newZoom = newZoom + 1
    if zoomLevels ~= nil then
      if zoomLevels[newZoom] == true then
        return newZoom
      end
    else
      return newZoom
    end
  end
  return utils.validateZoomLevel(newZoom,conf,status,zoomLevels)
end

utils.getMapZoomLevel = function(myWidget,conf,status,customSensors)
  local chValue = getValue(conf.mapWheelChannelId)
  local newZoom = status.mapZoomLevel == nil and conf.mapZoomLevel or status.mapZoomLevel
  local zoomLevels = nil
  if customSensors ~= nil then
    zoomLevels = customSensors.zoomLevels
  end
  if conf.mapWheelChannelId > -1 then
    -- SW up (increase zoom detail)
    if chValue < -600 then
      if conf.mapProvider == 1 then
        return utils.decZoomLevel(conf,status,zoomLevels)
      else
        return utils.incZoomLevel(conf,status,zoomLevels)
      end
    end
    -- SW down (decrease zoom detail)
    if chValue > 600 then
      if conf.mapProvider == 1 then
        return utils.incZoomLevel(conf,status,zoomLevels)
      else
        return utils.decZoomLevel(conf,status,zoomLevels)
      end
    end
    -- switch is idle, force timer expire
    zoomDelayStart = getTime() - conf.mapWheelChannelDelay*10
  end
  return status.mapZoomLevel
end

-- Called when script is hidden @20Hz
local function background(myWidget)
  backgroundTasks(myWidget)
end

local slowTimer = getTime()

-- Called when script is visible
local function drawFullScreen(myWidget)
  if getTime() - slowTimer > 50 then
    -- check if current widget page changed
    slowTimer = getTime()
  end

  backgroundTasks(myWidget)

  lcd.setColor(CUSTOM_COLOR, utils.colors.darkblue)
  lcd.clear(CUSTOM_COLOR)

  if mapLayout ~= nil then
    mapLayout.draw(myWidget,drawLib,conf,telemetry,status,battery,alarms,frame,utils,customSensors,gpsStatuses,leftPanel,centerPanel,rightPanel)
  else
  -- Layout start
    if loadCycle == 3 then
      mapLayout = utils.doLibrary("mapslayout")
    end
  end

  -- no telemetry/minmax outer box
  if telemetryEnabled() == false then
    -- no telemetry inner box
    if not status.hideNoTelemetry then
      drawLib.drawNoTelemetryData(status,telemetry,utils,telemetryEnabled)
    end
    utils.drawBlinkBitmap("warn",0,0)
  end

  loadCycle=(loadCycle+1)%8
  collectgarbage()
  collectgarbage()
end

function refresh(myWidget)

  if myWidget.zone.h < 250 then
    fullScreenRequired(myWidget)
    return
  end
  drawFullScreen(myWidget)
end

return { name="YaapuMaps", options=options, create=create, update=update, background=background, refresh=refresh }
