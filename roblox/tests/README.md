# Driving tests (offline)

These run the real car scripts outside Roblox, so the driving can be checked after every
tuning change without opening Studio.

- `physics_test.luau` drives the car in a small physics simulation: resting, 0 to top speed,
  braking, reverse, steering direction, rollovers, handbrake drifts (including a full circle
  round a cone at 30 and 60 fps), ramp jumps, air control rates, backflips, crashes and
  respawns, parking on hills, boost, ice, curbs, and all three cars.
- `api_test.luau` runs the server and client scripts against a fake Roblox that knows every
  real class, property, method and Enum (from the `@rbxts/types` package). A typo like
  `part.Anchord` or `Enum.KeyCode.Spacebar` makes it fail.

The simulation is a simplified stand-in for Roblox physics. Passing tests mean the maths and
the logic are right; the final check is always driving it in Studio.

## Run them

Needs `curl`, `g++`, `python3` and `npm`.

```
cd roblox/tests
./setup.sh                    # builds ./luaurun and api.luau (first time only)
./luaurun physics_test.luau   # ends with ALL PASSED
./luaurun api_test.luau       # ends with API CHECK PASSED
```
