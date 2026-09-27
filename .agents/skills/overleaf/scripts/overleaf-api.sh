#!/usr/bin/env bash
# overleaf-api.sh - Programmatic REST API client for AI Agents interacting with Overleaf
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_URL="http://localhost:8080"
COOKIE_JAR="${SKILL_ROOT}/.session_cookie"
CREDS_FILE="${SKILL_ROOT}/.agent_credentials.json"

usage() {
  cat <<'EOF'
overleaf-api.sh - Programmatic Overleaf API client for Agents

USAGE:
  overleaf-api.sh <command> [options]

COMMANDS:
  login             Authenticate agent and establish persistent session cookie
  list-projects     List all projects accessible to the authenticated agent
  create-project    Create a new LaTeX project (template-based)
  upload-project    Upload a .tex file, directory, or .zip to create a project
  compile           Trigger compilation and optionally download the generated PDF
  download-pdf      Download compiled PDF for a project
  sync-down         Download and extract project zip to a local directory
  status            Check authenticated API connectivity

OPTIONS:
  --url <url>             Overleaf base URL (default: http://localhost:8080 or OVERLEAF_URL)
  --email <email>         Agent login email (default: read from .agent_credentials.json)
  --password <password>   Agent login password (default: read from .agent_credentials.json)
  --project-id <id>       Target project ID (for compile, download-pdf)
  --file <path>           File (.tex/.zip) or directory to upload (for upload-project)
  --name <name>           Project name (for create-project, upload-project)
  --compile               Trigger immediate compilation after upload
  --output <path>         Output path for downloaded PDF (default: output.pdf)
  --open                  Automatically open unauthenticated PDF in browser after compile

EXAMPLES:
  # 1. Log in programmatically
  overleaf-api.sh login

  # 2. Upload a .tex file and immediately compile to PDF
  overleaf-api.sh upload-project --file sample.tex --name "My Paper" --compile --output paper.pdf

  # 3. Create a template project
  overleaf-api.sh create-project --name "Deep Learning Survey"

  # 4. Compile existing project and save PDF
  overleaf-api.sh compile --project-id <PROJECT_ID> --output paper.pdf

  # 5. List all agent projects
  overleaf-api.sh list-projects
EOF
}

get_base_url() {
  echo "${OVERLEAF_URL:-$DEFAULT_URL}"
}

load_credentials() {
  local email="${OVERLEAF_AGENT_EMAIL:-}"
  local password="${OVERLEAF_AGENT_PASSWORD:-}"

  if [[ -z "$email" || -z "$password" ]] && [[ -f "$CREDS_FILE" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      email=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d.get('email', ''))" 2>/dev/null || true)
      password=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d.get('password', ''))" 2>/dev/null || true)
    else
      email=$(grep -o '"email": "[^"]*' "$CREDS_FILE" | cut -d'"' -f4 || true)
      password=$(grep -o '"password": "[^"]*' "$CREDS_FILE" | cut -d'"' -f4 || true)
    fi
  fi

  # Fallback defaults if not in file
  echo "${email:-agent@local.overleaf}" "${password:-0123}"
}

get_csrf_token() {
  local url="$1"
  local target_page="${2:-/login}"
  local csrf
  csrf=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" "${url}${target_page}" | grep -o 'name="ol-csrfToken" content="[^"]*' | cut -d'"' -f4 || true)
  if [[ -z "$csrf" ]]; then
    csrf=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" "${url}${target_page}" | grep -o 'name="_csrf" value="[^"]*' | cut -d'"' -f3 || true)
  fi
  echo "$csrf"
}

cmd_login() {
  local base_url
  base_url=$(get_base_url)
  read -r default_email default_pass <<< "$(load_credentials)"

  local email="$default_email"
  local password="$default_pass"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --email) email="$2"; shift 2 ;;
      --password) password="$2"; shift 2 ;;
      --url) base_url="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Step 1: Initial CSRF from /login
  local csrf
  csrf=$(get_csrf_token "$base_url" "/login")
  if [[ -z "$csrf" ]]; then
    echo "Error: Failed to extract CSRF token from ${base_url}/login. Is Overleaf running?" >&2
    exit 1
  fi

  # Step 2: Post login JSON
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -H "X-Csrf-Token: ${csrf}" \
    -d "{\"email\":\"${email}\",\"password\":\"${password}\"}" \
    "${base_url}/login")

  if [[ "$http_code" =~ ^(200|302)$ ]]; then
    # Verify session against /project
    local verify_code
    verify_code=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" "${base_url}/project")
    if [[ "$verify_code" == "200" ]]; then
      echo "==> Successfully authenticated as '${email}'."
      echo "==> Session stored in: ${COOKIE_JAR}"
      return 0
    fi
  fi

  echo "Error: Authentication failed with HTTP status ${http_code}. Check credentials for '${email}'." >&2
  exit 1
}

ensure_authenticated() {
  local base_url
  base_url=$(get_base_url)
  if [[ -f "$COOKIE_JAR" ]]; then
    local test_code
    test_code=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" "${base_url}/project")
    if [[ "$test_code" == "200" ]]; then
      return 0
    fi
  fi
  cmd_login "$@" >/dev/null
}

cmd_create_project() {
  local base_url
  base_url=$(get_base_url)
  local name="New Project"
  local template="basic"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --template) template="$2"; shift 2 ;;
      --url) base_url="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  ensure_authenticated

  # Fresh CSRF from authenticated dashboard
  local csrf
  csrf=$(get_csrf_token "$base_url" "/project")

  local resp
  resp=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -H "X-Csrf-Token: ${csrf}" \
    -d "{\"projectName\":\"${name}\",\"template\":\"${template}\"}" \
    "${base_url}/project/new")

  echo "$resp"
}

cmd_upload_project() {
  local base_url
  base_url=$(get_base_url)
  local file_path=""
  local name=""
  local compile_after=false
  local output_pdf=""
  local open_browser=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file|--path|-f) file_path="$2"; shift 2 ;;
      --name|-n) name="$2"; shift 2 ;;
      --compile|-c) compile_after=true; shift ;;
      --output|-o) output_pdf="$2"; compile_after=true; shift 2 ;;
      --open) compile_after=true; open_browser=true; shift ;;
      --url) base_url="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$file_path" ]]; then
    echo "Error: --file <path-to-.tex-or-.zip-or-dir> is required." >&2
    exit 1
  fi

  if [[ ! -e "$file_path" ]]; then
    echo "Error: Target file or directory not found: $file_path" >&2
    exit 1
  fi

  ensure_authenticated

  local tmp_dir=""
  local zip_file=""

  if [[ -f "$file_path" && "$file_path" =~ \.zip$ ]]; then
    zip_file="$file_path"
    if [[ -z "$name" ]]; then
      name="$(basename "$file_path" .zip)"
    fi
  else
    tmp_dir=$(mktemp -d)
    zip_file="${tmp_dir}/project.zip"

    if [[ -d "$file_path" ]]; then
      if [[ -z "$name" ]]; then
        name="$(basename "$file_path")"
      fi
      (cd "$file_path" && zip -q -r "$zip_file" .)
    else
      # Single file (e.g. .tex)
      local base_fname
      base_fname="$(basename "$file_path")"
      if [[ -z "$name" ]]; then
        name="${base_fname%.*}"
      fi
      cp "$file_path" "${tmp_dir}/${base_fname}"
      # Overleaf CE looks for main.tex by default if present
      if [[ "$base_fname" != "main.tex" ]]; then
        cp "$file_path" "${tmp_dir}/main.tex"
      fi
      (cd "$tmp_dir" && zip -q -r "$zip_file" .)
    fi
  fi

  local csrf
  csrf=$(get_csrf_token "$base_url" "/project")

  local upload_resp
  upload_resp=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "X-Csrf-Token: ${csrf}" \
    -F "qqfile=@${zip_file}" \
    -F "name=${name}.zip" \
    "${base_url}/project/new/upload")

  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
  fi

  local project_id=""
  if command -v python3 >/dev/null 2>&1; then
    project_id=$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('project_id', ''))" "$upload_resp" 2>/dev/null || true)
  fi
  if [[ -z "$project_id" ]]; then
    project_id=$(echo "$upload_resp" | grep -o '"project_id":"[^"]*' | cut -d'"' -f4 || true)
  fi

  if [[ -n "$project_id" ]]; then
    echo "==> Project successfully uploaded from '${file_path}'"
    echo "    Project Name: ${name}"
    echo "    Project ID:   ${project_id}"
    echo "    Project URL:  ${base_url}/project/${project_id}"

    if [[ "$compile_after" == true ]]; then
      echo "==> Triggering compilation..."
      local compile_args=(--project-id "$project_id" --url "$base_url")
      if [[ -n "$output_pdf" ]]; then
        compile_args+=(--output "$output_pdf")
      fi
      if [[ "$open_browser" == true ]]; then
        compile_args+=(--open)
      fi
      cmd_compile "${compile_args[@]}"
    else
      echo "==> To compile: overleaf-api.sh compile --project-id ${project_id} --output ${name}.pdf"
    fi
  else
    echo "Error: Upload failed. Server response:" >&2
    echo "$upload_resp" >&2
    exit 1
  fi
}

cmd_compile() {
  local base_url
  base_url=$(get_base_url)
  local project_id=""
  local output_pdf=""
  local open_browser=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-id) project_id="$2"; shift 2 ;;
      --output|--output-pdf) output_pdf="$2"; shift 2 ;;
      --open) open_browser=true; shift ;;
      --url) base_url="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$project_id" ]]; then
    echo "Error: --project-id <id> is required." >&2
    exit 1
  fi

  ensure_authenticated

  local csrf
  csrf=$(get_csrf_token "$base_url" "/project")

  local compile_json
  compile_json=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -H "X-Csrf-Token: ${csrf}" \
    -d '{"check":"silent","draft":false}' \
    "${base_url}/project/${project_id}/compile")

  local status
  status=$(echo "$compile_json" | grep -o '"status":"[^"]*' | cut -d'"' -f4 || echo "unknown")

  if [[ "$status" == "success" ]]; then
    echo "==> Compilation SUCCESSFUL for project ${project_id}."
    
    local pdf_url=""
    if command -v python3 >/dev/null 2>&1; then
      pdf_url=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    for f in data.get('outputFiles', []):
        if f.get('path') == 'output.pdf':
            print(f.get('url', ''))
            break
except Exception:
    pass
" "$compile_json" 2>/dev/null || true)
    fi

    if [[ -z "$pdf_url" ]]; then
      pdf_url=$(echo "$compile_json" | grep -o '"url":"/project/[^"]*output\.pdf"' | head -n 1 | cut -d'"' -f4 || true)
    fi

    if [[ -n "$pdf_url" ]]; then
      echo "==> Direct PDF View URL (No Login Needed):"
      echo "    ${base_url}${pdf_url}"

      if [[ "$open_browser" == true ]]; then
        echo "==> Opening PDF in default browser..."
        open "${base_url}${pdf_url}" 2>/dev/null || xdg-open "${base_url}${pdf_url}" 2>/dev/null || true
      fi

      if [[ -n "$output_pdf" ]]; then
        echo "==> Downloading PDF to: ${output_pdf}..."
        curl -s -b "$COOKIE_JAR" "${base_url}${pdf_url}" -o "${output_pdf}"
        echo "==> PDF saved (${output_pdf})."
      fi
    else
      echo "Warning: Could not extract specific PDF url from compile response." >&2
    fi
  else
    echo "==> Compilation FAILED or had errors. Server response:" >&2
    echo "$compile_json" >&2
    exit 2
  fi
}

cmd_download_pdf() {
  local base_url
  base_url=$(get_base_url)
  local project_id=""
  local output_pdf="output.pdf"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-id) project_id="$2"; shift 2 ;;
      --output) output_pdf="$2"; shift 2 ;;
      --url) base_url="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$project_id" ]]; then
    echo "Error: --project-id <id> is required." >&2
    exit 1
  fi

  cmd_compile --project-id "$project_id" --output "$output_pdf"
}

cmd_sync_down() {
  local base_url
  base_url=$(get_base_url)
  local project_id=""
  local target_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-id) project_id="$2"; shift 2 ;;
      --dir) target_dir="$2"; shift 2 ;;
      --url) base_url="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$project_id" ]]; then
    echo "Error: --project-id <id> is required." >&2
    exit 1
  fi

  if [[ -z "$target_dir" ]]; then
    echo "Error: --dir <directory> is required." >&2
    exit 1
  fi

  ensure_authenticated

  echo "==> Syncing down project ${project_id} to ${target_dir}..."
  
  local zip_file="${target_dir}/.sync_download.zip"
  mkdir -p "$target_dir"
  
  local http_code
  http_code=$(curl -s -w "%{http_code}" -b "$COOKIE_JAR" "${base_url}/project/${project_id}/download/zip" -o "$zip_file")
  
  if [[ "$http_code" == "200" ]]; then
    unzip -q -o "$zip_file" -d "$target_dir"
    rm -f "$zip_file"
    echo "==> Successfully synced down project to ${target_dir}."
  else
    echo "Error: Failed to download project. HTTP status ${http_code}" >&2
    rm -f "$zip_file"
    exit 1
  fi
}

cmd_list_projects() {
  local base_url
  base_url=$(get_base_url)
  ensure_authenticated

  # In Overleaf CE, /project returns the dashboard HTML containing project data in window.userProjects
  local html
  html=$(curl -s -b "$COOKIE_JAR" "${base_url}/project")
  
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import sys, re, json, html
raw = sys.stdin.read()
m = re.search(r'name=\"ol-prefetchedProjectsBlob\"\s+data-type=\"json\"\s+content=\"(.*?)\"', raw)
if m:
    try:
        blob = json.loads(html.unescape(m.group(1)))
        for p in blob.get('projects', []):
            print(f\"{p.get('id', '')}\t{p.get('name', '')}\t{p.get('lastUpdated', '')}\")
    except Exception as e:
        print(f'Error parsing projects JSON: {e}', file=sys.stderr)
else:
    print('No projects found.')
" <<< "$html"
  else
    grep -o '"id":"[a-f0-9]\{24\}","name":"[^"]*' <<< "$html" | sed 's/"id":"//; s/","name":"/\t/' || echo "No projects found."
  fi
}

cmd_status() {
  local base_url
  base_url=$(get_base_url)
  echo "Checking API connectivity at ${base_url}..."
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "${base_url}/login" || echo "000")
  if [[ "$http_code" =~ ^(200|302)$ ]]; then
    echo " [OK] Overleaf endpoint is responding (HTTP ${http_code})."
  else
    echo " [ERROR] Endpoint ${base_url} unreachable (HTTP ${http_code})."
    exit 1
  fi

  if [[ -f "$COOKIE_JAR" ]]; then
    local auth_code
    auth_code=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" "${base_url}/project")
    if [[ "$auth_code" == "200" ]]; then
      echo " [OK] Authenticated session is ACTIVE."
    else
      echo " [WARN] Session cookie exists but returned HTTP ${auth_code} (Login required)."
    fi
  else
    echo " [INFO] No session cookie found. Run 'overleaf-api.sh login' to authenticate."
  fi
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  local action="$1"
  shift

  case "$action" in
    login) cmd_login "$@" ;;
    create-project|new-project) cmd_create_project "$@" ;;
    upload-project|upload) cmd_upload_project "$@" ;;
    compile) cmd_compile "$@" ;;
    download-pdf) cmd_download_pdf "$@" ;;
    sync-down) cmd_sync_down "$@" ;;
    list-projects|projects) cmd_list_projects "$@" ;;
    status) cmd_status "$@" ;;
    help|--help|-h) usage ;;
    *)
      echo "Error: Unknown API command '$action'" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
