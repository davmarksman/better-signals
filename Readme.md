Great mod again. My changes only seek to improve a little on the hard work you've done and it's focused on a small part of the codebase because the rest is pretty amazing.


# Summary
- More green signals! Attempts to work out if a red signal is safe to be treated as green
- Performance improvements (see Performance)


# Debugging
To aid understanding I've left in print statements that can be switched on using `config_debug = true` in `utils.lua`.

Mods that are also helpful for debuging:
- AutoSig2 - Speeds up placing and removing signals
- Splitter - Can use it so hover over a track edges and see entity id and details
- I created a mod to highlight a train's path. Let me know if you would like that and I can share it
- Common API

# Changes:

## Functionality
### Attempts to work out if a red signal is safe to be treated as green
A red signal can be treated as green if:
- No train on block it's protecting
- If it's not protecting a switch: A switch can be crossed in different directions so we don't attempt to work out the complex block that the signal is protecting
- It's not the last signal we've calculated on the path we're evaluating
- The path end or a station the train stops at are treated as red signals
- When in cockpit mode, camera location doesn't update. I've added code to handle that scenario `signals.updateGuiCameraPos`, `signals.setCockpitMode`, `signals.getPosition`


### Performance
- Signals are only computed when signals are visible (when the camera is too zoomed out signals are not visibile, so no point slowing down the already slow game then :))
- Signals computation only happens every 5th game update event (every second according to this: https://wiki.transportfever2.com/api/topics/states.md.html). It's a good trade off between performance and the user noticing
- Only signals for trains within 2km of the camera are computed: so a signal up to apx 8km from a train can be triggered by that train. But only if the train is within 2km of the centre of the camera. This 2km is user configurable - `Signal View Distance`, the 8km is a rough estimate based of `config_lookAheadEdges = 100` 
- Only 4-6 signals in front of the train are computed (depending on `Signal View Distance`). (Don't need to compute more as only need to get enough signals so we can get that nice Green - Yellow - Red)
- Signals can now be placed a larger distance, so less signals are placed, resulting in better computation


### Limitations 
- Red signals before a switch are always treated as at danger and never changed to green - Reasonable
- Existing limitation: 2 signals on same segment
- Cockpit view is only supported for trains. I don't know enough to work out the how to get the position of other vehicle types
- If a train has passed a pre-signal, the presignal won't update when the main signal does (we only compute signals in front of the train)
