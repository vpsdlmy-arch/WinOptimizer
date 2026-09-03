# WinOptimizer ⚡

> **An ultra-lightweight (~175 KB), declarative, and transaction-safe Windows 11 state engine with a native zero-dependency GUI.**

Unlike traditional debloat scripts that run destructive, irreversible `reg delete` commands, **WinOptimizer** operates like Infrastructure-as-Code (IaC): it captures system states, detects configuration drift, applies declarative changes, and logs exact pre-mutation states for strict reverse-LIFO rollback.

> [!WARNING]
> **Administrator Privileges Required:** WinOptimizer manages Windows 11 system services, Appx packages, and registry settings. Always launch `Start-GUI.bat` or run CLI scripts from an elevated administrator prompt.
>
> **Create a Restore Point First:** It is strongly recommended to create a Windows Restore Point before applying any system modifications:
> ```powershell
> Checkpoint-Computer -Description "Before WinOptimizer" -RestorePointType "MODIFY_SETTINGS"
> ```

> [!NOTE]
> **Project Status: As-Is / Unmaintained**
> This utility was built for personal use and is published strictly on an **"AS IS"** basis for educational and enthusiast reference. There are **no plans for active maintenance, feature updates, or adaptation to future Windows 11 builds**. Issues and pull requests may not be actively monitored. You are welcome to fork and adapt the repository to your own requirements.

---

## 🌟 Key Highlights

- 🪶 **Ultra Lightweight (~175 KB total / ~72 KB code):** No Electron, no Node.js, no Python, no .NET SDK runtimes, zero third-party binaries.
- 🖥️ **Native Modern GUI (`Start-GUI.bat`):** Built-in WPF dark interface running natively in pure PowerShell. Toggle components with checkboxes, search in real time, or use 1-click presets.
- 🛡️ **Safe-by-Default:** All 162 components are initialized to `KEEP`. Nothing is changed unless you explicitly choose to optimize.
- 🎮 **Gaming Preserved:** Smart presets never break DirectPlay, DirectX, Xbox Game Pass, GameInput, or game controllers.
- 🔄 **Transactional & Reversible:** Every applied registry, service, or task state is snapshotted into `applied_changes.jsonl`. Run `scripts/Restore.ps1` to revert changes in reverse LIFO order.
- 🔍 **Drift Detection (`scripts/Analyze.ps1`):** Inspect system configuration drift against `components.json` before touching anything.
- 🔒 **Enterprise-Grade Safety:**
  - Strict CLR type enforcement (Int32, Int64, String, Byte[], String[]).
  - True multi-user safety: dynamic HKCU user-hive resolution via Win32_ComputerSystem and interactive SID verification.
  - Granular Scheduled Task isolation.
  - Full `-WhatIf` / ShouldProcess dry-run support.

---

## 📁 Project Structure

```text
WinOptimizer/
├── Start-GUI.bat             # 1-Click root launcher (elevates UAC & opens GUI)
├── Start-GUI.ps1             # Native WPF GUI application (~20 KB)
├── components.json           # Active declarative component database (162 items)
├── components.example.json   # Pristine reference database template
├── README.md                 # Quick start & usage guide
├── LICENSE                   # MIT License ('AS IS' disclaimer)
├── scripts/                  # Headless execution scripts
│   ├── Analyze.ps1           # Drift detection engine
│   ├── Apply.ps1             # State mutation applicator
│   └── Restore.ps1           # Reverse-LIFO rollback engine
├── WinOptimizer/             # Core PowerShell Module (WinOptimizer.psd1, WinOptimizer.psm1)
└── docs/
    └── PRODUCT.md            # Complete product & architecture specification
```

---

## 🚀 How to Use

### Option 1: Native Graphical Interface (Recommended)
Simply double-click **`Start-GUI.bat`** in the project root.

- **Presets in 1 click:**
  - **Recommended:** Disables non-essential telemetry and consumer bloat while preserving Xbox, Game Pass, DirectPlay, and Store apps.
  - **Gaming Focus:** Eliminates background CPU interrupts while strictly keeping DirectPlay, DirectX, Xbox Game Pass, GameInput, and controllers intact.
  - **Privacy Only:** Focuses strictly on telemetry, feedback schedulers, and diagnostics.
  - **Clear All / Select All:** Reset all toggles to `KEEP` or select all items.
- **Search bar:** Filter all 162 components in real time.
- **Analyze (Dry-Run):** Inspect system state and check drift against `components.json` without modifying your machine.
- **Apply Selected:** Updates `components.json` and executes state mutations with transactional logging.
- **Restore (Rollback):** Reverts applied modifications in reverse-LIFO order.

---

### Option 2: Command Line (Headless / SysAdmin)

#### 1. Pre-Flight & Drift Analysis (Safe, read-only)
```powershell
# Run from an elevated PowerShell prompt:
.\scripts\Analyze.ps1
```

#### 2. Dry Run (-WhatIf)
```powershell
.\scripts\Apply.ps1 -WhatIf
```

#### 3. Apply Target State Declaratively
```powershell
.\scripts\Apply.ps1
```

#### 4. Rollback Changes (Reverse LIFO)
```powershell
.\scripts\Restore.ps1
```

---

## 📄 License & Disclaimer

Released under the **MIT License**. Distributed on an **"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND**. Always perform a system backup before applying system modifications.
