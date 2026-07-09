# 🕯️ NIGHTFALL

*[Читать на русском](README.ru.md)*

A first-person **horror game**, built in [Godot 4](https://godotengine.org/).

You wake in a torchlit dungeon with no light of your own. **Something is in
here with you.** Crack open the key-chests, take the stairs down — floor
after floor, deeper into the dark, with no way back up. Read the scraps of
paper left by those before you. And pray *The Stalker* doesn't find you —
because when it does, it catches you. Every floor down it grows faster and
keener, the torches thin out, more keys lock the door, and your mind frays
quicker. How deep can you get?

There's also a **story mode**: a handful of handmade, non-procedural levels
built around a personal memory rather than the endless descent.

```
  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
  ▓ · ·  N I G H T ·▓      >  a torch, a dungeon, and two red eyes
  ▓ F A L L · · ·  ·▓      >  that are getting closer
  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
```

## Features

- **Procedural dungeon** — every floor is a fresh layout of rooms joined by
  corridors, drawn as real 3D geometry (`GridMap`), lit only by flickering
  wall torches against a near-black ambient and fog — no player flashlight.
  Walls and floors carry a procedurally generated stone-brick texture that
  grows more cracked and blood-stained the deeper you go.
- **The Stalker** — an AI with real perception. It **hunts** what it can see
  (line-of-sight) or hear (running is loud). Break its line of sight and it
  drops to **search** mode, walking to where it last sensed you, then
  **wanders** the halls — investigating chests, noise, and its patrol route —
  until it catches your trail again. Pathing is a breadth-first flood-field
  toward its current focus, closing in on your exact position for the final
  approach. It roars when it first spots you and growls while it hunts.
- **Three horrors** — deeper floors unlock new predators: the **Listener** is
  blind but homes on any footstep; the **Watcher** only moves while you're
  *not* looking at it, then rushes in silence.
- **Stamina & stealth** — sprinting is fast but burns a stamina bar. Walk to
  stay quiet, or dive into a **locker** (`E`) to break line of sight.
- **It hunts by sound** — running, a chest cracking open, or a match hissing
  alight all leave a noise trail the Stalker will investigate even if it
  never saw you directly.
- **Rocks — throw a distraction** — press `G` to hurl one down the corridor
  you're facing; it cracks against stone loud enough to pull the Stalker
  toward the sound instead of you.
- **Matches — light vs. hide** — press `F` for a few seconds of light that
  steadies your nerves, but the glow lets the Stalker spot you from farther
  away.
- **Sanity** — your composure erodes in the dark, faster while the Stalker
  hunts you. A red vignette closes in as your mind frays.
- **Biomes** — each floor belongs to one of six palettes (Catacombs, Flooded
  Tier, Furnace, Bone Crypt, Frosthold, Abyss), cycled by depth, shown on the
  HUD.
- **Lore notes** — scraps of paper pinned to the walls; press `E` to read
  what the last visitor scrawled before the whispering took them.
- **Story mode** — a separate, non-procedural mode: a two-storey house,
  scripted encounters, and popup memories as you approach.

## Run it

There's no prebuilt download yet — you run it from source with the Godot 4
engine, which is free and open source.

### Install Godot 4

Ubuntu's package manager only ships Godot 3, so grab the official Godot 4
build directly instead:

1. Download the build for your OS from the
   [Godot download page](https://godotengine.org/download/) (Linux, macOS,
   and Windows are all supported; look for something like
   `Godot_v4.x-stable_linux.x86_64.zip` on Linux).
2. On Linux, unzip it and make the binary executable:
   ```bash
   unzip Godot_v4.*-stable_linux.x86_64.zip
   chmod +x Godot_v4.*-stable_linux.x86_64
   ```
3. Put it somewhere on your `PATH` so you can just type `godot4`, e.g.:
   ```bash
   mkdir -p ~/.local/bin
   mv Godot_v4.*-stable_linux.x86_64 ~/.local/bin/godot4
   ```
   Make sure `~/.local/bin` is actually on your `PATH` (check with
   `echo $PATH` — if it's missing, add
   `export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc` and open a new
   terminal). On macOS/Windows, just run the downloaded Godot editor
   directly instead of aliasing it to `godot4`.

### Get the source and run it

```bash
git clone https://github.com/KoDiK2005/nightfall.git
cd nightfall/godot        # the folder with project.godot in it
godot4 .                  # opens straight into the game
```

or, to open it in the editor first (useful if you want to look around the
scenes/scripts, not just play):

```bash
godot4 -e .
```

Then press the ▶ button (top-right) or `F5` to run.

On the title screen: `W`/`S` (or the arrow keys) picks between "БЕСКОНЕЧНЫЙ
СПУСК" (the endless descent) and "СЮЖЕТ" (story mode), `Enter` starts. All
letter keys bind to the physical key position, so there's no need to switch
your keyboard layout to English.

## Controls

| Key            | Action        |
|----------------|---------------|
| `W` `A` `S` `D`| Move          |
| Mouse          | Look (free, up/down too) |
| `Shift`        | Run (uses stamina) |
| `E`            | Open a chest · hide in / leave a locker · read / close a note |
| `F`            | Strike a match (light vs. being seen) |
| `G`            | Throw a rock (a lure, away from you) |
| `Enter`        | Start         |
| `R`            | Retry / replay (on the caught screen) |
| `Esc`          | Pause / resume (`Q` in the pause menu quits to the title) |

## How it works

| Path                       | Role                                                  |
|-----------------------------|-------------------------------------------------------|
| `godot/project.godot`       | Godot project entry point                             |
| `godot/scripts/game_state.gd` | Global mode/state machine (title/play/caught, endless vs. story) |
| `godot/scripts/level_gen.gd`| Procedural room+corridor generation, `GridMap` painting, torches, chests/exit, procedural wall/floor/chest/locker textures |
| `godot/scripts/monster.gd`  | The three horrors' AI: perception, pathing, growls     |
| `godot/scripts/player.gd`   | Movement, stamina, sanity                              |
| `godot/scripts/story_level.gd` | The handmade story-mode house/yard and its scripted scenes |
| `godot/scripts/biomes.gd`   | Per-depth palette + wall/floor texture generation       |
| `godot/scripts/audio_manager.gd` | Ambient drone, heartbeat, footsteps               |
| `godot/test/`               | Headless self-tests (see below)                        |
| `assets/`                   | Sound assets shared with the (now removed) original build |
| `tools/`                    | Standalone Python scripts that generated some of those sounds/images |

## Tests

The game's logic is covered by headless self-tests (no window or
rendering — they drive the real game methods). From `godot/`:

```bash
./run_tests.sh
```

They assert the whole endless loop (generation / connectivity / key pickup /
descent / catch), the story phase progression, and the pause menu. Worth
running after editing scripts: a parse error in any `.gd` fails the whole
scene load, and the tests catch it.

## History

This started as a hand-rolled C11/SDL2/OpenGL engine and was ported to Godot
4 feature-by-feature. As of 2026-07-09 the Godot port is feature-complete
enough that the original C build was removed from the repo — Godot is now
the only version. The old build's design (procedural textures, the AI's
perception model, the noise/lure system) still informs how things get
ported here; if you're curious what it looked like, check the git history.

## License

MIT — see [LICENSE](LICENSE).
