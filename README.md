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
  away — and keeps leaking a faint noise the whole time it burns, so even a
  monster without a direct line of sight can be drawn toward it.
- **Flares — a decoy that isn't you** — press `H` to plant a burning flare at
  your feet; it keeps making noise on its own for several seconds after you
  walk away, pulling a hunting monster to the wrong spot while you slip out
  another way.
- **Foot wraps — the counter to the Listener** — press `J` to muffle your own
  footsteps for a while: no noise trail from sprinting, and both the Stalker
  and the (otherwise blind) Listener hear you from much closer. The only
  direct answer to a monster that has no eyes.
- **Searchable crates & a shrine altar** — a couple of the crates scattered
  through each floor hide a spare consumable (`E` to search, once each), and
  one guaranteed altar per floor rewards a prayer (`E`) with a chunk of
  sanity back — both mark themselves with a faint golden glow.
- **Sanity** — your composure erodes in the dark, faster while the Stalker
  hunts you. A red vignette closes in as your mind frays.
- **Biomes** — each floor belongs to one of six palettes (Catacombs, Flooded
  Tier, Furnace, Bone Crypt, Frosthold, Abyss), cycled by depth, shown on the
  HUD.
- **Lore notes** — scraps of paper, either pinned to a wall or left lying flat
  on a desk; press `E` to read what the last visitor scrawled before the
  whispering took them.
- **Cell rooms** — some rooms are lined with rusted iron cages and dark pools
  on the stone, a grimmer decor set than the usual rubble and crates.
- **Story mode** — a separate, non-procedural mode: a two-storey house,
  scripted encounters, and popup memories as you approach.

## Run it

There's no prebuilt download yet — you run it from source with the Godot 4
engine, which is free, open source, and needs no account or installer (just
an executable you download and run). Pick your OS below.

### 1. Get the source code

If you have `git`:

```bash
git clone https://github.com/KoDiK2005/nightfall.git
```

If you don't want to install `git`, you can instead download a ZIP of the
repo: on the GitHub page, click the green **Code** button →
**Download ZIP**, then extract it anywhere. Either way you end up with a
`nightfall` folder that contains a `godot` subfolder — that inner folder
(the one with `project.godot` in it) is what you'll open in Godot.

### 2. Install Godot 4

The game needs **Godot 4** specifically (4.2 or newer; developed against
4.7) — not Godot 3, which is what some Linux package managers still ship by
default. Download it once from the official
[Godot download page](https://godotengine.org/download/) and it works for
every project, this one included.

<details open>
<summary><b>Windows</b></summary>

1. On the [download page](https://godotengine.org/download/windows/), grab
   **Godot 4 · Standard · Windows Desktop** — a `Godot_v4.x-stable_win64.exe`
   (or `_win32.exe` on very old 32-bit systems) or a `.zip` containing it.
2. If you got a `.zip`, right-click it → **Extract All**.
3. Double-click the `.exe`. Windows SmartScreen may say "Windows protected
   your PC" the first time (it's an unsigned/unrecognized binary, not a
   virus) — click **More info**, then **Run anyway**.
4. That single `.exe` *is* the whole engine — nothing to install, no
   installer wizard. Godot opens straight into the **Project Manager**.
5. Click **Import**, browse to the `nightfall\godot` folder from step 1, and
   select `project.godot` (or the folder itself). Click **Import & Edit**.
6. The project opens in the editor. Press `F5` or the ▶ button (top-right)
   to play.

Prefer the command line (PowerShell)? Rename/move the `.exe` somewhere handy
(e.g. `C:\Godot\Godot.exe`), then:

```powershell
cd path\to\nightfall\godot
& "C:\Godot\Godot.exe" .          # play immediately
& "C:\Godot\Godot.exe" -e .       # open in the editor instead
```

</details>

<details open>
<summary><b>macOS</b></summary>

1. On the [download page](https://godotengine.org/download/macos/), grab
   **Godot 4 · Standard · macOS** — `Godot_v4.x-stable_macos.universal.zip`
   (one build works on both Intel and Apple Silicon Macs).
2. Double-click the zip to extract `Godot.app`, then drag it into
   `/Applications` (or anywhere you like).
3. Gatekeeper will refuse to open it the first time ("Godot can't be opened
   because it is from an unidentified developer"). Either:
   - Right-click (or Control-click) `Godot.app` → **Open** → **Open** in the
     confirmation dialog, *or*
   - Run once in Terminal: `xattr -dr com.apple.quarantine /Applications/Godot.app`
4. Open `Godot.app`. In the **Project Manager**, click **Import**, navigate
   into the `nightfall/godot` folder from step 1, and select
   `project.godot`. Click **Import & Edit**.
5. Press `F5` or the ▶ button (top-right) to play.

Prefer the command line? The binary lives inside the `.app` bundle; symlink
it once so `godot4` works like on Linux:

```bash
sudo ln -s /Applications/Godot.app/Contents/MacOS/Godot /usr/local/bin/godot4
cd path/to/nightfall/godot
godot4 .          # play immediately
godot4 -e .       # open in the editor instead
```

</details>

<details>
<summary><b>Linux</b></summary>

Most distro package managers (Ubuntu/Debian's `apt`, Fedora's `dnf`, etc.)
only ship Godot 3, so grab the official Godot 4 build directly instead —
or use Flatpak, if you'd rather not manage `PATH` by hand.

**Option A — official binary:**

1. On the [download page](https://godotengine.org/download/linux/), grab
   **Godot 4 · Standard · Linux** — `Godot_v4.x-stable_linux.x86_64.zip`
   (or `_arm64` on ARM machines, e.g. some Raspberry Pi / ARM laptops).
2. Unzip it and make the binary executable:
   ```bash
   unzip Godot_v4.*-stable_linux.x86_64.zip
   chmod +x Godot_v4.*-stable_linux.x86_64
   ```
3. Put it somewhere on your `PATH` so you can just type `godot4`:
   ```bash
   mkdir -p ~/.local/bin
   mv Godot_v4.*-stable_linux.x86_64 ~/.local/bin/godot4
   ```
   Make sure `~/.local/bin` is actually on your `PATH` (check with
   `echo $PATH` — if it's missing, add
   `export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc` or `~/.zshrc` and
   open a new terminal).

**Option B — Flatpak** (handles updates and `PATH` for you):

```bash
flatpak install flathub org.godotengine.Godot
flatpak run org.godotengine.Godot --path path/to/nightfall/godot
```

(add `-e` before `--path` to open the editor instead of playing directly)

</details>

### 3. Run the game

From a terminal, with `godot4` on your `PATH` (Linux/macOS) or the full
path to the `.exe` (Windows) — see your OS's section above for the
one-off setup:

```bash
cd nightfall/godot        # the folder with project.godot in it
godot4 .                  # opens straight into the game
```

or, to open it in the editor first (useful if you want to look around the
scenes/scripts, not just play):

```bash
godot4 -e .
```

Then press the ▶ button (top-right) or `F5` to run. If you used a GUI
Import instead of the command line (Windows/macOS above), the project is
already open in the editor at this point — just press `F5`.

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
| `E`            | Open a chest · hide in / leave a locker · search a crate · pray at an altar · read / close a note |
| `F`            | Strike a match (light vs. being seen) |
| `G`            | Throw a rock (a lure, away from you) |
| `H`            | Drop a flare (a lure that keeps working after you leave) |
| `J`            | Wrap your feet (muffle your footsteps for a while) |
| `Enter`        | Start         |
| `R`            | Retry / replay (on the caught screen) |
| `Esc`          | Pause / resume (`Q` in the pause menu quits to the title) |

All of the above are consumable — check the item counts in the
bottom-right of the HUD. Matches/rocks are common, flares/wraps are rare
finds, crates/altars are limited per floor.

## How it works

| Path                       | Role                                                  |
|-----------------------------|-------------------------------------------------------|
| `godot/project.godot`       | Godot project entry point                             |
| `godot/scripts/game_state.gd` | Global mode/state machine (title/play/caught, endless vs. story) |
| `godot/scripts/level_gen.gd`| Procedural room+corridor generation, `GridMap` painting, torches, chests/lockers/crates/altar/cell rooms/exit, all the procedural stone/wood/metal textures |
| `godot/scripts/monster.gd`  | The three horrors' AI: perception, pathing, growls     |
| `godot/scripts/player.gd`   | Movement, stamina, sanity, interact-target tracking (locker/crate/altar) |
| `godot/scripts/items.gd`    | Matches, rocks, flares, foot wraps — the `F`/`G`/`H`/`J` consumables |
| `godot/scripts/flare.gd`    | The dropped flare's self-refreshing noise + burn-out light |
| `godot/scripts/notes.gd`    | Lore notes: wall-pinned or lying flat on a desk, `E` to read |
| `godot/scripts/hud.gd`      | On-screen HUD, vignette/post-fx, jump-scare flashes, interact prompts |
| `godot/scripts/torch.gd`    | Wall torch: light, flicker, procedural flame + dust motes |
| `godot/scripts/story_level.gd` | The handmade story-mode house/yard and its scripted scenes |
| `godot/scripts/biomes.gd`   | Per-depth palette + wall/floor/ceiling texture generation |
| `godot/scripts/audio_manager.gd` | Ambient drone, heartbeat, footsteps               |
| `godot/test/`               | Headless self-tests (see below)                        |
| `assets/`                   | Sound assets shared with the (now removed) original build |
| `tools/`                    | Standalone Python scripts that generated some of those sounds/images |

### Dev hooks

A handful of environment variables skip straight to a specific situation —
handy for testing without a full playthrough. Set them before launching,
e.g. `NIGHTFALL_AUTOPLAY=1 godot4 .`:

| Variable                | Effect                                              |
|--------------------------|------------------------------------------------------|
| `NIGHTFALL_AUTOPLAY=1`   | Skip the title screen straight into the endless mode |
| `NIGHTFALL_STORY=1`      | Skip straight into story mode                        |
| `NIGHTFALL_STORY_ROAM=1` | Story mode, free-roam inside the house                |
| `NIGHTFALL_DEPTH=<n>`    | Start the endless descent at floor `n`                |
| `NIGHTFALL_SHOWEXIT=1`   | Spawn right in front of the (already unlocked) exit door |
| `NIGHTFALL_SHOWCRATE=1`  | Spawn in front of a searchable crate, if the floor has one |
| `NIGHTFALL_SHOWDESK=1`   | Spawn over a desk with a note on it, if the floor has one |
| `NIGHTFALL_SHOWALTAR=1`  | Spawn in front of the floor's shrine altar             |
| `NIGHTFALL_SHOWCELL=1`   | Spawn in front of a cage, if the floor rolled a cell room |
| `NIGHTFALL_SHOWMON=1`    | Freeze the monster in place (for screenshots)          |
| `NIGHTFALL_SHOWVISION=<n>` | Hold hallucination image `n` on screen (instead of a brief low-sanity flash) |
| `NIGHTFALL_AITRACE=1`    | Print the monster's state/position once a second       |
| `NIGHTFALL_GDTRACE=1`    | Print level-generation trace                           |
| `NIGHTFALL_FPS=1`        | Print FPS once a second                                |

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
