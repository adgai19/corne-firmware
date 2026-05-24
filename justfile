# _default:
#   @just --list
#
# flash:
#   cp /mnt/data/Downloads/firmware.zip .
#   rm *.uf2
#   unzip firmware.zip
#   cp corny_left\ rgbled_adapter-seeeduino_xiao_ble-zmk.uf2 /run/media/adgai/XIAO-SENSE
#
#

default:
    @just --list --unsorted

config := absolute_path('config')
build := absolute_path('.build')
out := absolute_path('firmware')
draw := absolute_path('draw')

# parse build.yaml and filter targets by expression
_parse_targets $expr:
    #!/usr/bin/env bash
    attrs="[.board, .shield, .snippet, .\"artifact-name\"]"
    filter="(($attrs | map(. // [.]) | combinations), ((.include // {})[] | $attrs)) | join(\",\")"
    echo "$(yq -r "$filter" build.yaml | grep -v "^," | grep -i "${expr/#all/.*}")"

# build firmware for single board & shield combination
_build_single $board $shield $snippet $artifact *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    artifact="${artifact:-${shield:+${shield// /+}-}${board}}"
    build_dir="{{ build / '$artifact' }}"

    echo "Building firmware for $artifact..."
    west build -s zmk/app -d "$build_dir" -b $board {{ west_args }} ${snippet:+-S "$snippet"} -- \
        -DZMK_CONFIG="{{ config }}" ${shield:+-DSHIELD="$shield"}

    if [[ -f "$build_dir/zephyr/zmk.uf2" ]]; then
        mkdir -p "{{ out }}" && cp "$build_dir/zephyr/zmk.uf2" "{{ out }}/$artifact.uf2"
    else
        mkdir -p "{{ out }}" && cp "$build_dir/zephyr/zmk.bin" "{{ out }}/$artifact.bin"
    fi

# build firmware for matching targets
build expr *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    targets=$(just _parse_targets {{ expr }})

    [[ -z $targets ]] && echo "No matching targets found. Aborting..." >&2 && exit 1
    echo "$targets" | while IFS=, read -r board shield snippet artifact; do
        just _build_single "$board" "$shield" "$snippet" "$artifact" {{ west_args }}
    done

# flash firmware to left, right, or both halves (double-tap reset first)
# usage: just flash left | just flash right | just flash all
flash side="all": (build side)
    #!/usr/bin/env bash
    set -euo pipefail
    volume="/Volumes/XIAO-SENSE"

    _flash_one() {
        local uf2="$1"
        echo "→ Double-tap reset on the keyboard half, then press Enter..."
        read -r
        echo "  Waiting for $volume..."
        for i in $(seq 1 30); do
            [[ -d "$volume" ]] && break
            sleep 1
        done
        [[ ! -d "$volume" ]] && echo "Timed out waiting for $volume" >&2 && exit 1
        echo "  Flashing $uf2..."
        cp "{{ out }}/$uf2" "$volume/"
        echo "  Done — drive will eject automatically."
    }

    if [[ "{{ side }}" == "all" ]]; then
        _flash_one "corny_left+rgbled_adapter-seeeduino_xiao_ble.uf2"
        _flash_one "corny_right+rgbled_adapter-seeeduino_xiao_ble.uf2"
    elif [[ "{{ side }}" == "left" ]]; then
        _flash_one "corny_left+rgbled_adapter-seeeduino_xiao_ble.uf2"
    elif [[ "{{ side }}" == "right" ]]; then
        _flash_one "corny_right+rgbled_adapter-seeeduino_xiao_ble.uf2"
    else
        echo "Unknown side '{{ side }}' — use left, right, or all" >&2 && exit 1
    fi

# clear build cache and artifacts
clean:
    rm -rf {{ build }} {{ out }}

# clear all automatically generated files
clean-all: clean
    rm -rf .west zmk

# clear nix cache
clean-nix:
    nix-collect-garbage --delete-old

# generate wallpaper SVG + PNG (urob-style vertical stack, dark theme)
# override resolution: just draw-wallpaper width=1920 height=1080
draw-wallpaper width="2560" height="1440": draw
    #!/usr/bin/env bash
    set -euo pipefail
    if ! keymap -c "{{ draw }}/wallpaper-config.yaml" \
        draw "{{ draw }}/keymap.yaml" \
        --dts-layout "{{ config }}/boards/shields/corny/corny-layouts.dtsi" \
        --select-layers Base Nav Sym Num Fn Combos \
        >"{{ draw }}/wallpaper.svg" 2>&1; then
        echo "Available layers:" >&2
        python3 -c "import yaml; d=yaml.safe_load(open('{{ draw }}/keymap.yaml')); print('\n'.join('  ' + l for l in d['layers']))" >&2
        exit 1
    fi
    rsvg-convert \
        --width={{ width }} --height={{ height }} \
        --keep-aspect-ratio \
        --background-color="#11111b" \
        "{{ draw }}/wallpaper.svg" \
        -o "{{ draw }}/wallpaper.png"
    echo "Done → {{ draw }}/wallpaper.png"


# parse & plot keymap
draw:
    #!/usr/bin/env bash
    set -euo pipefail
    keymap -c "{{ draw }}/config.yaml" parse -z "{{ config }}/boards/shields/corny/corny.keymap" --virtual-layers Combos >"{{ draw }}/keymap.yaml"
    yq -Yi '.combos.[].l = ["Combos"]' "{{ draw }}/keymap.yaml"
    keymap -c "{{ draw }}/config.yaml" draw "{{ draw }}/keymap.yaml" --dts-layout "{{ config }}/boards/shields/corny/corny-layouts.dtsi" >"{{ draw }}/keymap.svg"

# initialize west
init:
    west init -l config
    west update --fetch-opt=--filter=blob:none
    west zephyr-export

# list build targets
list:
    @just _parse_targets all | sed 's/,*$//' | sort | column

# update west
update:
    west update --fetch-opt=--filter=blob:none

# upgrade zephyr-sdk and python dependencies
upgrade-sdk:
    nix flake update --flake .

[no-cd]
test $testpath *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    testcase=$(basename "$testpath")
    build_dir="{{ build / "tests" / '$testcase' }}"
    config_dir="{{ '$(pwd)' / '$testpath' }}"
    cd {{ justfile_directory() }}

    if [[ "{{ FLAGS }}" != *"--no-build"* ]]; then
        echo "Running $testcase..."
        rm -rf "$build_dir"
        west build -s zmk/app -d "$build_dir" -b native_posix_64 -- \
            -DCONFIG_ASSERT=y -DZMK_CONFIG="$config_dir"
    fi

    ${build_dir}/zephyr/zmk.exe | sed -e "s/.*> //" |
        tee ${build_dir}/keycode_events.full.log |
        sed -n -f ${config_dir}/events.patterns > ${build_dir}/keycode_events.log
    if [[ "{{ FLAGS }}" == *"--verbose"* ]]; then
        cat ${build_dir}/keycode_events.log
    fi

    if [[ "{{ FLAGS }}" == *"--auto-accept"* ]]; then
        cp ${build_dir}/keycode_events.log ${config_dir}/keycode_events.snapshot
    fi
    diff -auZ ${config_dir}/keycode_events.snapshot ${build_dir}/keycode_events.log


# BASE NAV  SYM  NUM  MEDIA BLE  
