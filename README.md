# editor-skills

Collection of Skills for Text Editor Agents.

## Available Skills

| Skill | Description | Prompt Example | Location |
| :--- | :--- | :--- | :--- |
| **`overleaf`** | Run and interact with a local Overleaf CE container stack. | `"Run example.tex"` | [.agents/skills/overleaf](.agents/skills/overleaf/SKILL.md) |
| **`tex-copycat`** | Clone scientific documents into clean LaTeX with native TikZ figures and Overleaf verification. | `"Copy the paper https://arxiv.org/pdf/2609.14849v1 into the current directory."` | [.agents/skills/tex-copycat](.agents/skills/tex-copycat/SKILL.md) |

## Requirements

| Skill | Requirements |
| :--- | :--- |
| **`overleaf`** | `podman` (preferred) or `docker` |
| **`tex-copycat`** | `overleaf` skill, `podman` (preferred) or `docker` |

## Usage Notes

The `local/` subdirectory is configured to be ignored by git. Use this directory as a sandbox to place your `.tex` files, or ask the agent to create its own `.tex` files there.
