local trainHelper = require "nightfury/signals/mainupdate/trainHelper"
local pathEvaluator = require "nightfury/signals/mainupdate/pathEvaluator"
local utils = require "nightfury/signals/utils"

local config_signalsToEvaluate = 4 -- 4 works well for home/distant. For 4 aspect signalling use 5. This should idealy be a config option
local config_lookAheadEdges = 100
local config_cameraRadiusSignalVisibleAt = 500 -- Can't see signal when camera radius is > 500
local config_debug = false


local signals = {}
signals.signals = {}
-- Table holds all placed Signals
signals.signalObjects = {}
signals.viewDistance = 2000
signals.pos = {0,0} -- Updated by event
signals.posRadius = 1000 -- Updated by event
signals.cockpitMode = false
signals.cockpitTrainEntityId = nil
signals.cockpitModeAtTime = nil -- We lock the cockpit mode for 2 seconds to prevent a race condition 
-- where a late arriving camera move makes us think we're out of cockpitMode

----------------------
--GUI Location Update!
--In cockpitMode the location Gui camera doesn't change but we can use the location of the train
--TODO: Maybe move this section to it's own file?

---Set's gui's camera position. Updated by event.
---We detect the game has left cockpitMode when the location starts updating again: the camera zooms to and tracks the train.
---When entering cockpit mode when the camera is following a train there is a race condition so we only allow
---detecting exiting cockpitMode after 2 seconds
---@param pos table<number> x,y position
---@param radius number
function signals.updateGuiCameraPos(pos, radius)
	if signals.cockpitMode then
		if pos[1] == signals.pos[1] and pos[2] == signals.pos[2] then
			-- No position change still in cockpitMode
			return
		elseif signals.cockpitModeAtTime ~= nil then
			-- We wait 2 seconds before we start detecting exit cockpitMode
			if os.clock() - signals.cockpitModeAtTime > 2  then
				signals.cockpitModeAtTime = nil
			end
		else
			-- The location is updating so must hae exited cockpitMode
			signals.cockpitMode = false
			signals.cockpitTrainEntityId = nil
		end
	end

	signals.pos = pos
	signals.posRadius = radius
end
function signals.setCockpitMode(vehicleId)
	if trainHelper.isTrain(vehicleId)  then
		signals.cockpitMode = true
		signals.cockpitTrainEntityId = vehicleId
		signals.cockpitModeAtTime = os.clock()
	end
end
function signals.getPosition()
	if signals.cockpitMode and signals.cockpitTrainEntityId then
		local trainPos = trainHelper.getTrainPos(signals.cockpitTrainEntityId)
		if trainPos then
			return trainPos
		end
	end
	return signals.pos
end
----------------------

-- 3 states: None, Changed, WasChanged

--- Function checks move_path of all the trains
--- If a signal is found it's current state is checked
--- after that the signal will be changed accordingly
function signals.updateSignals()
	if signals.posRadius > config_cameraRadiusSignalVisibleAt and signals.cockpitMode == false then
		return
	end

	if config_debug then
		print("----------")
		print("Better Signals ", signals.viewDistance)
		print("----------")
	end
	local start_time = os.clock()

	local pos = signals.getPosition()
	local trains = trainHelper.getTrainsToEvaluate(pos, signals.viewDistance)
	signals.resetAll()

	local trainLocsEdgeIds = trainHelper.computeTrainLocs(trains)

	local signalsToBeUpdated = signals.computeSignalPaths(trains, trainLocsEdgeIds)

	signals.updateConstructions(signalsToBeUpdated)

	signals.throwSignalToRed()
	if config_debug then
		print(string.format("updateSignals. Elapsed time: %.4f", os.clock() - start_time))
	end
end

function signals.computeSignalPaths(trains, trainLocsEdgeIds)
	local signalsToBeUpdated = {}

	-- Compute signals in path of each train
	for vehicleId, vehComp in pairs(trains) do
		if config_debug then
			print("----------")
			local vehNameEnt = api.engine.getComponent(vehicleId, api.type.ComponentType.NAME)
			print("Vehicle " .. vehicleId .. " Name: " .. vehNameEnt.name)
		end

		local lineName = trainHelper.getLineNameOfVehicle(vehComp)
		local signalPaths = pathEvaluator.evaluate(vehicleId, config_lookAheadEdges, config_signalsToEvaluate, trainLocsEdgeIds, signals.signalObjects, signals.signals)

		for _, signalPath in ipairs(signalPaths) do
			signalPath.lineName = lineName.name
			signals.recordSignalToBeUpdated(signalPath, signalsToBeUpdated)
		end
	end
	return signalsToBeUpdated
end

function signals.recordSignalToBeUpdated(signalPath, signalsToBeUpdated)
	local signalKey = "signal" .. signalPath.entity
	if signalsToBeUpdated[signalKey] then
		-- two trains want to update the same signal. Prioritise green signal state over red
		-- Assumption here is a train with green state would be closer to the signal than one with red
		local existingPath = signalsToBeUpdated[signalKey]
		if existingPath.signal_state < signalPath.signal_state then
			signalsToBeUpdated[signalKey] = signalPath
		elseif existingPath.signal_state == 1 and signalPath.signal_state == 1 then
			-- Both green, use next signal state to prioritise so we don't get a signal showing yellow followed by signal showing green
			if existingPath.following_signal and signalPath.following_signal then
				if existingPath.following_signal.signal_state < signalPath.following_signal.signal_state then
					signalsToBeUpdated[signalKey] = signalPath
				end
			elseif not existingPath.following_signal and signalPath.following_signal then
				signalsToBeUpdated[signalKey] = signalPath
			end
		end
	else
		signalsToBeUpdated[signalKey] = signalPath
	end
end

function signals.updateConstructions(signalsToBeUpdated)
	for signalKey, signalPath in pairs(signalsToBeUpdated) do
		local tableEntry = signals.signalObjects[signalKey]
		if tableEntry then
			local newCheckSum = 0
			for _, betterSignal in pairs(tableEntry.signals) do
				signals.signalObjects[signalKey].changed = 1
				local conSignal = betterSignal.construction

				if conSignal then
					local oldConstruction = game.interface.getEntity(conSignal)
					if oldConstruction and oldConstruction.params then
						oldConstruction.params.previous_speed = signalPath.previous_speed
						oldConstruction.params.signal_state = signalPath.signal_state
						oldConstruction.params.signal_speed = signalPath.signal_speed
						oldConstruction.params.following_signal = signalPath.following_signal
						oldConstruction.params.paramsOverride = signalPath.paramsOverride
						if signalPath.lineName ~= "ERROR" then
							oldConstruction.params.currentLine = signalPath.lineName
						end
						
						newCheckSum = signalPath.checksum

						if (not signals.signalObjects[signalKey].checksum) or (newCheckSum ~= signals.signalObjects[signalKey].checksum) then
							utils.updateConstruction(oldConstruction, conSignal)
							
							-- TODO: Should I take this out? I use it for debugging but not necessary in code
							if config_debug then
								local followingState = -1
								if signalPath.following_signal then
									followingState = signalPath.following_signal.signal_state
								end

								print("utils.updateConstruction for ", signalPath.entity, newCheckSum, signals.signalObjects[signalKey].checksum, followingState,signalPath.signal_state )
							end
						end
					else
						print("Couldn't access params")
					end
				end
			end

			signals.signalObjects[signalKey].checksum = newCheckSum
		end
	end
end

function signals.resetAll()
    for _, value in pairs(signals.signalObjects) do
        if value.changed then
            value.changed = value.changed * 2
        end
    end
end

function signals.throwSignalToRed()
	for _, value in pairs(signals.signalObjects) do
		if value.changed == 2 then
			for _, signal in pairs(value.signals) do
				local oldConstruction = game.interface.getEntity(signal.construction)
				if oldConstruction then
					oldConstruction.params.signal_state = 0
					oldConstruction.params.previous_speed = nil

					utils.updateConstruction(oldConstruction, signal.construction)
				end
				value.changed = 0
			end
		end
	end
end

-- Registers new signal
-- @param signal signal entityid
-- @param construct construction entityid
function signals.createSignal(signal, construct, signalType, isAnimated)
	local signalKey = "signal" .. signal

	if not signals.signalObjects[signalKey] then
		signals.signalObjects[signalKey] = {}
		signals.signalObjects[signalKey].signals = {}
	end

	signals.signalObjects[signalKey].changed = 0
	signals.signalObjects[signalKey].signalType = signalType
	signals.signalObjects[signalKey].construction = construct

	local newSignal = {}

	newSignal.construction = construct
	newSignal.isAnimated = isAnimated

	table.insert(signals.signalObjects[signalKey].signals, newSignal)
end

function signals.removeSignalBySignal(signal)
	signals.signalObjects["signal" .. signal] = nil
end

function signals.removeSignalByConstruction(construction)
	for _, value in pairs(signals.signalObjects) do
		for index, signal in ipairs(value.signals) do
			if signal.construction == construction then
				table.remove(value.signals, index)
				print("Removed Signal " .. construction .. " at index: " .. index)
				return
			end
		end
	end
end

function signals.removeTunnel(signalConstructionId)
	local oldConstruction = game.interface.getEntity(signalConstructionId)
	if oldConstruction then
		oldConstruction.params.better_signals_tunnel_helper = 0

		utils.updateConstruction(oldConstruction, signalConstructionId)
	end
end

function signals.save()
	return signals.signalObjects
end


function signals.load(state)
	if state then
		signals.signalObjects = state
	end
end

return signals

