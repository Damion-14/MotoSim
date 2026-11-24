# MotoSim online free ride

Build private **Free Ride** sessions for two to four friends on iPhone. Everyone loads the same terrain, joins near the selected start, and can ride, jump, and reset independently. Public matchmaking, race results, and persistent worlds are outside this first milestone.

## 1. Create and join a private session

Add **Free Ride → Host** and **Join Invite**. Use Game Center authentication, friend invitations, and GameKit’s real-time match transport. The host picks the track and starting area. The lobby shows who is connected and who has finished loading, then starts when the riders are ready. Start with the built-in circuit to verify invitations and connections without a track import dependency. [Apple GameKit real-time multiplayer](https://developer.apple.com/documentation/gamekit/exchanging-data-between-players-in-real-time-games)

**Acceptance** — Two iPhones on different networks can host, accept the invite, load the circuit, and see each other. Test invite acceptance with MotoSim already open and when launched from the invitation.

## 2. Synchronize bikes without delaying controls

Each phone runs its own bike physics at the existing **240 Hz**. Start by sending a small state snapshot roughly **20 times per second** with a sequence number, position, velocity, orientation, steering, wheel speed, suspension travel, and rider pose. Animate remote bikes from interpolated snapshots. Start with an interpolation buffer near **100 ms**, tune it on real devices, and hold the last plausible pose if a connection stalls. Remote bikes pass through each other in the first release so packet delay cannot knock someone off their bike.

Send movement over GameKit’s unreliable channel so fresh snapshots can replace lost ones. Send session setup, readiness, and respawn events reliably. Include a respawn generation in snapshots and reset interpolation when it changes, so a remote bike snaps to the new location instead of sliding across the map. Version the message format and reject invalid or stale messages. [Apple GameKit delivery modes](https://developer.apple.com/documentation/gamekit/gkmatch/senddatamode)

**Acceptance** — Local controls stay responsive while remote bikes steer, lean, wheelie, land, and respawn. Simulate delay, jitter, and dropped packets and check that remote bikes recover smoothly.

## 3. Add imported tracks

The host announces the track’s content hash and the importer version. Each rider selects or uses a local copy of the same `.pkz`. Show exactly who needs the track or has a mismatch, and keep them in the lobby until their terrain is ready. Use a shared start point and heading, with small offsets so bikes appear beside one another. Each rider can keep their own bike setup for free ride.

**Acceptance** — Two players on the same imported track see each other at the same jump and landing. A same-named file with different content produces a clear mismatch message.

## 4. Handle disconnects and decide what to add next

Detect a dropped rider and remove their bike after a short grace period. Give the remaining riders a clear session status and let them leave or retry. For the first release, keep host departure simple by ending the shared session and letting everyone continue riding locally. Decide whether host migration or late joining is worth adding after the two-phone test.

If we later want bike collisions, shared deformable ruts, races, or persistent rooms, move those shared effects to a host or dedicated server that resolves one common world state. Keep the local bike responsive through prediction and reconcile it with authoritative results. Evaluate a server before expanding player count or supporting clients outside Apple platforms.

## Implementation order

Build the two-phone invite and remote-bike prototype first. Add imported-track checks once the network path is proven. Test with the built-in circuit and one shared `.pkz`, on Wi-Fi and cellular, before expanding to four riders.

## Track sharing update

Hosts upload the normalized imported terrain and artwork before sending a Game Center invite. The lobby passes a SHA-256 and a six-hour download grant. A guest reuses the current track or a cached package if its hash matches, otherwise it downloads and verifies the package automatically. Readiness is reported after the terrain renders. The built-in circuit needs only Game Center.

The [Go service setup](backend/README.md) uses the external Docker network `app-network`, an HTTPS reverse proxy, and a Docker volume with automatic expiry cleanup. A server-provisioned upload key authorizes custom-track hosts. Guests receive only the download grant.

Device acceptance still requires signed iPhones on separate networks. Verify both warm and cold invite acceptance, the built-in circuit, a guest downloading a custom track, a repeat invite with the track in cache, respawn snapping, and host departure.
