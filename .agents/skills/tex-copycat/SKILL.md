---
name: tex-copycat
description: >-
  Reproduce, digitize, and clone scientific papers and LaTeX documents into clean, compilation-verified TeX projects.
  Enforces native TikZ for schematics and PGFPlots for graphs, and leverages the local Overleaf container skill
  for iterative compilation, package resolution, and visual verification.
---

# `tex-copycat`: High-Fidelity Scientific Paper Reproduction

This skill establishes the standard workflow for reproducing, cloning, and digitizing academic papers, arXiv preprints, and scientific documents into fully functional LaTeX codebases.

Every reproduced document must be **compilation-verified**, **typographically faithful**, and built around **native vector illustrations** rather than raster screenshots.

---

## 1. Core Visual Directives (The Golden Rules)

When copying or reproducing scientific papers:

### Rule 1: Schematics $\to$ Pure Native TikZ
- **Mandatory**: All architectural diagrams, system overviews, workflow pipelines, state transitions, neural net architectures, block diagrams, and conceptual schematics **MUST be reproduced in native TikZ code**.
- **No Screenshots**: Never substitute screenshots or raster PNGs for diagrams. Native TikZ guarantees infinite resolution, font harmony with the paper typography, dark/light mode compatibility, and full editability.
- **Icons & Glyphs**: Use vector icon packages (such as `fontawesome5`, `pifont`, or geometric TikZ shapes) instead of raster icon snippets.
- **Structure**: Create a self-contained figure snippet (e.g. `figures/<name>_fig.tex`) containing only the `\begin{tikzpicture} ... \end{tikzpicture}` environment (with local color/library definitions), included into the paper via:
  ```latex
  \begin{figure}[t]
  \centering
  \resizebox{\linewidth}{!}{%
    \input{figures/<name>_fig.tex}%
  }
  \caption{...}
  \label{fig:...}
  \end{figure}
  ```

### Rule 2: Quantitative Graphs $\to$ Native PGFPlots
- **Mandatory**: All quantitative data charts (bar charts, line plots, ablation curves, scatter plots, pareto frontiers) **MUST be reproduced using PGFPlots** (`pgfplots`).
- **Data Representation**: Encode data points directly in `\addplot coordinates { ... }` or tabular `.dat`/`.csv` files.
- **Styling**: Match axis ticks, legends, grid lines, and color schemes with the original publication.

### Rule 3: Exceptions (When Raster Images Are Permitted)
Raster images (`\includegraphics{...}`) are strictly reserved for:
1. Natural photographs, microscopy, satellite imagery, and medical imaging (MRI/CT).
2. Complex UI screenshots of external third-party software applications where code-level reconstruction is impossible.
3. Official corporate or university crests/logos if vector PDFs/SVGs cannot be obtained.

---

## 2. Integration with Local Overleaf Service

This skill directly relies on the [overleaf](../overleaf/SKILL.md) skill to test compilation iteratively and provide the user with a live web editor preview.

### A. Ensure Overleaf Is Running
Check service status or start the stack:
```bash
# Check if overleaf container is running
./.agents/skills/overleaf/scripts/overleaf-api.sh status || ./.agents/skills/overleaf/scripts/overleaf-ctl.sh up --port 8080
```

### B. Dynamic TeX Live Package Resolution
The base container image has a minimal TeX Live profile. When compiling complex papers, packages or fonts may be missing. **Do not run massive collection installs** (`collection-latexextra` has 2,000+ packages and times out). Instead, install targeted packages on demand directly inside the container:

```bash
# General packages
podman exec overleaf-server tlmgr install <package-name>

# Common academic packages often needed:
podman exec overleaf-server tlmgr install \
  environ todonotes xargs wrapfig threeparttable enumitem makecell \
  pgfplots floatrow caption newfloat xurl fancyvrb tcolorbox \
  fontawesome5 cjk mathtools cleveref tikzfill algorithms titlesec

# Font metric packages:
# - missing 'phvb8t'  -> tlmgr install helvetic
# - missing 'ptmr8t'  -> tlmgr install times
# - missing 'nicefrac' -> tlmgr install units
```

### C. Visual Inspection Loop (PDF to PNG)
To verify layout, spacing, and ensure zero text overlaps without requiring manual user intervention:
```bash
# Render specific page of the compiled paper to PNG inside container
podman exec -w /tmp/<project> overleaf-server pdftoppm -png -r 200 -f <page> -l <page> main.pdf /tmp/page_render

# Copy to workspace and inspect
podman cp overleaf-server:/tmp/page_render-<page>.png /tmp/page_inspected.png
```
Use the `view_file` tool on the resulting PNG to verify alignment, arrow endpoints, font sizes, and container clearances.

### D. Publish to Overleaf Web Editor
Once compiled and visually verified, push the complete project into Overleaf:
```bash
./.agents/skills/overleaf/scripts/overleaf-api.sh upload-project \
  --file local/<project-name> \
  --name "<Paper Title>" \
  --compile
```
Then navigate the browser to the returned project URL (`http://localhost:8080/project/<PROJECT_ID>`) using `browser_subagent`.

---

## 3. End-to-End Paper Reproduction Workflow

```
[ArXiv ID / PDF Source]
          │
          ▼
1. Fetch Source or Ingest Text
   - Download .tar.gz from https://arxiv.org/src/<id>
   - Unpack into local/<project-name>/
          │
          ▼
2. Organize Document Structure
   - Modular entry point (main.tex)
   - Optional consolidated file via latexpand (harness_zero_consolidated.tex)
          │
          ▼
3. Vectorize Diagrams (TikZ & PGFPlots)
   - Extract raster figures
   - Code pure TikZ figures in figures/<name>_fig.tex
   - Test standalone compilation in container
   - Visually verify via pdftoppm + view_file
          │
          ▼
4. Iterative Compilation & Dependency Fixes
   - Run latexmk in overleaf-server
   - Catch missing .sty / font metrics in .log
   - Install missing packages via tlmgr
          │
          ▼
5. Sync & Upload to Overleaf
   - Upload via overleaf-api.sh
   - Launch browser preview at exact page
```

---

## 4. TikZ Reproduction Best Practices

### Modular Snippet Architecture
Keep TikZ code decoupled from document preambles by separating the drawing from its wrapper:

1. **`figures/<name>_fig.tex`**: Contains only local color definitions and `\begin{tikzpicture} ... \end{tikzpicture}`.
2. **`figures/<name>_standalone.tex`**: Uses `\documentclass[tikz,border=6pt]{standalone}` and `\input{figures/<name>_fig.tex}` for isolated testing.
3. **`section/<section>.tex`**: Inlines the figure with `\resizebox{\linewidth}{!}{\input{figures/<name>_fig.tex}}`.

### Designing Multi-Panel Complex Diagrams
1. **Define a Coordinate Grid**: Establish bounding coordinates for each panel before placing nodes (e.g. Panel 1: $Y \in [6.5, 11.0]$, Panel 2: $Y \in [2.5, 6.2]$, Panel 3: $X \in [16.0, 20.2]$).
2. **Consistent Color Palette**: Extract exact hexadecimal colors from the original paper using image inspection:
   - Panel headers: Dark muted tones (`#A63D24`, `#3A5874`, `#4A7452`).
   - Cards/Containers: Very soft pastel backgrounds (`#FFFDF8`, `#F3F7FA`, `#EEF6F0`).
   - Action badges: Saturated accents (`#2E7D32`, `#1976D2`, `#E54B4B`).
3. **Use Vector Avatars & Icons**:
   - Construct robot faces, servers, and devices with elementary geometric shapes (`rounded corners`, `circle`, `rectangle`).
   - Integrate `\faDatabase`, `\faSync`, `\faTools`, `\faBrain`, `\faFire`, `\faLock` from `fontawesome5`.
4. **Preventing Overlaps**:
   - Always place node text labels with explicit `align=center` or `text width=...`.
   - Leave at least $0.4\,\text{cm}$ vertical clearance between arrow shafts and neighboring label baselines.
   - Use relative offsets (`to[out=..., in=...]`) rather than hard-coded straight lines for inter-panel routing.

---

## 5. Quick Reference & Diagnostic Commands

| Issue in LaTeX Log | Cause | Solution |
| :--- | :--- | :--- |
| `File 'environ.sty' not found` | Missing LaTeX package | `podman exec overleaf-server tlmgr install environ` |
| `Font T1/phv/b/n/19=phvb8t not loadable` | Missing Helvetica font metric | `podman exec overleaf-server tlmgr install helvetic` |
| `Font T1/ptm/m/n/10=ptmr8t not loadable` | Missing Times font metric | `podman exec overleaf-server tlmgr install times` |
| `File 'nicefrac.sty' not found` | Missing `units` CTAN package | `podman exec overleaf-server tlmgr install units` |
| `Package xcolor Error: Undefined color` | Missing named color | Add `\definecolor{<name>}{RGB}{...}` to figure preamble |
| `Undefined control sequence \faSyncAlt` | FontAwesome version mismatch | Use `\faSync` instead of `\faSyncAlt` |
