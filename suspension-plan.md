# MotoSim suspension improvement plan

Start by measuring what happens on landing and separating wheel movement from chassis movement. MotoSim currently estimates suspension travel from wheel overlap with the ground and uses that calculation to produce tire load. The fork and shock share a base spring rate and damping curve. The rebound sliders adjust extension damping, while the current telemetry leaves the cause of a landing bounce uncertain. [Current suspension solver](MotoSim/Physics/Motorcycle.swift#L286)

## 1. Measure the bounce

Extend the debug overlay with front and rear travel in millimeters, compression and rebound speed, tire load, and bottom-out events. Record a short trace around touchdown. Repeat the same jump to see which end kicks first, whether it bottoms, and when each tire loses contact.

## 2. Give each wheel its own suspension state

Add front and rear unsprung mass and integrate each wheel’s motion independently. Tire deflection produces ground force, while the fork and shock transmit force to the chassis. Add progressive bottom-out and top-out stops.

Run a flat drop and a downslope landing at fixed speeds. Check peak travel, time in contact, and how quickly the chassis settles.

## 3. Model the 2023 KTM 250 SX-F setup

Use a progressive air spring for the fork and a coil shock with a rising-rate rear linkage. Set travel to **310 mm front and 300 mm rear**. Use KTM’s **105 mm rear rider sag** as a baseline, measured using the manual’s procedure. Check sag with and without the rider. Fit the rear linkage’s motion ratio before tuning spring or damping forces at the wheel. [KTM owner’s manual](https://mobil.ktmshop.se/bike-manuals/23_3214641_en_OM.pdf)

## 4. Expand Ride Setup

Keep independent fork and shock rebound. Add fork compression, rear low- and high-speed compression, fork air pressure, and rear preload. Low and high speed refer to damper shaft speed, so a sharp landing can engage high-speed damping at low ground speed.

Verify that more rebound slows extension, that more compression damping changes how quickly travel is used, and that excessive rebound can leave the suspension compressed through successive whoops. [KTM owner’s manual](https://mobil.ktmshop.se/bike-manuals/23_3214641_en_OM.pdf)

## Implementation order

Implement phases 1 and 2 together, then tune on one repeatable landing and one whoop section. Use the traces to distinguish rebound kick, bottoming out, and loss of tire contact before adding more sliders. KTM’s published specifications give us travel, sag, and adjuster targets. The damping curves and linkage motion ratio need measurements or clearly labeled estimates.

## Initial air-fork simulation validation

The 240 Hz regression fixtures in [SuspensionTests.swift](Tests/SuspensionTests.swift) use a 0.45 m chassis drop on flat ground and on a 15% downslope at 6 m/s. The flat drop used about 145 mm front and 182 mm rear, with around 17 ms of front contact loss after touchdown. The downslope used about 150 mm front and 172 mm rear, with both tires loaded throughout the 750 ms capture. Both runs settled onto the surface. A separate 2.2 m drop with softer compression produced one rear bottom-out.

The whoop fixture starts at 8 m/s and uses five 200 mm bumps spaced 2 m apart. At the three later sampled valleys, the shock retained roughly 95–188 mm of travel at maximum rebound damping and 15–39 mm at minimum rebound damping. Higher compression settings reduced peak travel on the drop. Higher rebound settings reduced peak extension speed under load.

Ride Setup estimates rear sag using the change in distance between the rear axle and a chassis reference with the wheel fully extended and with the bike supported on flat ground. The defaults give approximately 103 mm with the rider and 46 mm without, compared with KTM’s 105 mm and 35 mm. The motion ratio is a rising-rate estimate calibrated around rider sag. The damping curves and air chamber geometry are estimates. [KTM owner’s manual](https://mobil.ktmshop.se/bike-manuals/23_3214641_en_OM.pdf)

## Coil fork update

Ride Setup now offers combined fork coil rates of 8, 10, 12, 14, and 16 N/mm, with 12 N/mm as the default. The landing, sag, bottom-out, and whoop regression tests also pass with the coil fork.
