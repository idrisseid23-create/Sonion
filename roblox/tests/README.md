# Driving tests (offline)

These run the real car scripts outside Roblox, so the driving can be checked after every
tuning change without opening Studio.

- `physics_test.luau` drives the car in a small physics simulation: resting, 0 to top speed,
  braking, reverse, steering direction, rollovers, handbrake drifts (including a full circle
  round a cone at 30 and 60 fps), ramp jumps, air control rates, backflips, crashes and
  respawns, parking on hills, boost, ice, curbs, all three cars, and getting in (a car that
  sank, or got kicked, as you got in). `physics_test_60hz.luau` runs it all again with the
  physics stepping at 60 Hz instead of 240 Hz, because Roblox can run simple assemblies that
  slowly and some bugs only show there.
- `api_test.luau` runs the server and client scripts against a fake Roblox that knows every
  real class, property, method and Enum (from the `@rbxts/types` package). A typo like
  `part.Anchord` or `Enum.KeyCode.Spacebar` makes it fail.

The simulation is a simplified stand-in for Roblox physics. Passing tests mean the maths and
the logic are right; the final check is always driving it in Studio.

- `preview/` draws the cars. `export.luau` builds each car with the real `CarBuilder` and
  `CarLooks` (inside the API checker) and saves every visible part; `render.mjs` draws them
  with three.js in a headless browser, next to blocky avatars for scale, and saves pictures
  from several angles. Use it to check a design change before opening Studio.

## Run them

Needs `curl`, `g++`, `python3` and `npm`.

```
cd roblox/tests
./setup.sh                    # builds ./luaurun and api.luau (first time only)
./luaurun physics_test.luau        # ends with ALL PASSED
./luaurun physics_test_60hz.luau   # the same at 60 Hz physics, which Roblox can fall back to
./luaurun api_test.luau       # ends with API CHECK PASSED
```

Car pictures (also needs `node`; the first time, run `npm install` in `preview/`):

```
./luaurun preview/export.luau > preview/cars.json
cd preview && node render.mjs              # every car, every angle, into preview/out/
cd preview && node render.mjs Bolt hero    # one car, one angle (hero, rear, side, front, back, top, chase)
cd preview && node render.mjs Bolt lineup  # all three side by side
```

It uses Chromium's headless shell from `/opt/pw-browsers` if it is there; otherwise run
`npx playwright install chromium` once in `preview/`. Set `CHROMIUM` to use another browser.
