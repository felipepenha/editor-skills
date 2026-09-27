---
name: overleaf
description: >-
  Build and run Overleaf Community Edition (ShareLaTeX) container service using Podman for programmatic
  AI agent access. Use when an agent needs to start Overleaf, create/manage LaTeX projects, compile
  documents, download PDFs, and interact via REST APIs without manual web setup across any processor architecture.
---

# Overleaf Community Edition for AI Agents (Podman)

This skill provides step-by-step instructions and automated utilities to build, run, configure, and **programmatically interact** with an **Overleaf Community Edition** service via **Podman**.

The service is configured for **fully autonomous programmatic access**:
- **Zero Manual Setup**: On startup, an agent user account is automatically provisioned in MongoDB with pre-authenticated session credentials, bypassing the manual `/launchpad` web browser wizard entirely.
- **REST API & CLI**: The included [overleaf-api.sh](./scripts/overleaf-api.sh) allows agents to create projects, upload documents, trigger compilations, and retrieve PDFs programmatically.
- **Architecture & OS Neutral**: Operates identically on `x86_64`/`amd64`, `aarch64`/`arm64`, Linux, macOS, and container environments without processor-specific hardcoding.

---

## 1. Quick Start: Launching the Service

Use [overleaf-ctl.sh](./scripts/overleaf-ctl.sh) to start the stack and automatically provision the agent credentials:

```bash
./scripts/overleaf-ctl.sh up --port 8080
```

When startup completes, the script:
1. Starts Redis, MongoDB (with active replica set), and Overleaf in a unified Podman Pod.
2. Automatically provisions an agent user (`agent@local.overleaf`) with persistent credentials saved in `.agent_credentials.json`.
3. Pre-authenticates and writes the session cookie to `.session_cookie`.
4. Outputs the endpoint URL and ready-to-use programmatic commands.

### Check Service Status:
```bash
./scripts/overleaf-ctl.sh status
```

### Stop Service (Preserves Data Volumes):
```bash
./scripts/overleaf-ctl.sh down
```

---

## 2. Programmatic Interaction (Agent Runbook)

Use [overleaf-api.sh](./scripts/overleaf-api.sh) to automate document workflows:

### A. Authenticate / Verify Session
```bash
./scripts/overleaf-api.sh login
```
*(Uses credentials in `.agent_credentials.json` by default, or accepts `--email` and `--password`)*

### B. Upload a Document / Project
Upload a local `.tex` file, folder, or `.zip` archive, and optionally compile immediately:
```bash
# Upload and compile in a single step
./scripts/overleaf-api.sh upload-project --file examples/sample_paper.tex --name "Sample Paper" --compile --output sample_paper.pdf
```
**Output:**
```
==> Project successfully uploaded from 'examples/sample_paper.tex'
    Project Name: Sample Paper
    Project ID:   6ab8a5c9f3a68cf48c18fd95
    Project URL:  http://localhost:8080/project/6ab8a5c9f3a68cf48c18fd95
==> Triggering compilation...
==> Compilation SUCCESSFUL for project 6ab8a5c9f3a68cf48c18fd95.
==> Downloading PDF to: sample_paper.pdf...
==> PDF saved (sample_paper.pdf).
```

### C. Create a Blank / Template Project
```bash
./scripts/overleaf-api.sh create-project --name "Autonomous Research Paper"
```
**Output (JSON):**
```json
{
  "project_id": "6ab8a419f3a68cf48c18fcd4",
  "owner": {
    "email": "agent@local.overleaf",
    "_id": "6ab8a3ebf6ea388bcfc6f2e7"
  }
}
```

### D. Compile & Download PDF
```bash
./scripts/overleaf-api.sh compile --project-id <PROJECT_ID> --output paper.pdf
```
- Triggers compilation on the Overleaf CLSI engine.
- If compilation succeeds, downloads the generated PDF directly to `paper.pdf` and outputs the **direct unauthenticated PDF view URL**.
- To automatically launch the unauthenticated PDF preview in your browser:
  ```bash
  ./scripts/overleaf-api.sh compile --project-id <PROJECT_ID> --open
  ```

### E. Visualizing Documents & Projects

Two access options are supported:

- **Option A: Direct Unauthenticated PDF Preview (Zero Login)**
  Overleaf's internal proxy serves the compiled binary PDF directly without any authentication:
  ```text
  http://localhost:8080/project/<PROJECT_ID>/user/<USER_ID>/build/<BUILD_ID>/output/output.pdf
  ```
  Pass `--open` to `compile` or `upload-project` to open this URL directly in your browser.

- **Option B: Full Interactive Web Editor (`/project/<id>`)**
  To use the full split-pane IDE editor side-by-side with source code:
  - **Login URL**: `http://localhost:8080/login`
  - **Username**: `user@local.com` (or `agent@local.overleaf`)
  - **Password**: `0123`
  *(Once logged in, the session cookie remains active for 7 days).*

### F. List Projects
```bash
./scripts/overleaf-api.sh list-projects
```

---

## 3. Direct REST API Reference for Agents

If the agent prefers sending direct HTTP requests (e.g. via `curl` or Python `requests`):

### 1. Authenticate & Obtain Session Cookie
```bash
COOKIE_JAR="/tmp/overleaf_cookies.txt"

# Step 1: Fetch CSRF token
CSRF1=$(curl -s -c "$COOKIE_JAR" http://localhost:8080/login | grep -o 'name="ol-csrfToken" content="[^"]*' | cut -d'"' -f4)

# Step 2: Post JSON credentials
curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  -H "Content-Type: application/json" \
  -H "X-Csrf-Token: ${CSRF1}" \
  -d '{"email":"agent@local.overleaf","password":"AutonomousAgentKey2026!"}' \
  http://localhost:8080/login > /dev/null

# Step 3: Extract fresh authenticated CSRF token from /project
CSRF=$(curl -s -b "$COOKIE_JAR" http://localhost:8080/project | grep -o 'name="ol-csrfToken" content="[^"]*' | cut -d'"' -f4)
```

### 2. Create Project
```bash
curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  -H "Content-Type: application/json" \
  -H "X-Csrf-Token: ${CSRF}" \
  -d '{"projectName":"My Paper Title","template":"basic"}' \
  http://localhost:8080/project/new
```

### 3. Compile Project
```bash
COMPILE_RESULT=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  -H "Content-Type: application/json" \
  -H "X-Csrf-Token: ${CSRF}" \
  -d '{"check":"silent","draft":false}' \
  http://localhost:8080/project/<PROJECT_ID>/compile)
```

### 4. Download Compiled Artifacts
Extract the `url` from `outputFiles` where `path == "output.pdf"` and retrieve:
```bash
curl -s -b "$COOKIE_JAR" "http://localhost:8080${PDF_URL}" -o output.pdf
```

---

## 4. Building Custom TeX Live Images

The official container comes with basic LaTeX packages. If your papers require advanced packages (`tikz`, `biber`, `microtype`, fonts, or `minted` with Pygments), build an extended container image:

### Build Extended Container:
```bash
# Recommended packages (~1.5 GB extra):
./scripts/overleaf-ctl.sh build --recommended --tag overleaf-custom:latest

# Or full TeX Live (~5 GB extra):
./scripts/overleaf-ctl.sh build --full --tag overleaf-full:latest
```

### Run Stack with Custom Image:
```bash
./scripts/overleaf-ctl.sh up --port 8080 --image overleaf-custom:latest
```

---

## 5. User & Credential Management via CLI

To create additional users or update passwords without web interface:
```bash
./scripts/overleaf-ctl.sh create-user --email user@example.com --password "SecurePass123!" --admin
```

---

## 6. Helper Utilities & Reference Files

- [overleaf-ctl.sh](./scripts/overleaf-ctl.sh): Stack lifecycle and automated container provisioning.
- [overleaf-api.sh](./scripts/overleaf-api.sh): Programmatic API client for agents (login, create, upload, compile, download).
- [init-replica-set.sh](./scripts/init-replica-set.sh): MongoDB replica set initializer.
- [sample_paper.tex](./examples/sample_paper.tex): Complete sample academic LaTeX paper demonstrating equations, matrices, tables, TikZ, and PGFPlots.
- [sample_presentation.tex](./examples/sample_presentation.tex): 16:9 Beamer slide deck with Madrid theme, TikZ diagrams, and PGFPlots charts.
- [Containerfile](./resources/Containerfile): Custom container build recipe with TeX Live profiles (Beamer, TikZ, PGFPlots included).
- [overleaf.env.example](./resources/overleaf.env.example): Environment configuration reference.
- [architecture.md](./references/architecture.md): Service architecture and storage persistence.
- [troubleshooting.md](./references/troubleshooting.md): Diagnostics for MongoDB, ports, and LaTeX compilation.
