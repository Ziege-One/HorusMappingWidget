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

--[[
  for info see https://github.com/heldersepu/GMapCatcher
  
  Notes:
  - tiles need to be resized down to 100x100 from original size of 256x256
  - at max zoom level (-2) 1 tile = 100px = 76.5m
]]

--------------------------
-- MINI HUD
--------------------------

--------------------------
-- MAP properties
--------------------------


--#define SAMPLES 10



--------------------------
-- CUSTOM SENSORS SUPPORT
--------------------------

local customSensorXY = {
  -- horizontal
  { 80, 220, 80, 232},
  { 160, 220, 160, 232},
  { 240, 220, 240, 232},
  { 320, 220, 320, 232},
  { 400, 220, 400, 232},
  { 478, 220, 478, 232},
  -- vertical
  { 478, 25, 478, 37},
  { 478, 75, 478, 87},
  { 478, 125, 478, 137},
  { 478, 175, 478, 187},
}

-- model and opentx version
local ver, radio, maj, minor, rev = getVersion()

-- map support
local posUpdated = false
local myScreenX, myScreenY
local homeScreenX, homeScreenY
local estimatedHomeScreenX, estimatedHomeScreenY
local tile_x,tile_y,offset_x,offset_y
local tiles = {}
local mapBitmapByPath = {}
local nomap = nil
local world_tiles
local tiles_per_radian
local tile_dim
local scaleLen
local scaleLabel
local posHistory = {}
local homeNeedsRefresh = true
local sample = 0
local sampleCount = 0
local lastPosUpdate = getTime()
local lastPosSample = getTime()
local lastHomePosUpdate = getTime()
local lastZoomLevel = -99
local estimatedHomeGps = {
  lat = nil,
  lon = nil
}

local row
local column 

local lastProcessCycle = getTime()
local processCycle = 0

local avgDistSamples = {}
local avgDist = 0;
local avgDistSum = 0;
local avgDistSample = 0;
local avgDistSampleCount = 0;
local avgDistLastSampleTime = getTime();
avgDistSamples[0] = 0


local coord_to_tiles = nil
local tiles_to_path = nil
local MinLatitude = -85.05112878;
local MaxLatitude = 85.05112878;
local MinLongitude = -180;
local MaxLongitude = 180;





local function clip(n, min, max)
  return math.min(math.max(n, min), max)
end

local function tiles_on_level(conf,level)
  if conf.mapProvider == 1 then
    return bit32.lshift(1,17 - level)
  else
    return 2^level
  end
end

--[[
  total tiles on the web mercator projection = 2^zoom*2^zoom
--]]
local function get_tile_matrix_size_pixel(level)
    local size = 2^level * 100
    return size, size
end

--[[
  https://developers.google.com/maps/documentation/javascript/coordinates
  https://github.com/judero01col/GMap.NET
  
  Questa funzione ritorna il pixel (assoluto) associato alle coordinate.
  La proiezione di mercatore è una matrice di pixel, tanto più grande quanto è elevato il valore dello zoom.
  zoom 1 = 1x1 tiles
  zoom 2 = 2x2 tiles
  zoom 3 = 4x4 tiles
  ...
  in cui ogni tile è di 256x256 px.
  in generale la matrice ha dimensioni 2^(zoom-1)*2^(zoom-1)
  Per risalire al singolo tile si divide per 256 (largezza del tile):
  
  tile_x = math.floor(x_coord/256)
  tile_y = math.floor(y_coord/256)
  
  Le coordinate relative all'interno del tile si calcolano con l'operatore modulo a partire dall'angolo in alto a sx
  
  x_offset = x_coord%256
  y_offset = y_coord%256
  
  Su filesystem il percorso è /tile_y/tile_x.png
--]]
local function google_coord_to_tiles(conf, lat, lng, level)
  lat = clip(lat, MinLatitude, MaxLatitude)
  lng = clip(lng, MinLongitude, MaxLongitude)

  local x = (lng + 180) / 360
  local sinLatitude = math.sin(lat * math.pi / 180)
  local y = 0.5 - math.log((1 + sinLatitude) / (1 - sinLatitude)) / (4 * math.pi)

  local mapSizeX, mapSizeY = get_tile_matrix_size_pixel(level)

  -- absolute pixel coordinates on the mercator projection at this zoom level
  local rx = clip(x * mapSizeX + 0.5, 0, mapSizeX - 1)
  local ry = clip(y * mapSizeY + 0.5, 0, mapSizeY - 1)
  -- return tile_x, tile_y, offset_x, offset_y
  return math.floor(rx/100), math.floor(ry/100), math.floor(rx%100), math.floor(ry%100)
end

local function gmapcatcher_coord_to_tiles(conf, lat, lon, level)
  local x = world_tiles / 360 * (lon + 180)
  local e = math.sin(lat * (1/180 * math.pi))
  local y = world_tiles / 2 + 0.5 * math.log((1+e)/(1-e)) * -1 * tiles_per_radian
  return math.floor(x % world_tiles), math.floor(y % world_tiles), math.floor((x - math.floor(x)) * 100), math.floor((y - math.floor(y)) * 100)
end

local function google_tiles_to_path(conf, tile_x, tile_y, level)
  return string.format("/%d/%d/s_%d.jpg", level, tile_y, tile_x)
end

local function gmapcatcher_tiles_to_path(conf, tile_x, tile_y, level)
  return string.format("/%d/%d/%d/%d/s_%d.png", level, tile_x/1024, tile_x%1024, tile_y/1024, tile_y%1024)
end

local function getTileBitmap(conf,tilePath)
  local fullPath = "/SCRIPTS/YAAPU/MAPS/"..conf.mapType..tilePath
  -- check cache
  if mapBitmapByPath[tilePath] ~= nil then
    return mapBitmapByPath[tilePath]
  end
  
  local bmp = Bitmap.open(fullPath)
  local w,h = Bitmap.getSize(bmp)
  
  if w > 0 then
    mapBitmapByPath[tilePath] = bmp
    return bmp
  else
    if nomap == nil then
      nomap = Bitmap.open("/SCRIPTS/YAAPU/MAPS/nomap.png")
    end
    mapBitmapByPath[tilePath] = nomap
    return nomap
  end
end

local function loadAndCenterTiles(conf,tile_x,tile_y,offset_x,offset_y,width,level)
  -- determine if upper or lower center tile
  local yy = 2
  if offset_y > 100/2 and not conf.enableFullscreen then
    yy = 1
  end
  for x=1,column                                             
  do
    for y=1,row                                           
    do
      local tile_path = tiles_to_path(conf, tile_x+x-column+2, tile_y+y-yy, level)	  
      local idx = column*(y-1)+x
	   
      if tiles[idx] == nil then
        tiles[idx] = tile_path
      else
        if tiles[idx] ~= tile_path then
          tiles[idx] = nil
          collectgarbage()
          collectgarbage()
          tiles[idx] = tile_path
        end
      end
    end
  end
  -- release unused cached images
  for path, bmp in pairs(mapBitmapByPath) do
    local remove = true
    for i=1,#tiles
    do
      if tiles[i] == path then
        remove = false
      end
    end
    if remove then
      mapBitmapByPath[path]=nil
    end
  end
  -- force a call to destroyBitmap()
  collectgarbage()
  collectgarbage()
end

local function drawTiles(conf,drawLib,utils,width,xmin,xmax,ymin,ymax,color,level)
  for x=1,column
  do
    for y=1,row
    do
      local idx = column*(y-1)+x
      if tiles[idx] ~= nil then
        lcd.drawBitmap(getTileBitmap(conf,tiles[idx]), xmin+(x-1)*100, ymin+(y-1)*100)
      end
    end
  end
  if conf.enableMapGrid then
    -- draw grid
    for x=1,column-1
    do
      lcd.drawLine(xmin+x*100,ymin,xmin+x*100,ymax,DOTTED,color)
    end
    
    for y=1,row-1
    do
      lcd.drawLine(xmin,ymin+y*100,xmax,ymin+y*100,DOTTED,color)
    end
  end
  -- map overlay
  if conf.enableFullscreen then
	lcd.drawBitmap(utils.getBitmap("maps_box_380x20"),50,265-20) --160x90  
	-- draw 50m or 150ft line at max zoom
	lcd.setColor(CUSTOM_COLOR,utils.colors.white)
	lcd.drawLine(50,265-7,5+scaleLen,265-7,SOLID,CUSTOM_COLOR)
	lcd.drawText(50,265-21,scaleLabel,SMLSIZE+CUSTOM_COLOR)
  else
	lcd.drawBitmap(utils.getBitmap("maps_box_380x20"),5,ymin+2*100-20) --160x90  
	-- draw 50m or 150ft line at max zoom
	lcd.setColor(CUSTOM_COLOR,utils.colors.white)
	lcd.drawLine(xmin+5,ymin+2*100-7,xmin+5+scaleLen,ymin+2*100-7,SOLID,CUSTOM_COLOR)
	lcd.drawText(xmin+5,ymin+2*100-21,scaleLabel,SMLSIZE+CUSTOM_COLOR)
  end	
end

local function getScreenCoordinates(minX,minY,tile_x,tile_y,offset_x,offset_y,level)
  -- is this tile on screen ?
  local tile_path = tiles_to_path(conf, tile_x, tile_y, level)
  local onScreen = false
  
  for x=1,column
  do
    for y=1,row
    do
      local idx = column*(y-1)+x
      if tiles[idx] == tile_path then
        -- ok it's on screen
        return minX + (x-1)*100 + offset_x, minY + (y-1)*100 + offset_y
      end
    end
  end
  -- force offscreen up
  return LCD_W/2, -10
end

local function drawMap(myWidget,drawLib,conf,telemetry,status,utils,level)
  if tiles_to_path == nil or coord_to_tiles == nil then
    return
  end
  local minY = 18
  local maxY = minY+2*100
  
  local minX = 0 
  local maxX = minX+4*100
  
  if conf.enableFullscreen then
    minY = 0
	minX = -10
	maxY = 272
	maxX = 480
  else

  end

  if telemetry.lat ~= nil and telemetry.lon ~= nil then
    -- position update
    if getTime() - lastPosUpdate > 50 then
      posUpdated = true
      lastPosUpdate = getTime()
      -- current vehicle tile coordinates
      tile_x,tile_y,offset_x,offset_y = coord_to_tiles(conf,telemetry.lat,telemetry.lon,level)
      -- viewport relative coordinates
      myScreenX,myScreenY = getScreenCoordinates(minX,minY,tile_x,tile_y,offset_x,offset_y,level)
      -- check if offscreen, and increase border on X axis
      local myCode = drawLib.computeOutCode(myScreenX, myScreenY, minX+50, minY+50, maxX-50, maxY-50);
      
      -- center vehicle on screen
      if myCode > 0 then
        loadAndCenterTiles(conf, tile_x, tile_y, offset_x, offset_y, 4, level)
        -- after centering screen position needs to be computed again
        tile_x,tile_y,offset_x,offset_y = coord_to_tiles(conf,telemetry.lat,telemetry.lon,level)
        myScreenX,myScreenY = getScreenCoordinates(minX,minY,tile_x,tile_y,offset_x,offset_y,level)
      end
    end
    -- home position update
    if getTime() - lastHomePosUpdate > 50 and posUpdated then
      lastHomePosUpdate = getTime()
      if homeNeedsRefresh then
        -- update home, schedule estimated home update
        homeNeedsRefresh = false
        if telemetry.homeLat ~= nil then
          -- current vehicle tile coordinates
          tile_x,tile_y,offset_x,offset_y = coord_to_tiles(conf,telemetry.homeLat,telemetry.homeLon,level)
          -- viewport relative coordinates
          homeScreenX,homeScreenY = getScreenCoordinates(minX,minY,tile_x,tile_y,offset_x,offset_y,level)
        end
      else
        -- update estimated home, schedule home update
        homeNeedsRefresh = true
        estimatedHomeGps.lat,estimatedHomeGps.lon = utils.getHomeFromAngleAndDistance(telemetry)
        if estimatedHomeGps.lat ~= nil then
          local t_x,t_y,o_x,o_y = coord_to_tiles(conf,estimatedHomeGps.lat,estimatedHomeGps.lon,level)
          -- viewport relative coordinates
          estimatedHomeScreenX,estimatedHomeScreenY = getScreenCoordinates(minX,minY,t_x,t_y,o_x,o_y,level)        
        end
      end
      collectgarbage()
      collectgarbage()
    end
    
    -- position history sampling
    if getTime() - lastPosSample > 50 and posUpdated then
        lastPosSample = getTime()
        posUpdated = false
        -- points history
        local path = tiles_to_path(conf, tile_x, tile_y, level)
        posHistory[sample] = { path, offset_x, offset_y }
        collectgarbage()
        collectgarbage()
        sampleCount = sampleCount+1
        sample = sampleCount%conf.mapTrailDots
    end
    
    -- draw map tiles
    lcd.setColor(CUSTOM_COLOR,utils.colors.yellow)
    drawTiles(conf,drawLib,utils,4,minX,maxX,minY,maxY,CUSTOM_COLOR,level)
    
    -- draw home
    if telemetry.homeLat ~= nil and telemetry.homeLon ~= nil and homeScreenX ~= nil then
      local homeCode = drawLib.computeOutCode(homeScreenX, homeScreenY, minX+11, minY+10, maxX-11, maxY-10);
      if homeCode == 0 then
        lcd.drawBitmap(utils.getBitmap("homeorange"),homeScreenX-11,homeScreenY-10)
      end
    end
    
    --[[
    -- draw estimated home (debug info)
    if estimatedHomeGps.lat ~= nil and estimatedHomeGps.lon ~= nil and estimatedHomeScreenX ~= nil then
      local homeCode = drawLib.computeOutCode(estimatedHomeScreenX, estimatedHomeScreenY, minX+11, minY+10, maxX-11, maxY-10);
      if homeCode == 0 then
        lcd.setColor(CUSTOM_COLOR,COLOR_RED)
        lcd.drawRectangle(estimatedHomeScreenX-11,estimatedHomeScreenY-11,20,20,CUSTOM_COLOR)
      end
    end
    --]]
    
    -- draw vehicle
    if myScreenX ~= nil then
      lcd.setColor(CUSTOM_COLOR,utils.colors.white)
      drawLib.drawRArrow(myScreenX,myScreenY,17-5,telemetry.yaw,CUSTOM_COLOR)
      lcd.setColor(CUSTOM_COLOR,utils.colors.black)
      drawLib.drawRArrow(myScreenX,myScreenY,17,telemetry.yaw,CUSTOM_COLOR)
    end
    -- draw gps trace
    lcd.setColor(CUSTOM_COLOR,utils.colors.yellow)
    for p=0, math.min(sampleCount-1,conf.mapTrailDots-1)
    do
      if p ~= (sampleCount-1)%conf.mapTrailDots then
        for x=1,column
        do
          for y=1,row
          do
            local idx = column*(y-1)+x
            -- check if tile is on screen
            if tiles[idx] == posHistory[p][1] then
              lcd.drawFilledRectangle(minX + (x-1)*100 + posHistory[p][2]-1, minY + (y-1)*100 + posHistory[p][3]-1,3,3,CUSTOM_COLOR)
            end
          end
        end
      end
    end
    lcd.drawBitmap(utils.getBitmap("maps_box_60x16"),3,24)
    lcd.setColor(CUSTOM_COLOR,utils.colors.white)
    lcd.drawText(0+5,18+5,string.format("zoom:%d",level),SMLSIZE+CUSTOM_COLOR)
    lcd.setColor(CUSTOM_COLOR,utils.colors.white)
  end
  lcd.setColor(CUSTOM_COLOR,utils.colors.white)
end

local function drawCustomSensors(x,customSensors,utils,status)
    --lcd.setColor(CUSTOM_COLOR,lcd.RGB(0,75,128))
    --[[
    lcd.setColor(CUSTOM_COLOR,COLOR_SENSORS)
    lcd.drawFilledRectangle(0,194,LCD_W,35,CUSTOM_COLOR)
    --]]

    lcd.setColor(CUSTOM_COLOR,utils.colors.black)
    lcd.drawRectangle(400,18,80,201,CUSTOM_COLOR)
    for l=1,3
    do
      lcd.drawLine(400,18+(l*50),479,18+(l*50),SOLID,CUSTOM_COLOR)
    end
    local label,data,prec,mult,flags,sensorConfig
    for i=1,10
    do
      if customSensors.sensors[i] ~= nil then 
        sensorConfig = customSensors.sensors[i]
        
        -- check if sensor is a timer
        if sensorConfig[4] == "" then
          label = string.format("%s",sensorConfig[1])
        else
          label = string.format("%s(%s)",sensorConfig[1],sensorConfig[4])
        end
        -- draw sensor label
        lcd.setColor(CUSTOM_COLOR,utils.colors.lightgrey)
        lcd.drawText(x+customSensorXY[i][1], customSensorXY[i][2],label, SMLSIZE+RIGHT+CUSTOM_COLOR)
        
        local timerId = string.match(string.lower(sensorConfig[2]), "timer(%d+)")
        if timerId ~= nil then
          lcd.setColor(CUSTOM_COLOR,utils.colors.white)
          -- lua timers are zero based
          if tonumber(timerId) > 0 then
            timerId = tonumber(timerId) -1
          end
          -- default font size
          flags = sensorConfig[7] == 1 and 0 or MIDSIZE
          local voffset = flags==0 and 6 or 0
          lcd.drawTimer(x+customSensorXY[i][3], customSensorXY[i][4]+voffset, model.getTimer(timerId).value, flags+CUSTOM_COLOR+RIGHT)
        else
          mult =  sensorConfig[3] == 0 and 1 or ( sensorConfig[3] == 1 and 10 or 100 )
          prec =  mult == 1 and 0 or (mult == 10 and 32 or 48)
          
          local sensorName = sensorConfig[2]..(status.showMinMaxValues == true and sensorConfig[6] or "")
          local sensorValue = getValue(sensorName) 
          local value = (sensorValue+(mult == 100 and 0.005 or 0))*mult*sensorConfig[5]        
          
          -- default font size
          flags = sensorConfig[7] == 1 and 0 or MIDSIZE
          
          -- for sensor 3,4,5,6 reduce font if necessary
          if math.abs(value)*mult > 99999 then
            flags = 0
          end
          
          local color = utils.colors.white
          local sign = sensorConfig[6] == "+" and 1 or -1
          -- max tracking, high values are critical
          if math.abs(value) ~= 0 and status.showMinMaxValues == false then
            color = ( sensorValue*sign > sensorConfig[9]*sign and lcd.RGB(255,70,0) or (sensorValue*sign > sensorConfig[8]*sign and utils.colors.yellow or utils.colors.white))
          end
          
          lcd.setColor(CUSTOM_COLOR,color)
          
          local voffset = flags==0 and 6 or 0
          -- if a lookup table exists use it!
          if customSensors.lookups[i] ~= nil and customSensors.lookups[i][value] ~= nil then
            lcd.drawText(x+customSensorXY[i][3], customSensorXY[i][4]+voffset, customSensors.lookups[i][value] or value, flags+RIGHT+CUSTOM_COLOR)
          else
            lcd.drawNumber(x+customSensorXY[i][3], customSensorXY[i][4]+voffset, value, flags+RIGHT+prec+CUSTOM_COLOR)
          end
        end
      end
    end
end

local function init(conf,utils,level)
  if level == nil then
    return
  end
  
  if conf.enableFullscreen then
	row = 3
	column = 5
  else
  	row = 2
	column = 4
  end
  
  if level ~= lastZoomLevel then
    utils.clearTable(tiles)
    
    utils.clearTable(mapBitmapByPath)
    
    utils.clearTable(posHistory)
    sample = 0
    sampleCount = 0    
    
    world_tiles = tiles_on_level(conf, level)
    tiles_per_radian = world_tiles / (2 * math.pi)
  
    if conf.mapProvider == 1 then
      coord_to_tiles = gmapcatcher_coord_to_tiles
      tiles_to_path = gmapcatcher_tiles_to_path
      tile_dim = (40075017/world_tiles) * unitScale -- m or ft
      scaleLabel = tostring((unitScale==1 and 1 or 3)*50*2^(level+2))..unitLabel
      scaleLen = ((unitScale==1 and 1 or 3)*50*2^(level+2)/tile_dim)*100
    elseif conf.mapProvider == 2 then
      coord_to_tiles = google_coord_to_tiles
      tiles_to_path = google_tiles_to_path
      tile_dim = (40075017/world_tiles) * unitScale -- m or ft
      scaleLabel = tostring((unitScale==1 and 1 or 3)*50*2^(20-level))..unitLabel
      scaleLen = ((unitScale==1 and 1 or 3)*50*2^(20-level)/tile_dim)*100
    end
--[[    
    tile_dim = (40075017/world_tiles) * unitScale -- m or ft
    scaleLen = ((unitScale==1 and 1 or 3)*50*(level+3)/tile_dim)*TILES_SIZE
    scaleLabel = tostring((unitScale==1 and 1 or 3)*50*(level+3))..unitLabel
--]]
    lastZoomLevel = level
  end
end

local function draw(myWidget,drawLib,conf,telemetry,status,battery,alarms,frame,utils,customSensors,gpsStatuses,leftPanel,centerPanel,rightPanel)
  -- initialize maps
  init(conf, utils, status.mapZoomLevel)
  drawMap(myWidget,drawLib,conf,telemetry,status,utils,status.mapZoomLevel)
  --[[ 
  -- No HUD support for now
  drawHud(myWidget,drawLib,conf,telemetry,status,battery,utils)
  --]]
  utils.drawTopBar()
  -- gps status, draw coordinatyes if good at least once
  lcd.setColor(CUSTOM_COLOR,utils.colors.white)
  if telemetry.lon ~= nil and telemetry.lat ~= nil then
	if conf.enableFullscreen then
		lcd.drawText(330,265-21,utils.decToDMSFull(telemetry.lat),SMLSIZE+CUSTOM_COLOR+RIGHT)
		lcd.drawText(430,265-21,utils.decToDMSFull(telemetry.lon,telemetry.lat),SMLSIZE+CUSTOM_COLOR+RIGHT)
	else
	    -- bottom bar                        
		lcd.setColor(CUSTOM_COLOR,utils.colors.black)											
		lcd.drawFilledRectangle(0,200+18,480,LCD_H-(200+18),CUSTOM_COLOR) 
		lcd.setColor(CUSTOM_COLOR,utils.colors.white)		
		lcd.drawText(280,200+18-21,utils.decToDMSFull(telemetry.lat),SMLSIZE+CUSTOM_COLOR+RIGHT)
		lcd.drawText(380,200+18-21,utils.decToDMSFull(telemetry.lon,telemetry.lat),SMLSIZE+CUSTOM_COLOR+RIGHT)
		  -- custom sensors
		if customSensors ~= nil then
			drawCustomSensors(0,customSensors,utils,status)
		end
    end 		
  end

end

local function background(myWidget,conf,telemetry,status,utils)
end

return {draw=draw,background=background}

