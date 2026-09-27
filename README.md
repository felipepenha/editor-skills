# editor-skills

Collection of Skills for Text Editor Agents.

## Available Skills

| Skill | Description | Location |
| :--- | :--- | :--- |
| **`overleaf`** | Build, run, and programmatically interact with an Overleaf Community Edition service via Podman for autonomous AI agents. | [.agents/skills/overleaf](.agents/skills/overleaf/SKILL.md) |

---

### Overleaf Skill Quick Start (Programmatic Agent Workflow)

Deploy and interact with Overleaf completely programmatically without manual browser steps:

```bash
# 1. Start Overleaf service (automatically provisions agent credentials)
./.agents/skills/overleaf/scripts/overleaf-ctl.sh up --port 8080

# 2. Authenticate session
./.agents/skills/overleaf/scripts/overleaf-api.sh login

# 3. Create a new LaTeX project
./.agents/skills/overleaf/scripts/overleaf-api.sh create-project --name "My Autonomous Paper"

# 4. Trigger compile and download the generated PDF
./.agents/skills/overleaf/scripts/overleaf-api.sh compile --project-id <PROJECT_ID> --output paper.pdf

# 5. List projects
./.agents/skills/overleaf/scripts/overleaf-api.sh list-projects

# 6. Stop the stack (preserves volumes)
./.agents/skills/overleaf/scripts/overleaf-ctl.sh down
```

For full documentation, REST API references, and build options, see [.agents/skills/overleaf/SKILL.md](.agents/skills/overleaf/SKILL.md).
