# preflight-stacks

Install a whole mod list without hunting through Nexus pages: framework downloads are automatic, and
the Nexus files you still have to click are queued so you never search for one.

```
core-2.5.yaml   8 frameworks, 0 Nexus clicks
my-mods.yaml    your list: those 8 + one page per extra mod
```

## What it can and cannot do

| Part | Clicks |
|---|---|
| Frameworks (RED4ext, redscript, CET, ArchiveXL, TweakXL, Codeware, Input Loader, Mod Settings) | **0** — `preflight install core` downloads from GitHub, sha256-verifies, installs as one undoable transaction |
| A Nexus mod you added | **1 per file** — the queue opens its Files page; you click "Mod manager download"; Vortex receives the `nxm://` link and saves the file |

Nexus allows one website click per file for a free account, and Preflight never builds or caches
download links — that is the line that keeps the tool allowed. So "one click instead of a thousand"
means: **one double-click starts the run, then one click per file, in order, with no searching and
no re-doing what is already installed.** Premium accounts can use a Nexus Collection in Vortex for a
true one-click install; this folder is for everyone else.

## Use it

Windows (double-click `install-stack.ps1`, or):

```powershell
.\install-stack.ps1                      # pick a stack, plan, install frameworks, walk the queue
.\install-stack.ps1 -Stack stacks\core-2.5.yaml -PlanOnly
```

Linux / macOS:

```bash
./install-stack.sh stacks/core-2.5.yaml "/path/to/Cyberpunk 2077"
PLAN_ONLY=1 ./install-stack.sh            # just the click count and the compatibility check
```

It needs `preflight` next to this folder (`preflight.exe` on Windows) — build it with
`cargo build --release -p preflight-cli` in `../preflight`, or put it on `PATH`.

Before anything downloads, `preflight stack plan` checks every member against the installed game
build and exits **3** if one of them cannot work (for example a framework with no 2.5 release). A
blocked stack changes nothing.

## Add your own mods

```bash
python add-mod.py --stack stacks/my-mods.yaml \
  --url "https://www.nexusmods.com/cyberpunk2077/mods/12345?tab=files" \
  --name "Better Saves" --file "*BetterSaves*"
```

`--file` is a fragment of the downloaded file name ( `*` and `?` work); the queue uses it to notice
the download arrived. Then run the stack as usual. Nothing is uploaded or shared.

## Where things land

- Downloads: Vortex's own folder (`%APPDATA%\Vortex\downloads\cyberpunk2077`), so Vortex sees the
  file immediately and installs it. The script falls back to your `Downloads` folder if Vortex has
  never run.
- Queue progress: `<state-dir>/queue/<stack>.json`, i.e. `%LOCALAPPDATA%\preflight\queue\`.
  Re-running resumes; `preflight stack next` also skips files that already arrived.
- Installed frameworks: the game folder, journaled. `preflight undo --game <dir> <txid>` reverses
  the whole install.

## Collections (one double-click, no preflight needed)

If someone already assembled a [Nexus collection](https://www.nexusmods.com/cyberpunk2077/collections),
`install-collection.bat` hands its `nxm://` URL straight to Vortex:

```powershell
.\install-collection.ps1 https://www.nexusmods.com/cyberpunk2077/collections/<slug>
.\install-collection.ps1 <slug>                    # or just the slug
.\install-collection.ps1                           # pastes into a prompt
.\install-collection.ps1 -Test                     # parsing check, no Vortex
```

It runs one command — `Vortex.exe --game cyberpunk2077 --install "nxm://…/revisions/latest"
--start-minimized` — which works whether Vortex is closed (cold start consumes `--install`) or
already running (the second instance forwards the same arguments). No addon, no `preflight.exe`,
no Nexus API calls from this script. Where Vortex.exe lives: the `VORTEX_EXE` environment variable,
or the default install paths, or the Start-menu shortcut — otherwise it prompts.

Premium = one click in Vortex and the whole collection is queued. Free = the collection is queued,
then one website click per file (the same ToS rule as the stacks above). `revisions/latest`
tracks the collection's newest revision.

## n8n (walk the queue from a workflow)

`n8n/stack-runner.json` is an importable n8n workflow that does the same loop as `stack run`:
plan → open page 1 → wait 10 s → poll until the file appears → open page 2 → … → done.

1. Workflows → **Import from File** → `n8n/stack-runner.json`.
2. Open the **Config** node and set the six paths (`runner`, `preflight`, `game`, `stack`, `downloads`,
   `rules`). `runner` is `n8n/run-preflight.js` from this folder.
3. **Execute workflow**. The schedule trigger (every 30 minutes) is disabled until you enable it.

Two things it deliberately does not do: it never clicks Vortex's install buttons, and it never builds
a Nexus download link — it opens the same file page you would, and Vortex keeps installing what it
downloads.

Why the `run-preflight.js` wrapper: `preflight stack plan` exits **3** when the stack does not fit the
build, and n8n's Execute Command node treats any non-zero exit as a node failure, which would throw
away the JSON that says why. The wrapper always exits 0 and prints
`{"exitCode":N,"stdout":"…","stderr":"…"}`.

Prerequisites: a self-hosted n8n (Execute Command is not available on n8n Cloud), running on the same
machine as Vortex and the game, with `preflight.exe` built. Check the workflow before importing:

```bash
cd n8n && python validate.py stack-runner.json      # structure + runs every Code node against real CLI output
```

## Files

```
stacks/core-2.5.yaml          frameworks for patch 2.5
stacks/core-2.31.yaml         frameworks for a rolled-back 2.31 install
stacks/my-mods.example.yaml   template for your own list
install-stack.ps1 / .sh       the one-double-click runner
install-collection.ps1/.bat   one-double-click Nexus Collection installer (Vortex only, no preflight)
add-mod.py                    paste a Nexus URL, get a queue entry
n8n/stack-runner.json         the same queue as an n8n workflow
n8n/run-preflight.js          prints {exitCode,stdout,stderr} so n8n never sees a non-zero exit
n8n/validate.py               checks the workflow graph and runs its Code nodes
```

`equipmentex` is deliberately absent from both core stacks: its newest stable release targets 2.31,
so a 2.5 stack would only report it as blocked.
