#!/bin/bash

# =============================================================================
#  Test Case Screen Recorder  —  macOS · Linux · Windows (Git Bash / WSL)
#  Press R to Record | Press S to Stop & Save | Press Q to Quit
# =============================================================================

# ── Dependency cache flag (skip check once both tools are confirmed present) ──
DEPS_FLAG="$HOME/.screen_recorder_deps_ok"

# ── Default Configuration ──
BASE_DIR="$HOME/testing_recording"
RESOLUTION="1920x1080"
FRAME_RATE=30
SCREEN_INDEX=""          # auto-set per OS if left blank

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── State ──
RECORDING_PID=""
IS_RECORDING=false
CURRENT_FILE=""
TEMP_FILE=""
RECORDING_COUNT=0
RECORDING_START_EPOCH=0
STATUS_MSG=""
STATUS_COLOR="$NC"
CHOSEN_DIR=""

# ─────────────────────────────────────────────────────────────────────────────
#  OS Detection
# ─────────────────────────────────────────────────────────────────────────────

detect_os() {
    case "$(uname -s)" in
        Darwin)
            echo "macos" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "windows" ;;
        *)
            echo "unknown" ;;
    esac
}

OS_TYPE=$(detect_os)

# ─────────────────────────────────────────────────────────────────────────────
#  Dependency Installer — shared helpers
# ─────────────────────────────────────────────────────────────────────────────

_spinner() {
    local pid=$1 msg=$2
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}%s${NC}  %s  " "${spin[$i]}" "$msg"
        i=$(( (i + 1) % ${#spin[@]} ))
        sleep 0.1
    done
    printf "\r%-60s\r" " "
}

_print_step() { echo -e "  ${BOLD}${CYAN}▶${NC}  $*"; }
_print_ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
_print_warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
_print_err()  { echo -e "  ${RED}✖${NC}  $*"; }

# ── macOS: Homebrew + ffmpeg ──────────────────────────────────────────────────

_install_homebrew_macos() {
    _print_step "Installing Homebrew..."
    echo -e "  ${DIM}(You may be prompted for your password)${NC}"
    echo ""
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    local ec=$?

    # Add brew to PATH (Apple Silicon or Intel)
    if   [[ -x "/opt/homebrew/bin/brew" ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x "/usr/local/bin/brew"    ]]; then eval "$(/usr/local/bin/brew shellenv)"
    fi

    if [[ $ec -ne 0 ]] || ! command -v brew &>/dev/null; then
        _print_err "Homebrew installation failed. Install manually: https://brew.sh"
        exit 1
    fi
    _print_ok "Homebrew installed."
}

_install_ffmpeg_via_brew() {
    _print_step "Installing ffmpeg via Homebrew..."
    brew install ffmpeg >/tmp/ffmpeg_install.log 2>&1 &
    _spinner $! "Installing ffmpeg…"
    wait $!
    if ! command -v ffmpeg &>/dev/null; then
        _print_err "ffmpeg install failed. See /tmp/ffmpeg_install.log"
        exit 1
    fi
    _print_ok "ffmpeg installed."
}

_check_deps_macos() {
    # Homebrew
    if command -v brew &>/dev/null; then
        _print_ok "Homebrew: $(brew --version | head -1)"
    else
        _print_warn "Homebrew not found."
        _install_homebrew_macos
    fi

    # ffmpeg
    if command -v ffmpeg &>/dev/null; then
        _print_ok "ffmpeg: $(ffmpeg -version 2>&1 | awk 'NR==1{print $1,$2,$3}')"
    else
        _print_warn "ffmpeg not found."
        _install_ffmpeg_via_brew
    fi
}

# ── Linux / WSL: native package manager ──────────────────────────────────────

_detect_linux_pkg_manager() {
    if   command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf     &>/dev/null; then echo "dnf"
    elif command -v yum     &>/dev/null; then echo "yum"
    elif command -v pacman  &>/dev/null; then echo "pacman"
    elif command -v zypper  &>/dev/null; then echo "zypper"
    elif command -v brew    &>/dev/null; then echo "brew"
    else                                      echo "unknown"
    fi
}

_install_ffmpeg_linux() {
    local pm
    pm=$(_detect_linux_pkg_manager)
    _print_step "Installing ffmpeg via ${pm}..."

    local cmd log="/tmp/ffmpeg_install.log"
    case "$pm" in
        apt)    cmd="sudo apt-get install -y ffmpeg" ;;
        dnf)    cmd="sudo dnf install -y ffmpeg" ;;
        yum)    cmd="sudo yum install -y ffmpeg" ;;
        pacman) cmd="sudo pacman -S --noconfirm ffmpeg" ;;
        zypper) cmd="sudo zypper install -y ffmpeg" ;;
        brew)   cmd="brew install ffmpeg" ;;
        *)
            _print_err "No supported package manager found."
            _print_err "Install ffmpeg manually: https://ffmpeg.org/download.html"
            exit 1
            ;;
    esac

    echo -e "  ${DIM}Running: ${cmd}${NC}"
    $cmd >"$log" 2>&1 &
    _spinner $! "Installing ffmpeg…"
    wait $!

    if ! command -v ffmpeg &>/dev/null; then
        _print_err "ffmpeg install failed. See ${log}"
        exit 1
    fi
    _print_ok "ffmpeg installed."
}

_check_deps_linux() {
    local pm
    pm=$(_detect_linux_pkg_manager)
    _print_ok "Package manager: ${pm}"

    if command -v ffmpeg &>/dev/null; then
        _print_ok "ffmpeg: $(ffmpeg -version 2>&1 | awk 'NR==1{print $1,$2,$3}')"
    else
        _print_warn "ffmpeg not found."
        _install_ffmpeg_linux
    fi
}

# ── Windows (Git Bash / MSYS2): winget → scoop → choco ───────────────────────

_detect_win_pkg_manager() {
    if   command -v winget &>/dev/null; then echo "winget"
    elif command -v scoop  &>/dev/null; then echo "scoop"
    elif command -v choco  &>/dev/null; then echo "choco"
    else                                     echo "unknown"
    fi
}

_install_ffmpeg_windows() {
    local pm
    pm=$(_detect_win_pkg_manager)
    _print_step "Installing ffmpeg via ${pm}..."

    local cmd log="/tmp/ffmpeg_install.log"
    case "$pm" in
        winget) cmd="winget install --id Gyan.FFmpeg -e --source winget" ;;
        scoop)  cmd="scoop install ffmpeg" ;;
        choco)  cmd="choco install ffmpeg -y" ;;
        *)
            _print_err "No package manager found (winget / scoop / choco)."
            echo ""
            echo -e "  ${CYAN}Install one of:${NC}"
            echo -e "    winget : built into Windows 10/11"
            echo -e "    scoop  : https://scoop.sh"
            echo -e "    choco  : https://chocolatey.org"
            exit 1
            ;;
    esac

    echo -e "  ${DIM}Running: ${cmd}${NC}"
    $cmd >"$log" 2>&1 &
    _spinner $! "Installing ffmpeg…"
    wait $!

    if ! command -v ffmpeg &>/dev/null; then
        _print_err "ffmpeg install failed. See ${log}"
        exit 1
    fi
    _print_ok "ffmpeg installed."
}

_check_deps_windows() {
    local pm
    pm=$(_detect_win_pkg_manager)
    if [[ "$pm" == "unknown" ]]; then
        _print_warn "No package manager found (winget / scoop / choco)."
    else
        _print_ok "Package manager: ${pm}"
    fi

    if command -v ffmpeg &>/dev/null; then
        _print_ok "ffmpeg: $(ffmpeg -version 2>&1 | awk 'NR==1{print $1,$2,$3}')"
    else
        _print_warn "ffmpeg not found."
        _install_ffmpeg_windows
    fi
}

# ── Main dependency gate ──────────────────────────────────────────────────────

check_and_install_deps() {
    [[ -f "$DEPS_FLAG" ]] && return 0

    clear
    echo ""
    echo -e "  ${BOLD}╔═══════════════════════════════════════════════════╗${NC}"

    local os_label
    case "$OS_TYPE" in
        macos)   os_label="macOS" ;;
        linux)   os_label="Linux" ;;
        wsl)     os_label="Linux (WSL)" ;;
        windows) os_label="Windows" ;;
        *)       os_label="Unknown OS" ;;
    esac

    echo -e "  ${BOLD}║       🔧  Checking Dependencies  [${os_label}]${NC}"
    echo -e "  ${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    case "$OS_TYPE" in
        macos)          _check_deps_macos ;;
        linux|wsl)      _check_deps_linux ;;
        windows)        _check_deps_windows ;;
        *)
            _print_err "Unsupported OS. Install ffmpeg manually: https://ffmpeg.org/download.html"
            exit 1
            ;;
    esac

    touch "$DEPS_FLAG"
    echo ""
    _print_ok "All dependencies satisfied — this check won't run again."
    echo ""
    sleep 1.5
}

# ─────────────────────────────────────────────────────────────────────────────
#  CLI Argument Parsing
# ─────────────────────────────────────────────────────────────────────────────

show_usage() {
    echo ""
    echo -e "  ${BOLD}Usage:${NC} ./screen-recorder.sh [OPTIONS]"
    echo ""
    echo -e "  ${BOLD}Options:${NC}"
    echo -e "    ${GREEN}-d, --dir <path>${NC}        Base directory for recordings"
    echo -e "                            ${CYAN}(default: ~/testing_recording)${NC}"
    echo -e "    ${GREEN}-r, --resolution <WxH>${NC}  Recording resolution"
    echo -e "                            ${CYAN}(default: 1920x1080)${NC}"
    echo -e "    ${GREEN}-f, --fps <number>${NC}      Frames per second"
    echo -e "                            ${CYAN}(default: 30)${NC}"
    echo -e "    ${GREEN}-s, --screen <id>${NC}       Screen/display identifier:"
    echo -e "                            ${CYAN}macOS  : AVFoundation device index (default: 1)${NC}"
    echo -e "                            ${CYAN}Linux  : X display, e.g. :0 or :0+1920,0${NC}"
    echo -e "                            ${CYAN}Windows: 'desktop' or window title${NC}"
    echo -e "    ${GREEN}    --reset-deps${NC}         Re-run the dependency check next launch"
    echo -e "    ${GREEN}-h, --help${NC}              Show this help message"
    echo ""
    echo -e "  ${BOLD}Examples:${NC}"
    echo -e "    ./screen-recorder.sh"
    echo -e "    ./screen-recorder.sh -d ~/MyTests --fps 60"
    echo -e "    ./screen-recorder.sh -s :0+1920,0          # Linux second monitor"
    echo ""
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir)
                [[ -z "$2" || "$2" == -* ]] && { echo -e "${RED}ERROR: --dir requires a path.${NC}"; exit 1; }
                BASE_DIR="$2"; shift 2 ;;
            -r|--resolution)
                [[ -z "$2" || "$2" == -* ]] && { echo -e "${RED}ERROR: --resolution requires WxH.${NC}"; exit 1; }
                RESOLUTION="$2"; shift 2 ;;
            -f|--fps)
                [[ -z "$2" || "$2" == -* ]] && { echo -e "${RED}ERROR: --fps requires a number.${NC}"; exit 1; }
                FRAME_RATE="$2"; shift 2 ;;
            -s|--screen)
                [[ -z "$2" || "$2" == -* ]] && { echo -e "${RED}ERROR: --screen requires an identifier.${NC}"; exit 1; }
                SCREEN_INDEX="$2"; shift 2 ;;
            --reset-deps)
                rm -f "$DEPS_FLAG"
                echo -e "${YELLOW}Dependency flag cleared — check will run on next launch.${NC}"
                exit 0 ;;
            -h|--help) show_usage ;;
            *)
                echo -e "${RED}ERROR: Unknown option: $1${NC}"
                echo -e "Run with ${GREEN}--help${NC} for usage info."
                exit 1 ;;
        esac
    done
    BASE_DIR="${BASE_DIR/#\~/$HOME}"

    # Set per-OS default screen identifier if not specified
    if [[ -z "$SCREEN_INDEX" ]]; then
        case "$OS_TYPE" in
            macos)          SCREEN_INDEX="1" ;;
            linux|wsl)      SCREEN_INDEX="${DISPLAY:-:0}" ;;
            windows)        SCREEN_INDEX="desktop" ;;
            *)              SCREEN_INDEX="0" ;;
        esac
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  Recording Helpers
# ─────────────────────────────────────────────────────────────────────────────

get_output_dir() {
    local dir="${BASE_DIR}/$(date +"%Y-%m-%d")"
    mkdir -p "$dir"
    echo "$dir"
}

generate_temp_filename() {
    echo "$(get_output_dir)/.recording_in_progress_$$.mp4"
}

_elapsed() {
    local secs=$(( $(date +%s) - RECORDING_START_EPOCH ))
    printf "%02d:%02d" $(( secs / 60 )) $(( secs % 60 ))
}

_capture_method() {
    case "$OS_TYPE" in
        macos)   echo "avfoundation" ;;
        linux)   echo "x11grab" ;;
        wsl)     echo "x11grab (WSL)" ;;
        windows) echo "gdigrab" ;;
        *)       echo "unknown" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
#  TUI
# ─────────────────────────────────────────────────────────────────────────────

draw_ui() {
    clear
    echo ""
    echo -e "  ${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
    if $IS_RECORDING; then
        local elapsed
        elapsed=$(_elapsed)
        echo -e "  ${BOLD}║${NC}  ${RED}${BOLD}● REC${NC}  ${RED}Recording…${NC}  ${DIM}elapsed: ${elapsed}${NC}            ${BOLD}║${NC}"
    else
        echo -e "  ${BOLD}║${NC}      ${GREEN}${BOLD}■ IDLE${NC}  Ready to record                      ${BOLD}║${NC}"
    fi
    echo -e "  ${BOLD}╠═══════════════════════════════════════════════════╣${NC}"
    echo -e "  ${BOLD}║                                                   ║${NC}"
    echo -e "  ${BOLD}║${NC}   ${GREEN}[R]${NC}  Start Recording                          ${BOLD}║${NC}"
    echo -e "  ${BOLD}║${NC}   ${RED}[S]${NC}  Stop & Save Recording                     ${BOLD}║${NC}"
    echo -e "  ${BOLD}║${NC}   ${YELLOW}[Q]${NC}  Quit                                      ${BOLD}║${NC}"
    echo -e "  ${BOLD}║                                                   ║${NC}"
    echo -e "  ${BOLD}╠═══════════════════════════════════════════════════╣${NC}"
    echo -e "  ${BOLD}║${NC}  ${CYAN}Platform  :${NC} $(_capture_method)  ${DIM}[${OS_TYPE}]${NC}"
    echo -e "  ${BOLD}║${NC}  ${CYAN}Save Path :${NC} ${BASE_DIR}/<YYYY-MM-DD>/"
    echo -e "  ${BOLD}║${NC}  ${CYAN}Resolution:${NC} ${RESOLUTION} @ ${FRAME_RATE}fps  ${CYAN}Screen:${NC} ${SCREEN_INDEX}"
    echo -e "  ${BOLD}║${NC}  ${CYAN}Saved     :${NC} ${RECORDING_COUNT} recording(s) this session"
    echo -e "  ${BOLD}╠═══════════════════════════════════════════════════╣${NC}"
    if [[ -n "$STATUS_MSG" ]]; then
        echo -e "  ${BOLD}║${NC}  ${STATUS_COLOR}${STATUS_MSG}${NC}"
    else
        echo -e "  ${BOLD}║${NC}  ${DIM}Waiting for input…${NC}"
    fi
    echo -e "  ${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
}

set_status() {
    STATUS_COLOR="$1"
    STATUS_MSG="$2"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Recording Actions
# ─────────────────────────────────────────────────────────────────────────────

start_recording() {
    if $IS_RECORDING; then
        set_status "$YELLOW" "⚠  Already recording — press S to stop first."
        draw_ui
        return
    fi

    TEMP_FILE=$(generate_temp_filename)
    RECORDING_START_EPOCH=$(date +%s)

    local common_enc=(-c:v libx264 -preset ultrafast -crf 22 -pix_fmt yuv420p -y "$TEMP_FILE")

    case "$OS_TYPE" in
        macos)
            ffmpeg \
                -f avfoundation \
                -framerate "$FRAME_RATE" \
                -i "${SCREEN_INDEX}:none" \
                -vf "scale=${RESOLUTION}" \
                "${common_enc[@]}" \
                >/dev/null 2>&1 &
            ;;
        linux|wsl)
            ffmpeg \
                -f x11grab \
                -framerate "$FRAME_RATE" \
                -video_size "$RESOLUTION" \
                -i "${SCREEN_INDEX}" \
                "${common_enc[@]}" \
                >/dev/null 2>&1 &
            ;;
        windows)
            ffmpeg \
                -f gdigrab \
                -framerate "$FRAME_RATE" \
                -i "${SCREEN_INDEX}" \
                -vf "scale=${RESOLUTION}" \
                "${common_enc[@]}" \
                >/dev/null 2>&1 &
            ;;
        *)
            set_status "$RED" "✖  Unsupported OS for recording."
            draw_ui
            return
            ;;
    esac

    RECORDING_PID=$!
    IS_RECORDING=true
    set_status "$RED" "● Recording started — press S to stop and save."
    draw_ui
}

prompt_folder_choice() {
    local date_dir="$1"

    # Collect existing subfolders
    local -a folders=()
    while IFS= read -r -d '' entry; do
        folders+=("$(basename "$entry")")
    done < <(find "$date_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

    echo ""
    echo -e "  ${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}║          📁  Choose Save Location                ║${NC}"
    echo -e "  ${BOLD}╠═══════════════════════════════════════════════════╣${NC}"
    echo -e "  ${BOLD}║${NC}  ${GREEN}[1]${NC}  Today's folder  ${DIM}($(basename "$date_dir"))${NC}"
    echo -e "  ${BOLD}║${NC}  ${GREEN}[2]${NC}  Create a new subfolder"
    if [[ ${#folders[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}║${NC}  ${GREEN}[3]${NC}  Use an existing subfolder"
    fi
    echo -e "  ${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
    printf "  Choice [1]: "
    read -r choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            CHOSEN_DIR="$date_dir"
            ;;
        2)
            echo ""
            echo -e "  ${CYAN}New subfolder name (leave blank for auto-name):${NC}"
            printf "  > "
            read -r folder_name
            if [[ -z "$folder_name" ]]; then
                folder_name="session_$((RANDOM % 90000 + 10000))"
            fi
            folder_name=$(echo "$folder_name" | sed 's/[^a-zA-Z0-9._-]/_/g')
            CHOSEN_DIR="${date_dir}/${folder_name}"
            mkdir -p "$CHOSEN_DIR"
            echo -e "  ${GREEN}✔${NC}  Created: ${CHOSEN_DIR}"
            ;;
        3)
            if [[ ${#folders[@]} -eq 0 ]]; then
                echo -e "  ${YELLOW}No subfolders yet — saving to today's folder.${NC}"
                CHOSEN_DIR="$date_dir"
            else
                echo ""
                echo -e "  ${CYAN}Existing subfolders:${NC}"
                local i
                for i in "${!folders[@]}"; do
                    echo -e "    ${GREEN}[$((i+1))]${NC}  ${folders[$i]}"
                done
                echo ""
                printf "  Pick [1]: "
                read -r folder_pick
                folder_pick="${folder_pick:-1}"
                if [[ "$folder_pick" =~ ^[0-9]+$ ]] \
                   && (( folder_pick >= 1 && folder_pick <= ${#folders[@]} )); then
                    CHOSEN_DIR="${date_dir}/${folders[$((folder_pick-1))]}"
                else
                    echo -e "  ${YELLOW}Invalid choice — saving to today's folder.${NC}"
                    CHOSEN_DIR="$date_dir"
                fi
            fi
            ;;
        *)
            echo -e "  ${YELLOW}Invalid choice — saving to today's folder.${NC}"
            CHOSEN_DIR="$date_dir"
            ;;
    esac
}

prompt_and_rename() {
    local output_dir
    output_dir=$(get_output_dir)
    RECORDING_COUNT=$((RECORDING_COUNT + 1))
    local timestamp
    timestamp=$(date +"%H%M%S")

    stty "$ORIGINAL_STTY" 2>/dev/null

    prompt_folder_choice "$output_dir"

    echo ""
    echo -e "  ${CYAN}Enter test case name (leave blank for auto-name):${NC}"
    printf "  > "
    read -r test_case_name

    stty -echo -icanon min 1 time 0 2>/dev/null

    if [[ -z "$test_case_name" ]]; then
        test_case_name="test_case_$((RANDOM % 90000 + 10000))"
    fi

    test_case_name=$(echo "$test_case_name" | sed 's/[^a-zA-Z0-9._-]/_/g')
    CURRENT_FILE="${CHOSEN_DIR}/${test_case_name}_run${RECORDING_COUNT}_${timestamp}.mp4"

    [[ -f "$TEMP_FILE" ]] && mv "$TEMP_FILE" "$CURRENT_FILE"
}

stop_recording() {
    if ! $IS_RECORDING; then
        set_status "$YELLOW" "⚠  No active recording to stop."
        draw_ui
        return
    fi

    kill -INT "$RECORDING_PID" 2>/dev/null
    wait "$RECORDING_PID" 2>/dev/null
    IS_RECORDING=false
    RECORDING_PID=""

    prompt_and_rename

    local size=""
    [[ -f "$CURRENT_FILE" ]] && size="  ($(du -h "$CURRENT_FILE" | cut -f1))"
    set_status "$GREEN" "✔  Saved: $(basename "$CURRENT_FILE")${size}"
    draw_ui
}

# ─────────────────────────────────────────────────────────────────────────────
#  Cleanup
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
    trap - SIGINT SIGTERM EXIT
    stty "$ORIGINAL_STTY" 2>/dev/null
    echo ""
    if $IS_RECORDING; then
        echo -e "  ${YELLOW}Stopping active recording before exit…${NC}"
        kill -INT "$RECORDING_PID" 2>/dev/null
        wait "$RECORDING_PID" 2>/dev/null
        prompt_and_rename
        echo -e "  ${GREEN}✔  Saved: ${CURRENT_FILE}${NC}"
    fi
    rm -f "${BASE_DIR}"/*/.recording_in_progress_$$.mp4 2>/dev/null
    echo ""
    echo -e "  ${BOLD}Goodbye! Recordings saved in: ${BASE_DIR}${NC}"
    echo ""
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────────────────────────────────────

parse_args "$@"
check_and_install_deps

ORIGINAL_STTY=$(stty -g)
trap cleanup SIGINT SIGTERM EXIT

draw_ui

stty -echo -icanon min 1 time 0 2>/dev/null

while true; do
    key=$(dd bs=1 count=1 2>/dev/null)
    case "$key" in
        r|R) start_recording ;;
        s|S) stop_recording ;;
        q|Q) cleanup ;;
        *)   draw_ui ;;
    esac
done
