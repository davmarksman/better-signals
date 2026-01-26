local utils = require "nightfury/signals/utils"

local pathEvaluator = {}
local config_debug = false

-- TODO Edge speeds

---We evaluate a train's path and create blocks protected by better signals
---@param vehicleId any
---@param lookAheadEdges any -- Max no of edges to look ahead on path before stopping
---@param signalsToEvaluate any -- Max no of signals to find on the path before stopping
---@param trainLocsEdgeEntityIds any -- edgeEntityIds of location of nearby trains
---@return SignalPath
function pathEvaluator.evaluate(vehicleId,  lookAheadEdges, signalsToEvaluate, trainLocsEdgeEntityIds)
	---@class SignalPath Represents a block of track protected by a signal
	---@field entity number Entity from api.engine.system.signalSystem.getSignal(). Should rename but keeping for backwards compatibility
	---@field signal_state number
	---@field signal_speed number
	---@field incomplete boolean
	---@field following_signal SignalPath
	---@field previous_speed boolean
	---@field checksum number

	-- print("pathEvaluator.evaluate ", vehicleId)
	local res = {}

	local path = api.engine.getComponent(vehicleId, api.type.ComponentType.MOVE_PATH)
	-- ignore stopped trains 
	if path.dyn.speed == 0 or #path.path.edges == 1 or path.dyn.pathPos.edgeIndex < 0 then
		return res
	end

	---1st evaluation: We split path into blocks protected by signals/end station. Each block starts with a signal
	local signalsInPath = pathEvaluator.findSignalsInPath(path,lookAheadEdges, signalsToEvaluate)
	local passedSwitchOrLevelCrossing = false

	-- 2nd evaluation: We determine signal states for each signal in path and prepare to return as SignalPath
	for i = 1, #signalsInPath, 1 do
		local signalAndBlock = signalsInPath[i]

		local signalState = 0
		if signalAndBlock.isStation == false then
			if signalAndBlock.hasSwitch then
				passedSwitchOrLevelCrossing = true
			end
			
			-- Recalculate signal state to attempt to make more signals green
			signalState = pathEvaluator.recalcSignalState(signalAndBlock, trainLocsEdgeEntityIds, i==#signalsInPath, passedSwitchOrLevelCrossing)
		end

		local signalPath = {}
		signalPath.entity = signalAndBlock.signalListEntityId
		signalPath.signal_state = signalState
		signalPath.signal_speed = signalAndBlock.minSpeed
		signalPath.incomplete = false

		if #res >0 then
			signalPath.previous_speed = res[#res].signal_speed
			res[#res].following_signal = signalPath
		end

		table.insert(res, signalPath)
	end

	-- 3rd evaluation: calc checksums. We do in reverse order to include following signal in checksum
	utils.addChecksumToSignals(res)

	-- For debuging can remove
	if config_debug then
		for i = 1, #signalsInPath, 1 do
			local signalAndBlock = signalsInPath[i]
			local signalPath = res[i]
				
			print("Signal at ", signalAndBlock.edgeEntityIdOn, signalPath.entity, signalPath.signal_state, signalPath.signal_speed, signalPath.checksum,signalAndBlock.hasSwitch)	
		end
	end

	return res
end

---First evaluation: We convert path into blocks protected by signals/end station
---@param path any
---@param lookAheadEdges any
---@param signalsToEvaluate any
---@return BlockInfo
function pathEvaluator.findSignalsInPath(path, lookAheadEdges, signalsToEvaluate)
	---@class BlockInfo Represents a block of track with a signal or a station
	---@field edges table<number> nil when isStation is true
	---@field signalComp any
	---@field signalListEntityId number -- The entity of the SignalList 
	---@field hasSwitch boolean
	---@field isStation boolean
	---@field edgeEntityId number
	---@field minSpeed number
	-- print("pathEvaluator.findSignalsInPath")
	local blocks = {}

	if path and path.path and #path.path.edges > 2 then
		local pathStart = math.max(path.dyn.pathPos.edgeIndex, 1)
		local pathEnd = math.min(#path.path.edges, pathStart + lookAheadEdges)
		local pathIndex = pathStart
		local shouldContinueSearch = true

		while shouldContinueSearch do
			local currentEdge = path.path.edges[pathIndex]
			local edgeEntityId = currentEdge.edgeId.entity
			-- print("currentEdge " .. tostring(edgeEntityId))

			local transportNetwork = api.engine.getComponent(currentEdge.edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK)
			local speed = math.floor(utils.getEdgeSpeed(currentEdge.edgeId, transportNetwork))

			if #blocks > 0 then
				blocks[#blocks].minSpeed = math.min(blocks[#blocks].minSpeed, speed)
		
				local isSwitchBranch = pathEvaluator.isAfterSwitch(transportNetwork)
				if isSwitchBranch then
					-- print("found switch branch at edge ",  edgeEntityId )
					blocks[#blocks].hasSwitch = true
				end
			end

			-- FYI sometimes the edgeId is duplicated in the path (seems when there is a signal on the edge). dir is needed to identify which one has signal
			local potentialSignal = api.engine.system.signalSystem.getSignal(currentEdge.edgeId, currentEdge.dir)
			if potentialSignal and potentialSignal.entity and potentialSignal.entity ~= -1 then
				local signalComponent = api.engine.getComponent(potentialSignal.entity, api.type.ComponentType.SIGNAL_LIST)
				if signalComponent and signalComponent.signals and #signalComponent.signals > 0 then
					local signal = signalComponent.signals[1]

					if (signal.type == 0 or signal.type == 1) then
						local signalInfo = {
							edges = {},
							signalComp = signalComponent,
							signalListEntityId = potentialSignal.entity,
							hasSwitch = false,
							isStation = false,
							edgeEntityIdOn = edgeEntityId,
							minSpeed = speed,
						}
						table.insert(blocks, signalInfo)
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
		print("stopping: enough signals")
		return false
	end
	if pathIndex >= pathEnd then
		-- Reached end
		print("stopping: path end")
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

	if signal.state == 1 then
		-- print("Green signal " .. block.signalListEntityId)
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
		return 1
	else
		-- print("Red signal at danger"  .. block.signalListEntityId)
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

return pathEvaluator