# Project Eclipse — CC:Tweaked API Documentation

The **Missile Control Panel (MCP)** is exposed as a CC:Tweaked peripheral of type `missile_control_panel`. It provides full programmatic access to every MCP capability: network topology, multi-target strike planning, launcher & Strategic Silo ("Big One") management, radar & IFF tracking, automated air defense, pursuit interceptors, protected zones, and UAV reconnaissance.

---

## 1. Security & Ownership Model

To prevent unauthorized control on multiplayer servers:
1. **Strict Ownership**: Every MCP records the player who placed it. Only the owner of an MCP can link a computer to it, generate tokens for it, or issue commands to its network.
2. **Per-(Computer, MCP) Session**: Authentication binds a specific `(computerId, mcpPos)` pair. A computer linked to your MCP cannot be moved to or wired into another player's MCP.
3. **Permanent Auto-Link (`/eclipse ccauto`)**: Running `/eclipse ccauto` links the nearest adjacent/wired computer to your MCP **permanently**. The link is saved to disk (`project_eclipse_cc_sessions`) and survives chunk unloads, wired modem reconnects, and server restarts until explicitly revoked.

### In-Game Commands

| Command | Description |
|---|---|
| `/eclipse ccauto` | Permanently authorizes the nearest computer connected to your MCP and copies a ready-to-run Lua snippet. Persists across world/server restarts. |
| `/eclipse ccgrant` | Generates a 6-character one-time token (valid for 2 minutes) for your nearest MCP. Pass this token to `mcp.authenticate("TOKEN")` on a computer. |
| `/eclipse ccrevoke [computerId]` | Revokes a specific computer's session on your MCP, or revokes all computers linked to your MCP if `computerId` is omitted. |

### Connecting in Lua

Place a computer directly next to your **Missile Control Panel** or connect it via **Wired Modems & Networking Cable**:

```lua
local mcp = peripheral.find("missile_control_panel")
assert(mcp, "No Missile Control Panel found!")

-- If linked via /eclipse ccauto, the session is already permanently active:
if not mcp.isAuthenticated() then
    mcp.authenticate("ABC123") -- One-time token from /eclipse ccgrant
end
```

---

## 2. Authentication & Session Methods

### `mcp.isAuthenticated()`
Returns whether this computer is currently authorized for this MCP.
- **Returns:** `boolean`

### `mcp.authenticate([token])`
Authenticates this computer with the MCP.
- **Parameters:**
  - `token` *(string, optional)* — 6-character token from `/eclipse ccgrant`. May be omitted if the computer was already authorized via `/eclipse ccauto`.
- **Returns:** `"AUTHENTICATED"` on success; throws a Lua error if the token is invalid, expired, or belongs to a different MCP.

### `mcp.deauthenticate()`
Revokes this computer's session with the connected MCP.
- **Returns:** `nil`

---

## 3. Network Overview, Topology & Logs

### `mcp.getNetworkInfo()`
Returns a comprehensive snapshot of the MCP network state.
- **Returns:** `table`
  | Field | Type | Description |
  |---|---|---|
  | `networkId` | `string` | Unique UUID of the MCP network |
  | `mcpId` | `number` | Packed block position (`BlockPos.asLong()`) |
  | `x`, `y`, `z` | `number` | Coordinates of the MCP block |
  | `networkOnline` | `boolean` | `false` while jammed by an active EMP effect |
  | `empRemainingTicks` | `number` | Remaining EMP disruption ticks (`0` when clear) |
  | `defenseMode` | `string` | `"MANUAL"`, `"ASSISTED"`, `"AUTO"`, or `"HOLD_FIRE"` |
  | `defenseDoctrine` | `string` | `"BALANCED"`, `"CONSERVE"`, or `"MAXIMUM_DEFENSE"` |
  | `pursuitAuto` | `boolean` | Whether autonomous pursuit interceptors are enabled |
  | `interceptorLauncherMode` | `string` | `"BOTH"`, `"ANTI_MISSILE"`, or `"ANTI_PLAYER"` |
  | `readyInterceptors` | `number` | Loaded interceptor missiles across all defense launchers |
  | `readyCiws` | `number` | Connected CIWS turrets with ammunition |
  | `ciwsAmmo` | `number` | Total CIWS rounds available across the network |
  | `defenseThreats` | `number` | Currently tracked incoming missile threats |
  | `protectedZones` | `number` | Number of configured defense zones |
  | `radarCount` | `number` | Connected radar dishes |
  | `launcherCount` | `number` | Connected offensive launcher units |
  | `readyMissiles` | `number` | Total offensive missiles ready to fire |
  | `activeFlights` | `number` | Currently airborne missiles launched by this network |
  | `activeUavs` | `number` | Currently airborne reconnaissance UAVs |
  | `scheduledLaunches` | `number` | Countdown fire plans waiting to launch |

### `mcp.getNodes()`
Lists every hardware node discovered on the MCP cable and wireless extender network.
- **Returns:** `table[]` (array of node tables)
  | Field | Type | Description |
  |---|---|---|
  | `id` | `number` | Node ID (`BlockPos.asLong()`) |
  | `type` | `string` | `"ATTACK_LAUNCHER"`, `"LAUNCH_PAD"`, `"STRATEGIC_SILO"`, `"CRUISE_LAUNCHER"`, `"CRUISE_MISSILE"`, `"PLACED_MISSILE"`, `"RADAR"`, `"INTERCEPTOR_LAUNCHER"`, `"CIWS"`, `"DEFENSE_CONTROLLER"`, `"UAV_PAD"`, `"WIRELESS_EXTENDER"`, `"SILO_DOOR"`, etc. |
  | `name` | `string` | Display name of the node |
  | `x`, `y`, `z` | `number` | Block coordinates |
  | `connected` | `boolean` | Whether the node is currently reachable |
  | `extenderDepth` | `number` | Wireless hop depth (`0` for wired nodes) |
  | `parentId` | `number` | Parent wireless extender ID (`0` if direct) |
  | `readyCount` | `number` | Ready missiles/rounds on this node |
  | `summary` | `string` | Human-readable status summary |

### `mcp.disconnectNode(nodeId)`
Disconnects a specific node from the MCP network.
- **Parameters:**
  - `nodeId` *(string)* — Node UUID from `mcp.getNodes()` or `mcp.getLaunchers()`.
- **Returns:** `boolean` (`true` if disconnected)

### `mcp.registerRocket(x, y, z [, name])` / `mcp.registerDevice(x, y, z [, name])` *(Requires `OWNER`)*
Programmatically registers/links a rocket, placed missile, four-rail pod launcher, launch pad, Strategic "Big One" silo, cruise missile trailer (including any unlinked cruise missiles inside its boxes), 4-rack interceptor launcher, radar, CIWS, wireless extender, UAV pad, or silo door at `(x, y, z)` to this MCP network. You can pass the coordinates of either the launcher/pad or the rocket standing on top of it.
- **Parameters:**
  - `x`, `y`, `z` *(number)* — World coordinates of the rocket or launcher.
  - `name` *(string, optional)* — Custom label to assign to the registered node.
- **Returns:** `table`
  | Field | Type | Description |
  |---|---|---|
  | `registered` | `boolean` | `true` if linked (or already registered to this MCP) |
  | `id` | `string` | Registered node UUID |
  | `type` | `string` | Node type (`"PLACED_MISSILE"`, `"ATTACK_LAUNCHER"`, `"LAUNCH_PAD"`, `"STRATEGIC_SILO"`, `"CRUISE_LAUNCHER"`, `"INTERCEPTOR_LAUNCHER"`, etc.) |
  | `label` | `string` | Human-readable device category |
  | `x`, `y`, `z` | `number` | Resolved controller coordinates |
  | `linkedCruiseMissiles` | `number` | Number of individual cruise missiles inside trailer boxes that were also linked |
  | `message` | `string` | `"REGISTERED"`, `"ALREADY REGISTERED"`, or failure reason |

### `mcp.scanAndRegister([radius])` *(Requires `OWNER`)*
Scans within `radius` blocks around the MCP (and across any Sable physics vehicle the MCP is mounted on) and automatically registers all unlinked rockets, placed missiles, launchers, pads, silos, cruise trailers, radars, and air-defense devices.
- **Parameters:**
  - `radius` *(number, optional)* — Scan radius in blocks (`1`–`64`, default `16`).
- **Returns:** `{ count = number, radius = number, registered = table[] }`

### `mcp.renameNode(nodeId, name)` *(Requires `OWNER`)*
Assigns or updates the custom display name of any registered rocket, launcher, or node on this MCP network.
- **Parameters:**
  - `nodeId` *(string)* — Node UUID from `mcp.getNodes()` or `mcp.getLaunchers()`.
  - `name` *(string)* — New display name (pass `""` to clear).
- **Returns:** `boolean` (`true` if updated)

### `mcp.getEvents([limit])`
Returns recent entries from the MCP activity log.
- **Parameters:**
  - `limit` *(number, optional)* — Max entries to return (`1`–`200`, default `50`).
- **Returns:** `table[]` — Each entry contains `{ tick, type, message, time }`.

---

## 4. Offensive Launchers & Strategic Silos ("Big One")

### `mcp.getLaunchers()`
Returns all offensive launchers connected to the network (4-rail Pod Launchers, 3×3 Launch Pads, Strategic Silos, Cruise Launchers, and standalone Placed Missiles).
- **Returns:** `table[]`
  | Field | Type | Description |
  |---|---|---|
  | `id` | `number` | Launcher ID (`BlockPos.asLong()`) |
  | `type` | `string` | `"POD_LAUNCHER"`, `"LAUNCH_PAD"`, `"STRATEGIC_SILO"`, `"CRUISE_LAUNCHER"`, or `"PLACED_MISSILE"` |
  | `name` | `string` | Launcher label |
  | `x`, `y`, `z` | `number` | Block coordinates |
  | `loadedCount` | `number` | Number of loaded missiles |
  | `busy` | `boolean` | Whether the launcher is currently slewing/firing |
  | `ready` | `boolean` | Whether the launcher can accept a fire mission now |
  | `networked` | `boolean` | Whether the link is active |
  | `racks` | `number[]` | Array of size 4 with missile tier IDs per rail (`0` = empty, `7` = Big One) |
  | `summary` | `string` | Status summary string |

### `mcp.getReadyMissileCount()`
Returns the total number of ready-to-fire offensive missiles across all launcher types.
- **Returns:** `number`

### `mcp.getTierIds()`
Returns the list of standard missile tier IDs (`{ 1, 2, 3, 4, 5, 6 }`).
- **Returns:** `number[]`

### `mcp.getSilos()`
Returns detailed telemetry for every connected **Strategic Silo ("Big One")**.
- **Returns:** `table[]`
  | Field | Type | Description |
  |---|---|---|
  | `id` | `number` | Silo controller ID (`BlockPos.asLong()`) |
  | `name` | `string` | Silo designation |
  | `x`, `y`, `z` | `number` | Controller coordinates |
  | `connected` | `boolean` | Network link status |
  | `loaded` | `boolean` | Whether a complete rocket is assembled inside |
  | `state` | `string` | Current silo state (e.g. `"IDLE"`, `"ARMED"`, `"LAUNCHING"`) |
  | `sections` | `number` | Assembled fuselage sections (`0`–`3`) |
  | `payload` | `string` | Installed warhead payload name |
  | `fuelMb` | `number` | Current RP-1 / fuel amount in mB |
  | `oxidizerMb` | `number` | Current LOX / oxidizer amount in mB |
  | `fuelPercent` | `number` | Fuel fill percentage (`0`–`100`) |
  | `oxidizerPercent` | `number` | Oxidizer fill percentage (`0`–`100`) |
  | `valvesOpen` | `boolean` | Whether propellant valves are open |
  | `ready` | `boolean` | Whether the silo is armed and ready to launch |
  | `locked` | `boolean` | Safety lock state |
  | `fault` | `string` | Fault code (`"NONE"` when nominal) |
  | `status` | `string` | Human-readable status line |

### `mcp.siloAction(siloId, action)`
Controls propellant valves or arming state on a Strategic Silo.
- **Parameters:**
  - `siloId` *(number)* — Silo ID from `mcp.getSilos()`.
  - `action` *(string | number)*:
    - `"VALVES"` / `"TOGGLE_VALVES"` / `0` — Toggle propellant valves open/closed
    - `"ARM"` / `1` — Arm the silo for launch
    - `"DISARM"` / `2` — Disarm the silo
- **Returns:** `boolean` (`true` if the state changed)

---

## 5. Targeting, Firing, Fire Plans & Scheduled Launches

### `mcp.setTarget(x, y, z)`
Stages target coordinates on this computer for `mcp.fire()`.
- **Parameters:** `x`, `y`, `z` *(number)* — World coordinates (`y` is clamped to `-64..320`).
- **Returns:** `"OK"`

### `mcp.getTarget()`
Returns the currently staged target on this computer, or `nil` if unset.
- **Returns:** `{ x = number, y = number, z = number } | nil`

### `mcp.clearTarget()`
Clears the staged target on this computer.
- **Returns:** `nil`

### `mcp.fire([count])`
Queues `count` missiles (default `1`, max `64`) toward the staged target set by `mcp.setTarget()`.
- **Multi-Target & Loop Support:** Rapid calls in a `for` loop (e.g. changing `setTarget` and calling `fire(1)` multiple times in the same tick) are automatically coalesced into a unified multi-mission fire plan and **auto-load-balanced** across all available launchers and rails. Each launcher smoothly slews to its assigned target(s) in sequence.
- **Returns:** `"FIRED <count>"`

### `mcp.fireAt(x, y, z [, count [, options]])`
Fires at `(x, y, z)` directly in a single call, with optional advanced mission parameters.
- **Parameters:**
  - `x`, `y`, `z` *(number)* — Target coordinates.
  - `count` *(number, optional)* — Number of missiles (`1`–`64`, default `1`).
  - `options` *(table, optional)* — Advanced mission configuration:
    | Field | Type | Description |
    |---|---|---|
    | `name` | `string` | Mission label |
    | `fireMode` / `tier` | `string \| number` | `"AUTO"` (`0`), tier `1`–`6`, `"BIG_ONE"` (`7`), `"CRUISE"` (`8`), or `"SALVO"` (`9`) |
    | `attackProfile` | `string` | `"HIGH_BALLISTIC"`, `"LOW_TRAJECTORY"`, or `"TERRAIN_HUG"` |
    | `approachBearing` | `number` | Terminal approach compass bearing in degrees (`-1` for direct) |
    | `impactMode` | `string` | `"SURFACE"`, `"AIRBURST"`, or `"BUNKER_BUSTER"` |
    | `bunkerDepth` | `number` | Depth in blocks (`1`–`20`) when `impactMode = "BUNKER_BUSTER"` |
    | `delaySeconds` | `number` | Countdown delay before launch (`0`–`3600` seconds) |
    | `contactId` | `string` | UUID string of a radar track for dynamic moving-target lock |
    | `launchers` | `number[]` | Specific launcher IDs to restrict this mission to |
    | `checkpoints` | `table[]` | Up to 3 waypoints: `{ { x = ..., z = ..., height = 120 }, ... }` |
- **Returns:** `string` (`"FIRED <count>"`, `"EXECUTING 1 MISSION(S)"`, or `"SCHEDULED 1 MISSION(S) IN <delay>S"`)

### `mcp.executeFirePlan(missions [, delaySeconds])`
Executes a full multi-mission fire plan (up to 48 missions) simultaneously or on a countdown timer.
- **Parameters:**
  - `missions` *(table[])* — Array of mission tables. Each mission table supports `x`, `y`, `z`, `count` (or `salvoCount`), plus all fields listed in `mcp.fireAt` `options`.
  - `delaySeconds` *(number, optional)* — Countdown in seconds (`0`–`3600`, default `0`).
- **Returns:** `string`

### `mcp.getPlannedMissions()`
Returns the missions currently saved on the MCP's tactical planning board.
- **Returns:** `table[]`

### `mcp.clearPlannedMissions()`
Clears all missions saved on the MCP's tactical planning board.
- **Returns:** `"OK"`

### `mcp.getScheduledLaunches()`
Returns all active countdown launches scheduled on this MCP.
- **Returns:** `table[]` — Each entry has `{ id, label, ticksRemaining, secondsRemaining, missionCount, missileCount }`.

### `mcp.abortScheduledLaunch(launchId)`
Aborts a scheduled countdown launch before ignition.
- **Parameters:** `launchId` *(number)* — ID from `mcp.getScheduledLaunches()`.
- **Returns:** `boolean` (`true` if aborted)

### `mcp.getFlights()`
Returns all currently airborne missiles belonging to this MCP network.
- **Returns:** `table[]`
  | Field | Type | Description |
  |---|---|---|
  | `id` | `string` | Flight UUID |
  | `tier` | `number` | Missile tier ID |
  | `phase` | `string` | Flight phase (`"BOOST"`, `"MIDCOURSE"`, `"TERMINAL"`, etc.) |
  | `x`, `y`, `z` | `number` | Current live position |
  | `vx`, `vy`, `vz` | `number` | Current velocity vector |
  | `originX`, `originY`, `originZ` | `number` | Launch coordinates |
  | `targetX`, `targetY`, `targetZ` | `number` | Impact target coordinates |
  | `progress` | `number` | Flight completion ratio (`0.0`–`1.0`) |
  | `remainingTicks` | `number` | Estimated ticks to impact |
  | `remainingSeconds` | `number` | Estimated seconds to impact |
  | `interceptable` | `boolean` | Whether the missile is in an interceptable phase |

---

## 6. Radar, Air/Vehicle Tracks & IFF

### `mcp.getContacts()`
Returns evaluated incoming missile threat contacts tracked by the defense network.
- **Returns:** `table[]`
  | Field | Type | Description |
  |---|---|---|
  | `id` | `string` | Threat flight UUID |
  | `tier` | `number` | Detected missile tier |
  | `confidence` | `number` | Radar track confidence (`0.0`–`1.0`) |
  | `level` | `string` | Threat classification (`"CRITICAL"`, `"HIGH"`, `"MEDIUM"`, `"LOW"`, `"NONE"`) |
  | `trackState` | `string` | Engagement state (`"TRACKING"`, `"ENGAGED"`, `"INTERCEPTED"`, etc.) |
  | `x`, `y`, `z` | `number` | Current coordinates |
  | `closestApproachBlocks` | `number` | Predicted closest approach distance to network assets |
  | `etaTicks` | `number` | Estimated ticks until impact |
  | `assignedRacks` | `number` | Number of interceptor rails assigned to this threat |
  | `endangeredAssets` | `string` | Summary of threatened zones/nodes |
  | `failureReason` | `string` | Reason if intercept cannot be computed |

### `mcp.getRadars()`
Returns status information for all connected radar dishes.
- **Returns:** `table[]` — Each entry has `{ id, x, y, z, range, state, contactCount }`.

### `mcp.getRadarContacts()`
Returns raw radar returns across all connected radar dishes.
- **Returns:** `table[]` — Each entry has `{ id, radarId, x, y, z, vx, vy, vz, tier, confidence, lastDetectedTick, ownNetwork }`.

### `mcp.getTracks()`
Returns airborne player (jetsuit/elytra) and vehicle tracks detected by radar.
- **Returns:** `table[]`
  | Field | Type | Description |
  |---|---|---|
  | `id` | `string` | Track UUID (can be passed to `setIffMark`, `launchPursuit`, or `fireAt` `contactId`) |
  | `kind` | `string` | Track category |
  | `iff` | `string` | Current IFF classification (`"FRIENDLY"`, `"HOSTILE"`, `"UNKNOWN"`) |
  | `state` | `string` | Track lock quality |
  | `confidence` | `number` | Track confidence (`0.0`–`1.0`) |
  | `x`, `y`, `z` | `number` | Current position |
  | `vx`, `vy`, `vz` | `number` | Current velocity |
  | `friendly` | `boolean` | Whether marked friendly |
  | `vehicle` | `boolean` | Whether the track is a vehicle |
  | `unknown` | `boolean` | Whether IFF is still unknown |
  | `designatable` | `boolean` | Whether the track has sufficient lock to be designated as a target |
  | `dwellRemaining` | `number` | Ticks of radar dwell remaining before full lock |
  | `lastDetectedTick` | `number` | Server tick of latest radar return |

### `mcp.setIffMark(contactId, mark)`
Marks a radar track as friendly, hostile, or clears its manual mark.
- **Parameters:**
  - `contactId` *(string)* — UUID string from `mcp.getTracks()`.
  - `mark` *(string)* — `"FRIENDLY"`, `"HOSTILE"`, or `"CLEAR"` (alias `"UNKNOWN"` / `"NONE"`).
- **Returns:** `string` (`"FRIENDLY"`, `"HOSTILE"`, or `"CLEAR"`)

---

## 7. Air Defense, Pursuit Interceptors & Protected Zones

### `mcp.getDefenseStatus()`
Returns a summary of the air defense subsystem.
- **Returns:** `table` (`mode`, `doctrine`, `pursuitAuto`, `interceptorLauncherMode`, `readyInterceptors`, `readyCiws`, `ciwsAmmo`, `threatCount`, `protectedZoneCount`)

### `mcp.setDefenseMode(mode)`
Sets the network air defense mode.
- **Parameters:** `mode` *(string)* — `"MANUAL"`, `"ASSISTED"`, `"AUTO"`, or `"HOLD_FIRE"` (alias `"STANDBY"` / `"OFF"`).
- **Returns:** `"OK"`

### `mcp.setDefenseDoctrine(doctrine)`
Sets the interceptor allocation doctrine.
- **Parameters:** `doctrine` *(string)* — `"BALANCED"`, `"CONSERVE"`, or `"MAXIMUM_DEFENSE"` (alias `"MAX"`).
- **Returns:** `"OK"`

### `mcp.engageThreat([contactId1, contactId2, ...])`
Manually launches interceptors against incoming missile threats.
- **Parameters:** Optional threat UUID strings (or a table of UUID strings) from `mcp.getContacts()`. If called with no arguments, engages all engageable threats.
- **Returns:** `boolean` (`true` if at least one interceptor was launched)

### `mcp.setPursuitAuto(enabled)`
Enables or disables automatic pursuit interceptor launches against hostile airborne tracks.
- **Parameters:** `enabled` *(boolean)*
- **Returns:** `"OK"`

### `mcp.getPursuitAuto()`
- **Returns:** `boolean`

### `mcp.launchPursuit(contactId1, ...)`
Manually launches pursuit interceptors at one or more airborne tracks from `mcp.getTracks()`.
- **Parameters:** One or more track UUID strings (or a table of UUID strings).
- **Returns:** `{ launched = number, message = string }`

### `mcp.setInterceptorLauncherMode(mode)`
Configures all connected Interceptor Launchers to engage missiles, airborne players/vehicles, or both.
- **Parameters:** `mode` *(string)* — `"BOTH"`, `"ANTI_MISSILE"` (alias `"ABM"`), or `"ANTI_PLAYER"` (alias `"SAM"`).
- **Returns:** `number` (number of interceptor launchers updated)

### `mcp.getInterceptorLauncherMode()`
- **Returns:** `string` (`"BOTH"`, `"ANTI_MISSILE"`, `"ANTI_PLAYER"`, `"MIXED"`, or `"NONE"`)

### `mcp.getDefenseZones()`
Lists all Protected Defense Zones configured on this MCP.
- **Returns:** `table[]` — Each entry has `{ id, name, centerX, centerZ, minX, maxX, minZ, maxZ, radius, priority, autoEngage }`.

### `mcp.upsertDefenseZone(zoneTable)`
Creates or updates a Protected Defense Zone (up to 16 zones per MCP).
- **Parameters:** `zoneTable` *(table)*:
  - `name` *(string)* — Zone label.
  - `priority` *(string, optional)* — `"CRITICAL"`, `"HIGH"`, `"NORMAL"`, or `"LOW"` (default `"NORMAL"`).
  - `autoEngage` *(boolean, optional)* — Default `true`.
  - Either center + radius: `x` (or `centerX`), `z` (or `centerZ`), `radius` (`8`–`512`).
  - Or bounding box: `minX`, `maxX`, `minZ`, `maxZ`.
- **Returns:** `{ saved = boolean, id = string, name = string, radius = number, message = string }`

### `mcp.removeDefenseZone(nameOrId)`
Removes a Protected Defense Zone by its `id` or `name`.
- **Returns:** `boolean`

### `mcp.setDefenseZoneAutoEngage(nameOrId, enabled)`
Enables or disables `autoEngage` on a Protected Defense Zone.
- **Returns:** `boolean`

---

## 8. UAV Reconnaissance

### `mcp.getUavs()`
Returns active reconnaissance UAV flights and pending recovery timers on this network.
- **Returns:** `table`
  - `flights` *(table[])* — Each flight has `{ id, padId, phase, x, y, z, originX, originZ, targetX, targetZ, loiterRemainingTicks, totalRemainingTicks }`.
  - `pendingRecoveries` *(number)* — Number of UAVs currently being recovered/refueled at pads.

### `mcp.launchUav(x, z [, y])` / `mcp.launchUav(x, y, z)`
Launches a reconnaissance UAV from a connected UAV Pad toward the specified target coordinates.
- **Parameters:**
  - 2 arguments: `x`, `z` *(number)* — Target X and Z coordinates (`y` defaults to `64`).
  - 3 arguments: `x`, `y`, `z` *(number)* — Target X, Y, and Z coordinates.
- **Returns:** `{ started = boolean, message = string }`

---

## 9. Orbital Recon Satellites & Project Thor Kinetic Strikes

Programmatic access to in-orbit space assets deployed via Strategic Silos ("The Big One").

### `mcp.getSatellites()`
Returns a list of all active Recon Satellites in orbit belonging to this defense network.
- **Returns:** `table[]` of:
  - `id`: `string`
  - `owner`: `string`
  - `orbitX`: `number`
  - `orbitY`: `number`
  - `orbitZ`: `number`
  - `deployedTick`: `number`

### `mcp.hasReconSatellites()`
Returns whether this network currently has at least one active recon satellite in orbit.
- **Returns:** `boolean`

### `mcp.getThorStatus()`
Returns the operational status of Project Thor orbital kinetic platforms for this network.
- **Returns:** `{ online = boolean, rodsRemaining = number }`

### `mcp.getRemainingTungstenRods()`
Returns the total count of heavy tungsten penetrator rods ready to drop from orbit.
- **Returns:** `number`

### `mcp.fireOrbitalStrike(x, z [, y])` *(Requires `OPERATOR`)*
Dispatches a hypersonic kinetic strike from an in-orbit Thor platform straight down onto the target coordinates. Takes ~3.5 seconds to impact and bores through 30+ blocks of subterranean bunkers.
- **Parameters:**
  - `x`: `number` — Target X coordinate
  - `z`: `number` — Target Z coordinate
  - `y` *(number, optional)* — Ground/target elevation (defaults to surface height)
- **Returns:** `{ status = "DISPATCHED", targetX = number, targetY = number, targetZ = number, flightSeconds = 3.5, remainingRods = number }`

---

## 10. Electronic Warfare & Radar Jamming

Control standalone or networked Radar Jammer stations.

### Standalone Peripheral: `radar_jammer`
Place a computer adjacent to a Radar Jammer Station or connect via wired modem:

```lua
local jammer = peripheral.find("radar_jammer")
assert(jammer, "No Radar Jammer found!")

-- Check status
print("Active:", jammer.isActive())
print("Mode:", jammer.getMode()) -- "noise" or "deception"
print("Range:", jammer.getRange())

-- Switch mode to deception spoofing
jammer.setMode("deception")

-- Toggle power
jammer.setActive(true)
```

#### Methods on `radar_jammer`:
- `jammer.isActive()`: Returns `boolean`.
- `jammer.setActive(boolean)`: Enables or disables the jammer.
- `jammer.toggle()`: Toggles active state. Returns new `boolean` state.
- `jammer.getMode()`: Returns `"noise"` (range denial) or `"deception"` (ghost spoofing).
- `jammer.setMode("noise" | "deception")`: Sets operational EW mode.
- `jammer.cycleMode()`: Toggles mode. Returns new mode string.
- `jammer.getRange()`: Returns effective broadcast radius (`160` for noise, `240` for deception).
- `jammer.getInfo()`: Returns `{ active, mode, range, x, y, z, networkId, linkedMcp }`.

### MCP Network Control Methods:
- `mcp.getRadarJammers()`: Returns a list of all Radar Jammers linked to this MCP network: `table[]` of `{ x, y, z, active, mode, range }`.
- `mcp.setRadarJammerActive(x, y, z, active)`: Remotely activates or deactivates a network jammer.
- `mcp.setRadarJammerMode(x, y, z, "noise" | "deception")`: Remotely sets the operational mode of a network jammer.

---

## 11. Complete Lua Examples

### Example 1: Multi-Target Salvo with Auto Load-Balancing
```lua
local mcp = peripheral.find("missile_control_panel")
assert(mcp and mcp.isAuthenticated(), "MCP not ready")

-- Rapidly queue 4 random targets; MCP coalesces and distributes them across all launchers/rails
for i = 1, 4 do
    mcp.setTarget(math.random(-1000, 1000), 64, math.random(-1000, 1000))
    mcp.fire(1)
end
```

### Example 2: Coordinated Multi-Mission Fire Plan with Waypoints & Bunker Buster
```lua
local mcp = peripheral.find("missile_control_panel")

local res = mcp.executeFirePlan({
    {
        name = "Radar Suppression",
        x = 1250, y = 72, z = -840,
        count = 2,
        attackProfile = "TERRAIN_HUG",
        impactMode = "AIRBURST",
        checkpoints = {
            { x = 600, z = -200, height = 110 },
            { x = 950, z = -650, height = 95 }
        }
    },
    {
        name = "Deep Bunker Strike",
        x = 1300, y = 64, z = -900,
        count = 1,
        fireMode = "BIG_ONE",
        attackProfile = "HIGH_BALLISTIC",
        impactMode = "BUNKER_BUSTER",
        bunkerDepth = 15
    }
}, 10) -- 10-second countdown

print(res)
```

### Example 3: Automated Air Defense & Hostile Track Intercept
```lua
local mcp = peripheral.find("missile_control_panel")

mcp.setDefenseMode("AUTO")
mcp.setDefenseDoctrine("MAXIMUM_DEFENSE")
mcp.setPursuitAuto(true)
mcp.setInterceptorLauncherMode("BOTH")

mcp.upsertDefenseZone({
    name = "Main Base",
    x = 0, z = 0,
    radius = 180,
    priority = "CRITICAL",
    autoEngage = true
})

while true do
    local contacts = mcp.getContacts()
    if #contacts > 0 then
        print(("ALERT: %d incoming missile threat(s)!"):format(#contacts))
        mcp.engageThreat()
    end
    sleep(1)
end
```

### Example 4: Orbital Recon & Automated Project Thor Kinetic Strike
```lua
local mcp = peripheral.find("missile_control_panel")
assert(mcp and mcp.isAuthenticated(), "MCP not ready")

-- Check space assets
local sats = mcp.getSatellites()
print(("Active Recon Satellites in orbit: %d"):format(#sats))

local thor = mcp.getThorStatus()
print(("Project Thor Online: %s (Rods remaining: %d)"):format(tostring(thor.online), thor.rodsRemaining))

-- Automatically drop a hypersonic tungsten rod when a hostile contact enters range
local contacts = mcp.getContacts()
for _, c in ipairs(contacts) do
    if c.tier >= 4 and thor.rodsRemaining > 0 then
        print(("CALLING ORBITAL STRIKE ON CONTACT %s AT (%d, %d)"):format(c.flightId, c.x, c.z))
        local strike = mcp.fireOrbitalStrike(c.x, c.z)
        print(("Hypersonic impact in %.1f seconds!"):format(strike.flightSeconds))
        break
    end
end
```
