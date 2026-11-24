# MotoSim

MotoSim is a landscape iPhone motocross prototype for iOS 18 and later. It opens directly on an original dirt circuit with two jumps, a whoop section, and banked turns.

Open [MotoSim.xcodeproj](MotoSim.xcodeproj) in Xcode and run the **MotoSim** scheme. For a physical iPhone, select your development team in Signing & Capabilities.

## Ride

- Hold **Throttle** or **Brake** with your right thumb. Drag the left pad sideways to request bike lean and up or down to shift the rider's weight forward or back.
- **Tilt** calibrates steering to the way you're holding the phone. The left pad still controls rider weight.
- With an extended game controller connected, use the left stick horizontally for bike lean and steering. Use the right stick to shift the rider forward, back, left, or right. The right trigger controls throttle and the left trigger controls braking.
- For a wheelie, open the throttle in first gear and shift your weight back. On Xbox, squeeze **RT** and pull the **right stick down**. Ease off the throttle and return to neutral to lower the front.
- Open **Ride Setup** using the gear button to adjust maximum lean, tire grip, fork spring rate, rear preload, fork compression, shock low- and high-speed compression, and independent fork and shock rebound. Fork spring rates are selectable from 8 to 16 N/mm and represent the combined rate of both legs. Settings are saved on the phone. Shock compression responds to damper shaft speed. Higher rebound damping slows extension after a landing.
- In **Ride Setup → Diagnostics**, turn on **Tire & Suspension Telemetry**. Cyan shows where each wheel points, white shows how its contact patch is traveling along the ground, and orange shows the calculated tire force. The overlay displays brake input, bar angle, actual and requested lean, and each wheel’s slip, traction use, normal load, travel, compression or rebound speed, and bottom-out count. After a jump, **Export Last Touchdown CSV** saves up to 250 ms before touchdown and 750 ms after it, including chassis vertical speed and pitch rate. **LOCK** appears when a loaded tire nearly stops rotating while the bike is moving and the brake is applied.
- Use the speaker button to enable synthesized engine audio. **Reset** returns the bike to the starting area. After a crash, MotoSim looks for an upright spot from about two seconds earlier and restarts the bike there at rest.

## Motorcycle model

The custom Swift simulator runs at 240 Hz in SI units. RealityKit renders interpolated poses. The solver uses rounded tire profiles, load-sensitive combined grip with post-peak sliding, fork travel along the rake axis, independent unsprung wheel motion, tire deflection, separate compression and rebound damping, progressive end stops, and wheel angular momentum. At riding speed the stick requests up to 48° of bike lean. The virtual rider applies torque to an inertial steering assembly, with rake and front-tire reaction through mechanical trail. At riding speed the bars countersteer to initiate the requested lean. Direct roll assistance tapers with speed and tire forces determine the bike’s path. See the [steering research and validation notes](research/2026-11-23-technical-motorcycle-steering.md). The suspension uses 310 mm of fork travel and 300 mm of rear travel, with a coil-spring fork and a rising-rate coil shock. The travel and rear setup are based on the 2023 KTM 250 SX-F US. Ride Setup estimates rear sag with and without the rider. KTM specifies 105 mm of rider sag and 35 mm of static sag. The fork coil rates, linkage, unsprung masses, and damping curves are simulation estimates. [KTM owner’s manual](https://mobil.ktmshop.se/bike-manuals/23_3214641_en_OM.pdf)

Run the macOS physics tests from this directory with `swift test`. The tests cover steering direction, flat and downslope touchdown, bottom-out capture, suspension packing over whoops, acceleration and braking, consistent fixed steps across frame rates, tire grip, and takeoff through landing.

## Blender chassis

Export a model named `DirtBikeChassis.usdz` and add it to the MotoSim app target. Use meters, Y up, and +Z forward in RealityKit coordinates. Place the origin at the chassis reference point, about 0.83 m above level ground at rest. The procedural wheel centers sit approximately 0.74 m ahead of and behind this origin. Export the frame, engine and plastics as the chassis. The app continues to render and animate its own forks, wheels, swingarm and rider. The procedural chassis serves as the default and as the fallback if the import fails.

## Import an MX Bikes track

Open **Track → Import MX Bikes Track** and select an unlocked `.pkz` in Files. MotoSim reads the compiled `.trh` heightfield directly from the archive. You can also choose an unpacked track folder or an editable source folder with a `.tht` or `.hmf` descriptor and its referenced 16-bit little-endian RAW heightmap. MotoSim prefers `.tht` for collision when both descriptors are present and reads the matching `.hmf` for visual layers.

Tap the preview to choose a starting location, adjust the heading, and choose **Ride**. MotoSim saves the most recently confirmed import and its start point on the device, then opens that track automatically on launch. Use **Track → Change Start Point** to move to a different section or **Track → Ride MotoSim Circuit** to return to the built-in track. The Track menu also lists the saved import when you’re riding another track.

The importer supports heightfield tracks. It reads supported embedded centerlines for the start preview and begins the ride on the authored route. For supported TerrainEd MP2 material stacks, MotoSim composites the archive’s diffuse textures, repetitions, and placement masks. Source folders can supply equivalent dry TGA layers through `.hmf`. An aligned `track_map.tga` can supply ground colors when a compiled material stack is unavailable. Baked ground artwork travels with the terrain in Free Ride. Supported MP2 grass records also provide the original blade cards, shape settings, and placement density maps. The app draws that grass near the rider and shares those assets in the track package. The importer preserves all authored height samples on supported grids up to 4,097 per axis. Physics uses that grid everywhere. For grids larger than 2,049 samples on either axis, the renderer uses the native mesh near the rider and coarser tiles at a distance. Compiled ground artwork is baked into an atlas up to 2,048 pixels per axis. Locked archives, mesh-only tracks, compiled scenery models, unsupported vegetation records, and race rules are outside the current importer.

[PiBoSo track tools and example source files](https://forum.mx-bikes.com/index.php?topic=89.0)

## Online Free Ride

Start the [Go multiplayer server](backend/README.md) and install the current MotoSim build on both players’ devices. Open **Track → Free Ride** and choose **Host Free Ride**. Share the room code. Guests enter it under **Join** and connect to the same server. The host starts once all riders are ready.

A local Debug build configured for custom-track hosting uploads the terrain and ground art automatically. Guests download a verified copy if needed. See the server setup for configuring the host test build. The built-in circuit and joining a room require only the server address and, for guests, the room code.
