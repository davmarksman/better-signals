Great mod again. My changes only seek to improve a little on the hard work you've done and it's focused on a small part of the codebase because the rest is pretty amazing.

I'll update the PR as and when I find bugs. Please report any issues you spot. 
That said I've tested it a fair bit using N-signals mod and it's working well with no issues.

# Summary
- Attempts to work out if a red signal is safe to be treated as green
- Performance improvements (see Performance)


# Debugging
To aid understanding I've left in print statements. Mods that are also helpful for debuging:
- AutoSig2 - Speeds up placing and removing signals
- Splitter - Can use it so hover over a track edges and see entity id and details
- I created a mod to highlight a train's path. Let me know if you would like that and I can share it

# Changes:

## Functionality
### Attempts to work out if a red signal is safe to be treated as green
A red signal can be treated as green if:
- No train on block it's protecting
- If it's not protecting a switch: A switch can be crossed in different directions so we don't attempt to work out the complex block that the signal is protecting
- It's not the last signal we've calculated on the path we're evaluating
- When in cockpit mode, camera location doesn't update. I've added code to handle that scenario `signals.updateGuiCameraPos`, `signals.setCockpitMode`, `signals.getPosition`


### Performance
- Signals are only computed when signals are visible (when the camera is too zoomed out signals are not visibile, so no point slowing down the already slow game then :))
- Signals computation only happens every 10th game update event (every 2 seconds according to this: https://wiki.transportfever2.com/api/topics/states.md.html). It's a good trade off between performance and the user noticing
- Only Trains within 2km of the camera are computed: so a signal up to 2km from a train can be triggered by that train. If the train is further out it's path is not computed so the signal doesn't get updated. The 2km is configurable from the mod menu
- Only 4 signals in front of the train are computed. (Don't need to compute more as we attempt to get enough signals so we can get that nice Green - Yellow - Red)
- As we work out if a red signal is safe to be treated as green less signals are placed resulting in better computation

## Logic
- `signals.updateSignals` is only executed when the camera is zoomed in enough for signals to be visible
- We effectively perform several reduce operations:
  1. `pathEvaluator.findSignalsInPath` - Split a train's path into blocks protected by signals/end station. Each block starts with a signal (or station)
  2. `pathEvaluator.evaluate` - We determine signal states for each signal leading a block and prepare to return as `SignalPath`
  3. `utils.addChecksumToSignals` - We calculate checksum and add to `SignalPath`. I rewrote the checksum implementation (see discussion)
  4. `signals.computeSignalPaths` - We collect together all the signals that need to be updated. There may be multiple trains trying to update the same signal so we resolve that here
- We then update signal constructions `signals.updateConstructions` followed by throwing all other signals to red

### Limitations 
- Red signals before a switch are always treated as at danger and never changed to green - Reasonable
- Existing limitation: 2 signals on same segment
- Cockpit view is only supported for trains. I don't know enough to work out the how to get the position of other vehicle types


## Breaking changes/TODO/Known Issues:
- Some more testing. Help is valued here :)
- Removed functionality: presignals to simplify my implementation. I can add it back based off discussion (see discussions)
- Ignoring waypoints. I can add it back based off discussion (see discussions)
- Removed functionality: getting showSpeedChange from construction to simplify my implementation. Defaulted to true. Need some help understanding what it does then can add it back in


# Discussion:

### Adding a parameter to construction for if track is occupied
We now dectect if a block is occupied by a train. Some signaling systems like your swiss type N mod have a signal to indicate to the train driver the track is occupied. We can now expose this as a param on the construction so other modders can use

### Waypoints for presignals
In my opinion it would make sense for:
- Waypoints to only support presignals (inform only about state of next signal)
- Regular signals to only support main signals or hybrid signal constructions

### What does show speed change do?

### Checksum
I had a rare issue where checksums collided: so didn't update a red signal to a green signal. I think it's due to the addition of previous checksum - You normally multiply for checksums

I think the check sum implementation can have collisions in rare instances - for example a signal_speed of 120 & signal_state 0, followed by a new train coming which has a signal speed of 119 and signal_state 1 would produce the same checksum

### Terrain util log messages
There's alot of this messages in the log when placing a construction. Not sure why:
```
terrain_util::GetHeightAt: pos not valid: (-inf / -inf)
terrain_util::GetHeightAt: pos not valid: (inf / -inf)
terrain_util::GetHeightAt: pos not valid: (inf / inf)
terrain_util::GetHeightAt: pos not valid: (-inf / inf)
```