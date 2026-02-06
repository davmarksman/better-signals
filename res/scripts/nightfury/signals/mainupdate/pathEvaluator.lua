local utils = require "nightfury/signals/utils"

local SIGNAL_UNIDIR = 0
local SIGNAL_ONEWAY = 1
local SIGNAL_WAYPOINT = 2

local SIGNAL_STATE_RED = 0
local SIGNAL_STATE_GREEN = 1

local pathEvaluator = {}
local config_debug = false

-- TODO Edge speeds

---We evaluate a train's path and create blocks protected by better signals
---@param vehicleId any
---@param lookAheadEdges any -- Max no of edges to look ahead on path before stopping
---@param signalsToEvaluate any -- Max no of signals to find on the path before stopping
---@param trainLocsEdgeEntityIds any -- edgeEntityIds of location of nearby trains
---@param main_signalObjects any -- signals.signalObjects
---@param main_signals any -- signals.signals
---@return SignalPath
function pathEvaluator.evaluate(vehicleId,  lookAheadEdges, signalsToEvaluate, trainLocsEdgeEntityIds, main_signalObjects, main_signals)
	---@class SignalPath Represents a block of track protected by a signal
	---@field entity number Entity from api.engine.system.signalSystem.getSignal(). Should rename but keeping for backwards compatibility
	---@field signal_state number
	---@field signal_speed number
	---@field incomplete boolean
	---@field following_signal SignalPath
	---@field previous_speed boolean
	---@field checksum number
	---@field paramsOverride table

	local res = {}

	local path = api.engine.getComponent(vehicleId, api.type.ComponentType.MOVE_PATH)
	-- ignore stopped trains 
	if path.dyn.speed == 0 or #path.path.edges == 1 or path.dyn.pathPos.edgeIndex < 0 then
		return res
	end

	---1st evaluation: We split path into blocks protected by signals/end station. Each block starts with a signal
	local signalsInPath = pathEvaluator.findSignalsInPath(path,lookAheadEdges, signalsToEvaluate, main_signalObjects, main_signals)
	local passedSwitchOrLevelCrossing = false

	-- 2nd evaluation: We determine signal states for each main signal and prepare to return as SignalPath
	-- Order is important as we add information from previous and following signals to the current signal
	local mainSignals = {}
	for i = 1, #signalsInPath, 1 do
		local signalAndBlock = signalsInPath[i]

		local signalState = 0
		if signalAndBlock.isStation == false then
			if signalAndBlock.hasSwitch then
				passedSwitchOrLevelCrossing = true
			end
			
			-- Recalculate signal state to make more signals green
			signalState = pathEvaluator.recalcSignalState(signalAndBlock, trainLocsEdgeEntityIds, i==#signalsInPath, passedSwitchOrLevelCrossing)
		end

		local signalPath = {}
		signalPath.entity = signalAndBlock.signalListEntityId
		signalPath.signal_state = signalState
		signalPath.signal_speed = signalAndBlock.minSpeed
		signalPath.incomplete = false
		signalPath.paramsOverride = signalAndBlock.paramsOverride

		if #mainSignals >0 then
			signalPath.previous_speed = mainSignals[#mainSignals].signal_speed
			mainSignals[#mainSignals].following_signal = signalPath
		end

		table.insert(mainSignals, signalPath)
	end

	-- 3rd evaluation create presignals between the main signals. We do this after the 2nd evaluation because it 2nd sets following_signal, and previous_speed which we need
	-- A presignal is just a copy of the main signal it's for
	for i = 1, #mainSignals, 1 do
		local signalPath = mainSignals[i]
		local presignalsTable = signalsInPath[i].presignalsEntityIds

		-- Create presignals
		for _, entityId in pairs(presignalsTable) do
			local preSignalTable = utils.deepCopy(signalPath)
			preSignalTable.entity = entityId
	
			if config_debug then
				local signalAndBlock = signalsInPath[i]
				print("Pre signal at ", signalAndBlock.edgeEntityIdOn, preSignalTable.entity, preSignalTable.signal_state, preSignalTable.signal_speed, preSignalTable.hasSwitch, utils.dictToString(signalPath.paramsOverride))
			end
			table.insert(res, preSignalTable)
		end

		-- Don't forget to add in the main signal
		if config_debug then
			local signalAndBlock = signalsInPath[i]
			print("Signal at ", signalAndBlock.edgeEntityIdOn, signalPath.entity, signalPath.signal_state, signalPath.signal_speed, signalAndBlock.hasSwitch, utils.dictToString(signalPath.paramsOverride))
		end
		table.insert(res, signalPath)
	end

	-- 4th evaluation: calc checksums. We do in reverse order to include following signal in checksum
	utils.addChecksumToSignals(res)
	if config_debug then
		for _, val in pairs(res) do
			print("checksum", val.entity, val.checksum)
		end
	end

	return res
end

---First evaluation: We convert path into blocks protected by signals/end station
---@param path any
---@param lookAheadEdges any
---@param signalsToEvaluate any
---@param main_signalObjects any -- signals.signalObjects
---@param main_signals any -- signals.signals
---@return [BlockInfo]
function pathEvaluator.findSignalsInPath(path, lookAheadEdges, signalsToEvaluate, main_signalObjects, main_signals)
	---@class BlockInfo Represents a block of track with a signal or a station
	---@field edges table<number> nil when isStation is true
	---@field signalComp any
	---@field signalListEntityId number -- The entity of the SignalList 
	---@field hasSwitch boolean
	---@field isStation boolean
	---@field edgeEntityIdOn number
	---@field minSpeed number
	---@field presignalsEntityIds [string]
	---@field paramsOverride table

	local blocks = {}
	local presignalsForNextBlock = {}

	if path and path.path and #path.path.edges > 2 then
		local pathStart = math.max(path.dyn.pathPos.edgeIndex, 1)
		local pathEnd = math.min(#path.path.edges, pathStart + lookAheadEdges)
		local pathIndex = pathStart
		local shouldContinueSearch = true

		while shouldContinueSearch do
			local currentEdge = path.path.edges[pathIndex]
			local edgeEntityId = currentEdge.edgeId.entity

			local transportNetwork = api.engine.getComponent(currentEdge.edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK)
			local speed = math.floor(utils.getEdgeSpeed(currentEdge.edgeId, transportNetwork))

			if #blocks > 0 then
				blocks[#blocks].minSpeed = math.min(blocks[#blocks].minSpeed, speed)
		
				local isSwitchBranch = pathEvaluator.isAfterSwitch(transportNetwork)
				if isSwitchBranch then
					blocks[#blocks].hasSwitch = true
				end
			end

			-- FYI sometimes the edgeId is duplicated in the path (seems when there is a signal on the edge). dir is needed to identify which one has signal
			local potentialSignal = api.engine.system.signalSystem.getSignal(currentEdge.edgeId, currentEdge.dir)
			if potentialSignal and potentialSignal.entity and potentialSignal.entity ~= -1 then
				local signalComponent = api.engine.getComponent(potentialSignal.entity, api.type.ComponentType.SIGNAL_LIST)
				if signalComponent and signalComponent.signals and #signalComponent.signals > 0 then
					local signal = signalComponent.signals[1]

					if pathEvaluator.isMainSignal(signal, potentialSignal.entity, main_signalObjects, main_signals) then
						local signalInfo = {
							edges = {},
							signalComp = signalComponent,
							signalListEntityId = potentialSignal.entity,
							hasSwitch = false,
							isStation = false,
							edgeEntityIdOn = edgeEntityId,
							minSpeed = speed,
							presignalsEntityIds = presignalsForNextBlock
						}
						table.insert(blocks, signalInfo)
						presignalsForNextBlock = {}
					elseif pathEvaluator.isASignal(signal, potentialSignal.entity, main_signalObjects) then
						-- Presignal/Hybrid in presignal state
						table.insert(presignalsForNextBlock, potentialSignal.entity)
					elseif signal.type == SIGNAL_WAYPOINT then
						-- Params override
						local name = utils.getComponentProtected(potentialSignal.entity, 63)
						local values = pathEvaluator.parseName(string.gsub(name.name, " ", ""))
						
						if #blocks > 0 then
							blocks[#blocks].paramsOverride = values
							if values.speed then
								blocks[#blocks].minSpeed = values.speed
							end
						end
					end
				end
			elseif pathEvaluator.isStation(pathIndex, path) then -- Adding Trainstations
				local stationInfo = {
					edges = {},
					signalListEntityId = 0000,
					hasSwitch = false,
					isStation = true,
					edgeEntityIdOn = edgeEntityId,
					minSpeed = 0,
					presignalsEntityIds = presignalsForNextBlock
				}
				table.insert(blocks, stationInfo)
			end

			-- register edge to last signal
			if #blocks > 0 then
				table.insert(blocks[#blocks].edges, edgeEntityId)
			end

			-- reset loop
			shouldContinueSearch = pathEvaluator.shouldContinueSearching(#blocks, signalsToEvaluate, pathIndex, pathEnd)
			pathIndex = pathIndex + 1
		end
	end

	return blocks
end

function pathEvaluator.isStation(pathIndex, path)
	return pathIndex == (#path.path.edges - path.path.endOffset)
end

function pathEvaluator.shouldContinueSearching(foundSignals, signalsToEvaluate, pathIndex, pathEnd)
	if foundSignals >= signalsToEvaluate then
		-- We've found enough signals to consider
		if config_debug then
			print("stopping: enough signals")
		end
		return false
	end
	if pathIndex >= pathEnd then
		-- Reached end
		if config_debug then
			print("stopping: path end")
		end
		return false
	end

	return true
end

---Gets if edge is a branch after a switch
---taken from WernerK's splitter mod
---@param transportNetwork table api.type.ComponentType.TRANSPORT_NETWORK
---@return boolean
function pathEvaluator.isAfterSwitch(transportNetwork)
	if transportNetwork then
		local lanes = transportNetwork.edges
		local firstIndex = lanes[1].conns[1].index
		local lastIndex = lanes[#lanes].conns[2].index
		return firstIndex > 0 and firstIndex < 5
		or lastIndex > 0 and lastIndex < 5
		-- >= 5 would be level crossing
	end
	return false
end

---The game has signals be default as red. This attempts to return more signals as green
---@param block BlockInfo
---@param trainLocsEdgeEntityIds any -- edgeEntityIds of location of nearby trains
---@param isLast boolean -- If last signal that has been evaluated unsafe to treat red as green
---@param passedSwitch boolean -- If a switch has been passed in the path as unsafe to treat red as green
---@return number -- signal state. 1 is green, 0 is red
function pathEvaluator.recalcSignalState(block, trainLocsEdgeEntityIds, isLast, passedSwitch)
	local signal = block.signalComp.signals[1]

	if signal.state == SIGNAL_STATE_GREEN then
		return signal.state
	end
	if isLast or passedSwitch then
		return signal.state
	end

	-- Red signal. Let's see if it's safe to treat as green
	local hasTrainInPath = pathEvaluator.hasTrainInPath(block.edges, trainLocsEdgeEntityIds)

	if not hasTrainInPath then
		if config_debug then
			print("Treat red signal as green "  .. block.signalListEntityId)
		end
		return SIGNAL_STATE_GREEN
	else
		return signal.state
	end
end

function pathEvaluator.hasTrainInPath(edgesTable, trainLocsEdgeIds)
	for _, edgeId in pairs(edgesTable) do
		if trainLocsEdgeIds[edgeId] ~= nil then
			-- Signal is protecting a train. Stop
			return true
		end
	end
	return false
end

function pathEvaluator.isMainSignal(signal, signalListEntityId, main_signalObjects, main_signals)
	if pathEvaluator.isHybridSignalInPreSignalState(signalListEntityId, main_signalObjects, main_signals) then
		return false
	end

	return pathEvaluator.isASignal(signal, signalListEntityId, main_signalObjects)
end

function pathEvaluator.isHybridSignalInPreSignalState(signalListEntityId, main_signalObjects,main_signals)
	local signalKey = "signal" .. signalListEntityId
	local signalObj = main_signalObjects[signalKey]
	if signalObj then
		local signalType = main_signals[signalObj.signalType]
		local construction = utils.getComponentProtected(signalObj.construction, api.type.ComponentType.CONSTRUCTION)

		if signalType.type == "hybrid" and construction then
			local presignalConditionMatch = construction.params[signalType['preSignalTriggerKey']] == signalType['preSignalTriggerValue']
			if presignalConditionMatch then
				return true
			end
		end
	end
	return false
end

function pathEvaluator.isASignal(signal, signalListEntityId, main_signalObjects)
	return signal.type == SIGNAL_UNIDIR or signal.type == SIGNAL_ONEWAY or (signal.type == SIGNAL_WAYPOINT and main_signalObjects["signal" .. signalListEntityId])
end

function pathEvaluator.parseName(input)
    local result = {}
    -- Entferne Leerzeichen am Anfang und Ende des Strings/ Remove spaces at the end and the start of the string
    input = input:match("^%s*(.-)%s*$")

    -- Iteriere über jedes Paar, das durch Kommas getrennt ist/ iterate over every pair seperated by ,
    for pair in string.gmatch(input, '([^,]+)') do
        local key, value = pair:match("^%s*([^=]+)%s*=%s*(.+)%s*$")
        if key and value then
            -- Konvertiere "true" und "false" in booleans/ convert true and false booloeans
            if value == "true" then
                value = 1
            elseif value == "false" then
                value = 2
            elseif tonumber(value) then
                value = tonumber(value)
            end
            result[key] = value
        end
    end
    return result
end

return pathEvaluator