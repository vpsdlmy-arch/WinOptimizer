# Product Architecture Specification (PRODUCT.md)

> **Document Status:** RELEASE CANDIDATE (v1.1.0)  
> **Target Scope:** Windows 11 State Management Engine & Control Center  
> **Runtime Footprint:** **~175 KB** Total (~72 KB pure PowerShell code + ~102 KB declarative database)

---

## 1. Project Purpose

**WinOptimizer** is a **declarative, ultra-lightweight Windows State Management Engine and Control Center** designed to audit, configure, and maintain a Windows 11 installation according to a strictly defined, predictable target state profile.

### 1.1. Core Goals
* **Declarative Specification:** Express target states of system components (Services, UWP/Appx applications, Windows Features, Capabilities, Scheduled Tasks, Registry hives, Network protocols) in a structured database (`components.json`).
* **Zero-Dependency Graphical Control Center (`Start-GUI.bat` / `Start-GUI.ps1`):** Provide a native, hardware-accelerated WPF user interface with interactive component toggles, intelligent presets, and integrated execution logs without requiring Node.js, Electron, Python, or external runtime installers.
* **Safe Configuration Drift Audit (`scripts/Analyze.ps1`):** Analyze and report divergence between active OS configuration and target specification without mutating system state.
* **Controlled, Idempotent Application (`scripts/Apply.ps1`):** Execute state mutations predictably with fine-grained error isolation and structured write-ahead audit logging.
* **Transactional Rollback (`scripts/Restore.ps1`):** Reliably revert applied mutations using a reverse-LIFO journal of pre-mutation state snapshots (`applied_changes.jsonl`).
* **Ultra-Minimal Footprint:** The entire executable engine (PowerShell module, execution scripts, and WPF interface) weighs **under 75 KB**, and the complete repository footprint (including the comprehensive 162-component database) is **~175 KB**.

### 1.2. Explicit Non-Goals
* **No Unverified Snake-Oil Heuristics:** Does not include registry brute-forcing, timer tampering, or destructive 'RAM cleaning' utilities.
* **No OS Binary Patching:** Never modifies system DLLs, bypasses digital signatures, or disables foundational kernel security features (Virtualization-Based Security, Core Isolation, Windows Defender Platform).
* **No Network Appx Re-downloading:** Does not download `.msixbundle` or `.appx` installers from external internet repositories during rollback.
* **No Third-Party Software Management:** Management of third-party installers (Steam, browsers, GPU drivers, peripheral software) is out of scope.

---

## 2. Core Architectural Principles

1. **Single Source of Truth:** `components.json` is the sole authoritative definition of target states across both the GUI and CLI scripts.
2. **Safe-by-Default Baseline:** Out of the box, all 162 components are initialized to `KEEP`. No mutations occur until the user explicitly selects a preset or toggles individual components.
3. **Intuitive Two-State Human Model:**
   * In the UI, every component is represented by a simple binary choice:
     * **`[ ] KEEP` (Leave Intact):** The component is protected and ignored during state mutation.
     * **`[X] REMOVE / DISABLE` (Optimize):** The component is targeted for removal (Appx, Features, Capabilities) or disabling (Services, Scheduled Tasks, Registry).
   * **`SKIP`** is strictly an internal runtime status (e.g. *«Skipped: component already absent/disabled»* or *«Skipped: component marked KEEP»*), eliminating user confusion.
4. **Zero Runtime Dependencies:** Built entirely with native Windows technologies (Windows PowerShell 5.1+, .NET PresentationFramework / WPF, CIM/WMI).
5. **Strict Idempotency:** Any script may be executed repeatedly without side effects. If a component is already compliant, no system mutation or audit log entry occurs.
6. **Deterministic Phase Order:** State transitions follow a fixed dependency sequence (`Appx -> Service -> Feature -> Capability -> ScheduledTask -> Registry -> Script`) to eliminate race conditions.
7. **Transparency & Auditability:** Every mutating operation records its prior state (`before`) and new state (`after`) in an append-only JSON Lines journal (`applied_changes.jsonl`).

---

## 3. High-Level Architecture

```text
                    +-------------------------+
                    |     components.json     |
                    | (Primary Source of Truth|
                    | Default: 100% KEEP)     |
                    +------------+------------+
                                 |
                                 v
+-----------------------------------------------------------------+
|                      WinOptimizer.psm1                          |
|  (HKCU Hive Mapping, Pre-Flight Engine, Strict State Comparator)|
+--------------+-----------------+-----------------+--------------+
               |                 |                 |
               v                 v                 v
     +-----------------+ +---------------+ +---------------+
     | scripts/        | | scripts/      | | scripts/      |
     | Analyze.ps1     | | Apply.ps1     | | Restore.ps1   |
     |  (Audit / Read) | |(Mutate/Write) | |(Rollback/LIFO)|
     +---------+-------+ +-------+-------+ +-------+-------+
               |                 |                 |
               v                 v                 v
     analyze_report.txt  applied_changes.jsonl  (OS State Restored)
               ^
               | (Bidirectional State Sync & Live Execution Logs)
               v
+-----------------------------------------------------------------+
|                   Start-GUI.bat / Start-GUI.ps1                 |
|              (Native Modern WPF Graphical Interface)            |
+-----------------------------------------------------------------+
```

---

## 4. Presets Specification

The Graphical Control Center includes smart, purpose-built presets engineered with exact hardware and software dependencies in mind:

| Preset | Target Scope | Preserved Core Components (`KEEP`) | Optimized Components (`REMOVE` / `DISABLE`) |
| :--- | :--- | :--- | :--- |
| **Recommended** | Balanced general-purpose daily workstation optimization | Store, Xbox, DirectPlay, DirectX, Camera, Print Spooler, Bluetooth, Notepad, Calculator, Paint, Photos, Terminal, Windows Defender, C++ / .NET runtimes | Telemetry, DiagTrack, CEIP, Feedback Hub, Customer Experience, Bing News, Weather, Solitaire, Tips, Advertising ID, Suggestions |
| **Gaming Focus** | Maximizing FPS and reducing background DPC latency / CPU interrupts | **Strictly Preserves Gaming Ecosystem:** Microsoft Store, Xbox Game Pass, Gaming Services, Xbox Game Bar, Xbox TCUI, GameInput, DirectPlay (Legacy), DirectX Runtime, GPU runtimes, Controller Bluetooth | Disables background non-gaming bloatware, heavy background diagnostics, indexing, Cortana, and background cloud synchronization |
| **Privacy Only** | Strict data telemetry and diagnostics lockdown | Leaves all application and gaming software untouched | Connected User Experiences (DiagTrack), dmwappushservice, Diagnostic Data level, Advertising ID, Activity History, Tailored Experiences |
| **Select All** | Complete deep debloat | None | Targets all 162 components for removal / disablement |
| **Clear All** | Reset to safe baseline | All 162 components reset to `KEEP` | None |

---

## 5. Subsystem Automation Matrix

| Subsystem | Automation Handler | Mutating Operation | Rollback Capability | State Comparison |
| :--- | :--- | :--- | :--- | :--- |
| **Appx** | `Set-AppxState` | `Remove-AppxPackage` + `Remove-AppxProvisionedPackage` | Manual (via Store) | Presence check |
| **Service** | `Set-ServiceState` | `Set-Service -StartupType` | Full (Automatic LIFO) | StartupType equality |
| **Feature** | `Set-OptionalFeatureState` | `Disable-WindowsOptionalFeature` | Full (Automatic LIFO) | State (`Enabled` / `Disabled`) |
| **Capability** | `Set-CapabilityState` | `Remove-WindowsCapability` | Full (Automatic LIFO) | State (`Installed` / `NotPresent`) |
| **Task** | `Set-ScheduledTaskState`| `Disable-ScheduledTask` | Full (Automatic LIFO) | State equality |
| **Registry** | `Set-RegistryState` | `Set-ItemProperty` / `Remove-ItemProperty` | Full (Automatic LIFO) | Strict 5-type equality check |
| **Script** | Scriptblock Runner | `Invoke-Command` | Not logged (Imperative) | N/A |

---

## 6. Directory Organization & Footprint

```text
WinOptimizer/
├── Start-GUI.bat             # 1-Click root launcher (elevates UAC & opens GUI) [0.4 KB]
├── Start-GUI.ps1             # Native WPF GUI application [20.5 KB]
├── components.json           # Active declarative component database (162 items) [102 KB]
├── components.example.json   # Pristine reference database template [102 KB]
├── README.md                 # Documentation & quick start guide
├── LICENSE                   # MIT License ('AS IS' disclaimer)
├── scripts/                  # Headless execution scripts
│   ├── Analyze.ps1           # Drift detection engine [8.0 KB]
│   ├── Apply.ps1             # State mutation applicator [8.4 KB]
│   └── Restore.ps1           # Reverse-LIFO rollback engine [8.2 KB]
├── WinOptimizer/             # Core PowerShell Module (~27 KB total)
│   ├── WinOptimizer.psd1     # Module manifest [4.2 KB]
│   ├── WinOptimizer.psm1     # Core engine implementation [17.0 KB]
│   └── setters.ps1           # Subsystem automation setters [6.2 KB]
└── docs/
    └── PRODUCT.md            # Product architecture & engineering specification
```

* **Total Executable Code (GUI + Scripts + Engine):** **~72 KB**
* **Total Executable Code + Declarative Database:** **~175 KB**
* **External Runtime Binaries Required:** **0 KB** (Zero Node.js, Zero Electron, Zero Python).
