# editor-skills

Collection of Skills for Text Editor Agents.

## Available Skills

| Skill | Description | Prompt Example | Location | Requirements |
| :--- | :--- | :--- | :--- | :--- |
| **`overleaf`** | Build, run, and programmatically interact with an Overleaf Community Edition service via Podman or Docker for autonomous AI agents. | `"Run example.tex"` | [.agents/skills/overleaf](.agents/skills/overleaf/SKILL.md) | `podman` (preferred) or `docker` |
| **`tex-copycat`** | Reproduce, digitize, and clone scientific papers into clean, compilation-verified LaTeX codebases. Enforces native TikZ for schematics and PGFPlots for graphs, and leverages Overleaf for iterative compilation and visual verification. | `"Copy the paper https://arxiv.org/pdf/2609.14849v1 into the current directory."` | [.agents/skills/tex-copycat](.agents/skills/tex-copycat/SKILL.md) | `overleaf` skill, `podman` (preferred) or `docker` |

