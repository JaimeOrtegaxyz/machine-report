#!/bin/bash
# TR-100 Machine Report — macOS Edition
# Fork of usgraphics/usgc-machine-report. BSD-3-Clause.

# Configuration
report_title="MACHINE REPORT"
DEMO_MODE=false

# Colors
C_RESET=$'\e[0m'
BG_WIN=$'\e[48;2;170;170;170m'
FG_FRAME=$'\e[38;2;255;255;255m'
FG_TEXT=$'\e[38;2;0;0;0m'
FG_LABEL=$'\e[1;38;2;0;0;0m'
FG_TITLE=$'\e[1;38;2;255;255;255m'
FG_DIV=$'\e[38;2;255;255;255m'
FG_BAR=$'\e[38;2;0;170;0m'
FG_BAR_EMPTY=$'\e[38;2;115;115;115m'
C_SHADOW=$'\e[48;2;0;0;0m'

# Layout
MIN_NAME_LEN=5
MAX_NAME_LEN=13
MAX_DATA_LEN=32
INDENT="  "

max_length() {
    local max_len=0 len
    for str in "$@"; do
        len=${#str}
        (( len > max_len )) && max_len=$len
    done
    (( max_len > MAX_DATA_LEN )) && max_len=$MAX_DATA_LEN
    printf '%s' "$max_len"
}

strip_ansi() {
    printf '%s' "$1" | sed $'s/\e\\[[0-9;]*m//g'
}

bar_graph() {
    local used=$1 total=$2 width=$CURRENT_LEN graph="" percent num_blocks
    if (( total == 0 )); then percent=0
    else percent=$(awk -v u="$used" -v t="$total" 'BEGIN { printf "%.2f", (u/t)*100 }'); fi
    num_blocks=$(awk -v p="$percent" -v w="$width" 'BEGIN { n=int((p/100)*w); if(n>w) n=w; printf "%d", n }')
    graph+="${FG_BAR}"
    for (( i=0; i<num_blocks; i++ )); do graph+="█"; done
    graph+="${FG_BAR_EMPTY}"
    for (( i=num_blocks; i<width; i++ )); do graph+="░"; done
    printf "%s" "$graph"
}

_shadow_r() { printf "${C_RESET}${C_SHADOW}  ${C_RESET}"; }

_repeat() {
    local char=$1 n=$2
    for ((i=0; i<n; i++)); do printf "%s" "$char"; done
}

PRINT_TOP() {
    local inner=$((MAX_NAME_LEN + CURRENT_LEN + 5))
    local col_pos=$((MAX_NAME_LEN + 2))
    local title=" ${report_title} "
    local tlen=${#title}
    local eq=$((inner - tlen))
    local el=$((eq / 2))
    local er=$((eq - el))
    local title_end=$((el + tlen))
    printf "${INDENT}${BG_WIN}${FG_FRAME}╔"
    if (( col_pos < el )); then
        _repeat "═" $col_pos
        printf "╤"
        _repeat "═" $((el - col_pos - 1))
        printf "${FG_TITLE}${title}${BG_WIN}${FG_FRAME}"
        _repeat "═" $er
    elif (( col_pos >= title_end )); then
        _repeat "═" $el
        printf "${FG_TITLE}${title}${BG_WIN}${FG_FRAME}"
        _repeat "═" $((col_pos - title_end))
        printf "╤"
        _repeat "═" $((inner - col_pos - 1))
    else
        _repeat "═" $el
        printf "${FG_TITLE}${title}${BG_WIN}${FG_FRAME}"
        _repeat "═" $er
    fi
    printf "╗${C_RESET}\n"
}

PRINT_BOTTOM() {
    local inner=$((MAX_NAME_LEN + CURRENT_LEN + 5))
    local col_pos=$((MAX_NAME_LEN + 2))
    local win_total=$((inner + 2))
    printf "${INDENT}${BG_WIN}${FG_FRAME}╚"
    _repeat "═" $col_pos
    printf "╧"
    _repeat "═" $((inner - col_pos - 1))
    printf "╝${C_RESET}"
    _shadow_r
    printf "\n"
    printf "${INDENT}  ${C_SHADOW}%${win_total}s${C_RESET}\n" ""
}

PRINT_BLANK() {
    local left_w=$((MAX_NAME_LEN + 2))
    local right_w=$((CURRENT_LEN + 2))
    printf "${INDENT}${BG_WIN}${FG_FRAME}║%${left_w}s${FG_DIV}│%${right_w}s${FG_FRAME}║${C_RESET}" "" ""
    _shadow_r
    printf "\n"
}

PRINT_DIVIDER() {
    local left_w=$((MAX_NAME_LEN + 2))
    local right_w=$((CURRENT_LEN + 2))
    printf "${INDENT}${BG_WIN}${FG_FRAME}╟${FG_DIV}"
    _repeat "─" $left_w
    printf "┼"
    _repeat "─" $right_w
    printf "${FG_FRAME}╢${C_RESET}"
    _shadow_r
    printf "\n"
}

_wrap_text() {
    local text="$1" width="$2"
    local lines=()
    local line="" w
    local words=()
    if [ -n "$ZSH_VERSION" ]; then
        words=(${=text})
    else
        local oldIFS="$IFS"
        IFS=$' \t\n'
        set -f
        words=($text)
        set +f
        IFS="$oldIFS"
    fi
    for w in "${words[@]}"; do
        if (( ${#w} > width )); then
            [[ -n "$line" ]] && { lines+=("$line"); line=""; }
            while (( ${#w} > width )); do
                lines+=("${w:0:$width}")
                w="${w:$width}"
            done
            line="$w"
        elif [[ -z "$line" ]]; then
            line="$w"
        elif (( ${#line} + 1 + ${#w} <= width )); then
            line+=" $w"
        else
            lines+=("$line")
            line="$w"
        fi
    done
    [[ -n "$line" ]] && lines+=("$line")
    (( ${#lines[@]} == 0 )) && lines+=("")
    printf '%s\n' "${lines[@]}"
}

PRINT_DATA() {
    local name="$1" data="$2"
    local nlen=${#name}
    if (( nlen > MAX_NAME_LEN )); then
        name=$(printf '%s' "$name" | cut -c 1-$((MAX_NAME_LEN-3)))...
    fi
    name=$(printf "%-${MAX_NAME_LEN}s" "$name")
    local blank_name
    blank_name=$(printf "%-${MAX_NAME_LEN}s" "")
    local stripped
    stripped=$(strip_ansi "$data")
    local vis=${#stripped}

    local -a render_lines
    if (( vis > CURRENT_LEN )); then
        while IFS= read -r wline; do
            render_lines+=("$wline")
        done < <(_wrap_text "$stripped" "$CURRENT_LEN")
    else
        render_lines+=("$data")
    fi

    local idx=0 line label_part pad_vis pad
    for line in "${render_lines[@]}"; do
        if (( idx == 0 && vis <= CURRENT_LEN )); then
            pad_vis=$vis
        else
            pad_vis=${#line}
        fi
        if (( pad_vis < CURRENT_LEN )); then
            pad=$(printf "%$((CURRENT_LEN - pad_vis))s" "")
        else
            pad=""
        fi
        if (( idx == 0 )); then
            label_part="${FG_LABEL}${name}"
        else
            label_part="${FG_LABEL}${blank_name}"
        fi
        printf '%s' "${INDENT}${BG_WIN}${FG_FRAME}║ ${label_part} ${FG_DIV}│${C_RESET}${BG_WIN} ${FG_TEXT}${line}${pad} ${FG_FRAME}║${C_RESET}"
        _shadow_r
        printf "\n"
        idx=$((idx + 1))
    done
}

# OS
os_name="macOS $(sw_vers -productVersion) ($(uname -m))"
os_kernel="Darwin $(uname -r)"
os_model=$(sysctl -n hw.model 2>/dev/null)

# Network
net_hostname=$(hostname -f 2>/dev/null || hostname)
net_current_user=$(whoami)
net_machine_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "No IP")
if [[ "$net_machine_ip" == "No IP" ]]; then
    net_machine_ip=$(ipconfig getifaddr en1 2>/dev/null || echo "No IP")
fi

# CPU
cpu_chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null)
cpu_pcores=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "?")
cpu_ecores=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo "?")
cpu_core_info="${cpu_pcores}P + ${cpu_ecores}E / ${cpu_cores} Threads"

# Load
load_avg_1min=$(sysctl -n vm.loadavg | awk '{print $2}')
load_avg_5min=$(sysctl -n vm.loadavg | awk '{print $3}')
load_avg_15min=$(sysctl -n vm.loadavg | awk '{print $4}')

# Memory
mem_total_bytes=$(sysctl -n hw.memsize)
mem_total_gb=$(awk -v t="$mem_total_bytes" 'BEGIN { printf "%.1f", t / (1024^3) }')
page_size=$(vm_stat | head -1 | grep -o '[0-9]*')
mem_pages_active=$(vm_stat | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
mem_pages_wired=$(vm_stat | awk '/Pages wired/ {gsub(/\./,"",$4); print $4}')
mem_pages_compressed=$(vm_stat | awk '/Pages occupied by compressor/ {gsub(/\./,"",$5); print $5}')
mem_used_bytes=$(( (mem_pages_active + mem_pages_wired + mem_pages_compressed) * page_size ))
mem_used_gb=$(awk -v u="$mem_used_bytes" 'BEGIN { printf "%.1f", u / (1024^3) }')
mem_percent=$(awk -v u="$mem_used_bytes" -v t="$mem_total_bytes" 'BEGIN { printf "%.0f", (u/t)*100 }')

# Disk
apfs_info=$(diskutil apfs list 2>/dev/null)
disk_total_bytes=$(echo "$apfs_info" | awk '/Size \(Capacity Ceiling\)/  { for(i=1;i<NF;i++) if($i~/^[0-9]+$/ && $(i+1)=="B") {print $i; exit} }' | head -1)
disk_used_bytes=$(echo "$apfs_info"  | awk '/Capacity In Use By Volumes/ { for(i=1;i<NF;i++) if($i~/^[0-9]+$/ && $(i+1)=="B") {print $i; exit} }' | head -1)
if [[ -n "$disk_total_bytes" && -n "$disk_used_bytes" ]]; then
    root_total_gb=$(awk -v t="$disk_total_bytes" 'BEGIN { printf "%.0f", t / (1024^3) }')
    root_used_gb=$(awk -v u="$disk_used_bytes" 'BEGIN { printf "%.0f", u / (1024^3) }')
    disk_percent=$(awk -v u="$disk_used_bytes" -v t="$disk_total_bytes" 'BEGIN { printf "%.0f", (u/t)*100 }')
    root_used=$((disk_used_bytes / 1048576))
    root_total=$((disk_total_bytes / 1048576))
else
    root_used=$(df -m / | awk 'NR==2 {print $3}')
    root_total=$(df -m / | awk 'NR==2 {print $2}')
    root_total_gb=$(awk -v t="$root_total" 'BEGIN { printf "%.0f", t / 1024 }')
    root_used_gb=$(awk -v u="$root_used" 'BEGIN { printf "%.0f", u / 1024 }')
    disk_percent=$(awk -v u="$root_used" -v t="$root_total" 'BEGIN { printf "%.0f", (u/t)*100 }')
fi

# Battery
battery_info=$(pmset -g batt 2>/dev/null | grep -o '[0-9]*%.*' | head -1)
if [[ -n "$battery_info" ]]; then
    battery_pct=$(echo "$battery_info" | grep -o '^[0-9]*')
    battery_state=$(echo "$battery_info" | sed 's/^[0-9]*%; //' | cut -d';' -f1)
    battery_display="${battery_pct}% ${battery_state}"
else
    battery_display="N/A"
fi

# Display
display_res=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Resolution" | head -1 | sed 's/.*: //' | xargs)

# Shell & Terminal
shell_info="$(basename "$SHELL") $(${SHELL} --version 2>&1 | head -1 | grep -o '[0-9][0-9.]*' | head -1)"
terminal_info="${TERM_PROGRAM:-Unknown} ${TERM_PROGRAM_VERSION:-}"

# Packages
brew_count=""
if command -v brew &>/dev/null; then
    brew_count=$(brew list 2>/dev/null | wc -l | tr -d ' ')
fi

# Uptime
raw_uptime=$(sysctl -n kern.boottime | awk '{print $4}' | tr -d ',')
now=$(date +%s)
uptime_secs=$((now - raw_uptime))
uptime_days=$((uptime_secs / 86400))
uptime_hours=$(( (uptime_secs % 86400) / 3600 ))
uptime_mins=$(( (uptime_secs % 3600) / 60 ))
sys_uptime=""
(( uptime_days > 0 )) && sys_uptime+="${uptime_days}d "
(( uptime_hours > 0 )) && sys_uptime+="${uptime_hours}h "
sys_uptime+="${uptime_mins}m"

# Demo mode overrides
if [[ "$DEMO_MODE" == true ]]; then
    os_name="macOS 15.3.1 (arm64)"
    os_kernel="Darwin 24.3.0"
    os_model="Mac14,6"
    net_hostname="workstation.local"
    net_machine_ip="127.0.0.1"
    net_current_user="user"
    cpu_chip="Apple M2 Max"
    cpu_cores=12
    cpu_pcores=8
    cpu_ecores=4
    cpu_core_info="8P + 4E / 12 Threads"
    load_avg_1min="2.45"
    load_avg_5min="1.87"
    load_avg_15min="1.32"
    mem_total_bytes=$((32 * 1024 * 1024 * 1024))
    mem_used_bytes=$((18 * 1024 * 1024 * 1024))
    mem_total_gb="32.0"
    mem_used_gb="18.4"
    mem_percent="58"
    root_total=953862
    root_used=476931
    root_total_gb="932"
    root_used_gb="466"
    disk_percent="50"
    disk_total_bytes=$((root_total * 1048576))
    disk_used_bytes=$((root_used * 1048576))
    battery_pct="78"
    battery_state="discharging"
    battery_display="78% discharging"
    display_res="3456 x 2234 Retina"
    shell_info="zsh 5.9"
    terminal_info="Apple_Terminal 453"
    brew_count="347"
    sys_uptime="4d 7h 23m"
fi

# Set current length before graphs get calculated
CURRENT_LEN=$(max_length              \
    "$report_title"                   \
    "$os_name"                        \
    "$os_kernel"                      \
    "$os_model"                       \
    "$net_hostname"                   \
    "$net_machine_ip"                 \
    "$net_current_user"               \
    "$cpu_chip"                       \
    "$cpu_core_info"                  \
    "$root_used_gb/${root_total_gb} GB [${disk_percent}%]" \
    "${mem_used_gb}/${mem_total_gb} GiB [${mem_percent}%]" \
    "$battery_display"                \
    "$display_res"                    \
    "$shell_info"                     \
    "$terminal_info"                  \
    "$sys_uptime"                     \
)

# Create graphs
cpu_1min_graph=$(bar_graph "$load_avg_1min" "$cpu_cores")
cpu_5min_graph=$(bar_graph "$load_avg_5min" "$cpu_cores")
cpu_15min_graph=$(bar_graph "$load_avg_15min" "$cpu_cores")
disk_bar_graph=$(bar_graph "$root_used" "$root_total")
mem_bar_graph=$(bar_graph "$mem_used_bytes" "$mem_total_bytes")

# Machine Report
printf "\n"
PRINT_TOP
PRINT_DATA "MODEL" "$os_model"
PRINT_DATA "OS" "$os_name"
PRINT_DATA "KERNEL" "$os_kernel"
PRINT_DIVIDER
PRINT_DATA "HOST" "$net_hostname"
PRINT_DATA "IP" "$net_machine_ip"
PRINT_DATA "USER" "$net_current_user"
PRINT_DIVIDER
PRINT_DATA "CHIP" "$cpu_chip"
PRINT_DATA "CORES" "$cpu_core_info"
PRINT_DATA "LOAD  1m" "$cpu_1min_graph"
PRINT_DATA "LOAD  5m" "$cpu_5min_graph"
PRINT_DATA "LOAD 15m" "$cpu_15min_graph"
PRINT_DIVIDER
PRINT_DATA "VOLUME" "${root_used_gb}/${root_total_gb} GB [${disk_percent}%]"
PRINT_DATA "DISK USAGE" "$disk_bar_graph"
PRINT_DIVIDER
PRINT_DATA "MEMORY" "${mem_used_gb}/${mem_total_gb} GiB [${mem_percent}%]"
PRINT_DATA "USAGE" "$mem_bar_graph"
PRINT_DIVIDER
PRINT_DATA "BATTERY" "$battery_display"
PRINT_DATA "DISPLAY" "$display_res"
PRINT_DATA "SHELL" "$shell_info"
PRINT_DATA "TERMINAL" "$terminal_info"
[[ -n "$brew_count" ]] && PRINT_DATA "PACKAGES" "${brew_count} (brew)"
PRINT_DATA "UPTIME" "$sys_uptime"
PRINT_BOTTOM
printf "\n"
