# 🕯️ NIGHTFALL

*[Читать на русском](README.ru.md)*

A first-person **horror game for Linux and Windows**, written in C on a hand-rolled
engine (SDL2 + OpenGL 3.3 + SDL2_mixer). No game engine, no external art —
the walls, the monster and the sound are all generated in code.

The primary build renders the maze as **real 3D geometry** through an OpenGL
pipeline with free mouse-look (yaw *and* pitch). The original **raycasting**
renderer is kept as a GPU-free fallback (`make run-classic`).

You wake in a torchlit maze with no light of your own. **Something is in
here with you.** Crack open the key-chests, take the stairs down — floor
after floor, deeper into the dark, with no way back up. Read the
scraps of paper left by those before you. And pray *The Stalker* doesn't
find you — because when it does, it fills the screen. Every floor down it
grows faster and keener, the torches thin out, more keys lock the door,
and your mind frays quicker. How deep can you get?

```
  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
  ▓ · ·  N I G H T ·▓      >  a flashlight, a maze, and two red eyes
  ▓ F A L L · · ·  ·▓      >  that are getting closer
  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
```

## Features

- **Real-3D OpenGL renderer** — the maze is genuine textured 3D geometry
  (walls, floor, ceiling, solid locker cabinets) drawn through an OpenGL 3.3
  core pipeline with a perspective camera, free mouse-look, warm per-fragment
  torch point-lights + distance fog, additive flame glows, and camera-facing
  billboards for the entities. HUD, menus and the jumpscare
  are drawn into a software buffer and composited over the scene as an overlay.
  (A software raycaster fallback ships as `nightfall-classic`.)
- **The Stalker** — an AI with real perception. It **hunts** what it can see
  (line-of-sight) or hear (footsteps — running is loud). Break its line of
  sight and it drops to **search** mode, walking to where it last sensed you,
  then **wanders** the halls until it catches your trail again. Navigation is
  a breadth-first flood-field toward its current focus. It is slower than you.
  It never truly stops.
- **Three horrors, each a different game** — deeper floors unlock new
  predators (first met on floors 4 and 7): the **Listener** is blind but homes
  on any footstep, so you freeze when it's near and move only when it's far;
  the **Watcher** only moves while you're *not* looking at it, then rushes in
  silence — stare to freeze it, look away to advance. A fading warning on entry
  teaches each one's rule, and every kind wears its own pallor.
- **Stamina & stealth** — sprinting is fast but burns a stamina bar; run dry
  and you're stuck at a walk while it recovers. Walk to stay quiet, or dive
  into a **locker** (press `E`) to break line of sight and let it lose you.
- **It hunts by sound** — noise leaves a trail the Stalker investigates even
  when it never saw you: pounding feet as you run, a chest cracking open, a
  match hissing alight. It heads for the sound and searches there, so a careless
  noise pulls it in — but a well-placed one can lure it away. Its ears sharpen
  the deeper you go, until a sound carries the whole width of the floor.
- **Rocks — throw a distraction** — scavenge a few off the floor and press
  `G` to hurl one down the corridor you're facing. It strikes stone and
  cracks loud enough for the Stalker to go investigate the sound instead of
  you — a deliberate lure, on demand, instead of hoping a careless noise
  works in your favour.
- **Sanity** — your composure erodes in the dark, faster when the Stalker
  hunts you and worst of all when it has you in *sight*. As your mind frays
  the world answers: a breathing vignette closes in, the shadows bleed red,
  whispers crowd together, the torches fail more often, and the whole frame
  begins to tremble. Steal a quiet moment and it slowly recovers.
- **Your own hallucinations** — drop photos into `photos/`, run
  `python tools/photos2visions.py`, and they get graded into blood-red
  screamers that flash across the screen as your sanity collapses. Bring your
  own nightmares. (See [photos/README.md](photos/README.md).)
- **Chests & screamers** — the three keys are locked in iron-bound chests
  you crack open with `E`. Every chest you open slams one of your photos
  edge-to-edge across the screen — a guaranteed jump-scare. A golden
  *key-sense* compass at the top of the HUD points you toward the nearest
  chest, brighter the closer you get and dimmer as your mind frays.
- **Torchlight, no flashlight** — you carry no steady light of your own. The
  halls are near-black; the only illumination comes from flickering **wall
  torches** (warm per-fragment point lights), so you move between islands of
  firelight through the dark. Random **power surges** make the flames stutter.
- **Matches — light vs. hide** — a scarce resource you scavenge off the floor.
  Strike one with `F` for a few seconds of light that steadies your nerves and
  reveals the way, but the glow lets the Stalker spot you from much farther. A
  gamble every time. (The blind Listener can't see it — so it's safe there.)
- **Procedural dread audio** — a low drone that swells with danger, a
  heartbeat that races as the Stalker nears, footsteps, and a jumpscare
  scream. Generated by `tools/gen_audio.py` (Python standard library only).
- **Endless descent that scales** — every floor is a fresh procedural maze,
  and it gets harder the deeper you go: the Stalker speeds up and its senses
  sharpen, torches are placed more sparsely so the dark closes in, sanity
  drains faster, and more keys (up to six) lock the way down. Your deepest
  floor is tracked and shown on the death screen — chase the record.
- **Biomes** — each floor belongs to one of six biomes (Catacombs, Flooded
  Tier, Furnace, Bone Crypt, Frosthold, Abyss), cycled by depth. Each recolours
  the stone and resets the ambient light and torch tint, so the descent moves
  through visibly distinct places; the biome name shows on the HUD.
- **Lore notes** — scraps of paper scattered through the dark; press `E` to
  read what the last visitor scrawled before the whispering took them.

## Build & run

There's no prebuilt download — you build it yourself from source, which is
why every step below (including the tools you need to install) is spelled
out in full.

### Linux (Debian / Ubuntu)

1. Install everything needed to get the code and build it — `git` to
   download the source, `make` to run the build, `gcc` to compile it,
   `python3` for the audio generator, plus the SDL2/OpenGL libraries the
   game itself links against:
   ```bash
   sudo apt install -y git make gcc libsdl2-dev libsdl2-mixer-dev libgl1-mesa-dev python3
   ```
2. Download the source code:
   ```bash
   git clone https://github.com/KoDiK2005/nightfall.git
   cd nightfall
   ```
3. Build the game:
   ```bash
   make
   ```
   This generates the audio assets and compiles the 3D build (`nightfall`).
4. Run it:
   ```bash
   ./nightfall
   ```
   (or just `make run`, which builds and launches in one step)

### macOS

1. Install [Homebrew](https://brew.sh/) if you don't have it yet, then install
   everything needed to get the code and build it — `git`, `make`/`gcc` come
   from Apple's Command Line Tools, so install those first, then the
   SDL2 libraries and `pkg-config`:
   ```bash
   xcode-select --install
   brew install sdl2 sdl2_mixer pkg-config python3
   ```
2. Make sure Homebrew's `pkg-config` files are on `PKG_CONFIG_PATH` (needed
   for the build to find SDL2 — Homebrew doesn't add this to your shell by
   default). On Apple Silicon Homebrew lives under `/opt/homebrew`, on Intel
   Macs under `/usr/local`:
   ```bash
   export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig:$PKG_CONFIG_PATH"
   ```
   (Add that line to your `~/.zshrc` so you don't have to repeat it.)
3. Download the source code:
   ```bash
   git clone https://github.com/KoDiK2005/nightfall.git
   cd nightfall
   ```
4. Build the game:
   ```bash
   make
   ```
   This generates the audio assets and compiles the 3D build (`nightfall`).
   The Makefile links OpenGL as a macOS framework, not `libGL`, so no extra
   flags are needed.
5. Run it:
   ```bash
   ./nightfall
   ```
   (or just `make run`, which builds and launches in one step)

   macOS's OpenGL driver is deprecated (Apple has pushed everyone toward
   Metal since Mojave) but still ships and still supports the 3.3 core
   profile this game requests, so the real-3D build runs natively — no
   translation layer needed. If a particular Mac's driver ever refuses to
   create that context, fall back to `make run-classic` below, which needs
   no GPU-specific API at all.

### Windows (MSYS2 / MinGW)

1. Install [MSYS2](https://www.msys2.org/) — this gives you a Linux-like
   terminal and package manager (`pacman`) on Windows, which is what the
   next steps use.
2. Open an **MSYS2 UCRT64** shell (look for "MSYS2 UCRT64" in the Start menu —
   not the plain "MSYS2" shell) and install everything needed to get the
   code and build it:
   ```bash
   pacman -S --needed git mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-make \
     mingw-w64-ucrt-x86_64-pkgconf mingw-w64-ucrt-x86_64-SDL2 \
     mingw-w64-ucrt-x86_64-SDL2_mixer python
   ```
3. Download the source code (still inside that same MSYS2 UCRT64 shell):
   ```bash
   git clone https://github.com/KoDiK2005/nightfall.git
   cd nightfall
   ```
4. Build the game:
   ```bash
   mingw32-make
   ```
   This generates the audio assets and compiles the 3D build (`nightfall.exe`).
   (`mingw32-make` is just the historical name of the `make` binary that
   ships with every MinGW toolchain — it builds a 64-bit `nightfall.exe`
   here, same as the packages above; nothing 32-bit is actually involved.)
5. Run it:
   ```bash
   ./nightfall.exe
   ```
   (or just `mingw32-make run`, which builds and launches in one step)

**Sharing the .exe with someone else (e.g. a tester)?** `nightfall.exe` is
dynamically linked against `SDL2.dll`, `SDL2_mixer.dll` and `zlib1.dll`,
which live in MSYS2's `ucrt64\bin`. That's on `PATH` inside the MSYS2 shell,
so it runs fine for you there — but if you just hand someone the bare `.exe`,
double-clicking it fails with errors like *"SDL2.dll was not found"*. Run
this instead to gather the exact DLLs it needs right next to it:
```bash
mingw32-make dist
```
Then zip up the whole folder (the `.exe`, the `.dll` files, and `assets/`)
and send that — it'll run standalone on a machine with no MSYS2 installed.

### Optional: classic software-raycaster fallback

No GPU, or an OpenGL 3.3 driver acting up? There's an older raycasting build
that needs no GPU at all — same gameplay, a flat 2.5D look instead of real 3D:

```bash
make run-classic          # Linux
mingw32-make run-classic  # Windows (from the same MSYS2 UCRT64 shell)
```

Make sure `C:\msys64\ucrt64\bin` is on your `PATH` (or run from the "MSYS2 UCRT64"
shell shortcut) so the built `.exe` can find `SDL2.dll` and friends.

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
| `R`            | Retry / replay|
| `Esc`          | Pause / resume (in the pause menu: `W`/`S` pick, `A`/`D` adjust, `Q` to title, `C` copies the bug-report log) |

## Found a bug?

Every run writes `nightfall_log.txt` next to the executable — the seed, which
floor and chest you were on, and how the run ended (caught, or quit). Nothing
is ever sent anywhere; it's a local file for you. Press `C` in the pause menu
to copy it straight to your clipboard, then paste it into a new
[GitHub issue](https://github.com/KoDiK2005/nightfall/issues) — no need to
go hunting for the file.

## How it works

| File                | Role                                                        |
|---------------------|-------------------------------------------------------------|
| `src/main.c`        | 3D build entry point: window/audio setup, event loop, player input |
| `src/game.h`        | Shared types and cross-file declarations for the 3D build   |
| `src/gen.c`         | Level generation: rooms, biomes, pathing, chests             |
| `src/ai.c`          | The monster's brain and the sanity/dread system              |
| `src/audio.c`       | Procedural dread audio                                       |
| `src/render.c`      | GL setup, procedural textures/sprites, world mesh, render passes |
| `src/hud.c`         | 2D overlay: font, HUD, menus, hallucinations                 |
| `src/log.c`         | Writes `nightfall_log.txt` for bug reports (nothing is sent over the network) |
| `src/raycast.c`     | Classic software-raycaster build (`nightfall-classic`)      |
| `tools/gen_audio.py`| Synthesises every `.wav` from scratch                        |
| `tools/photos2visions.py`| Grades photos in `photos/` into sanity-loss screamers  |
| `assets/`           | Generated sounds (committed so the repo runs out of the box)|
| `assets/visions/`   | Your PNG hallucinations, flashed when sanity is low         |
| `Makefile`          | `make` builds 3D, `make classic` the fallback, `make audio` |

## License

MIT — see [LICENSE](LICENSE).
