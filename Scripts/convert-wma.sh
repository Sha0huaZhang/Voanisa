#!/bin/bash
#
# convert-wma.sh — 把 WMA 批量转成 Voanisa 能解码的格式。
#
# WMA 是微软的私有容器，macOS 的 AVFoundation 打不开，Voanisa 的 Rust 核心也
# 没有对应解码器，所以 app 内不支持。这个脚本用本机安装的 ffmpeg 做一次性转码：
# 源文件保持不动，转换结果写在旁边（或 --out 指定的目录），确认无误后再导入。
#
# 默认输出 FLAC：WMA 都是有损编码，转成无损容器不会再有第二次质量损失。想把体积
# 压低一半可以加 --aac，代价是多一次有损编码。
#
# 用法：
#   Scripts/convert-wma.sh [选项] 目录或文件...
#
#   --flac            输出 FLAC（默认）
#   --aac             输出 AAC (.m4a)，体积更小
#   --out DIR         输出到 DIR，而不是源文件旁边
#   --recursive, -r   递归处理子目录
#   --delete          校验通过后删除源文件
#   --force           覆盖已存在的输出
#   --dry-run         只打印将要做什么
#
# 依赖：ffmpeg / ffprobe（brew install ffmpeg）。

set -euo pipefail

container="flac"
audio_codec="flac"
audio_opts=(-compression_level 8)
extension="flac"
out_dir=""
recursive=0
delete_source=0
force=0
dry_run=0

usage() {
    sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --flac) container="flac"; audio_codec="flac"; audio_opts=(-compression_level 8); extension="flac"; shift ;;
        --aac) container="m4a"; audio_codec="aac"; audio_opts=(-b:a 192k); extension="m4a"; shift ;;
        --out) out_dir="${2-}"; [[ -n "$out_dir" ]] || { echo "--out 需要目录" >&2; exit 2; }; shift 2 ;;
        --recursive|-r) recursive=1; shift ;;
        --delete) delete_source=1; shift ;;
        --force) force=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "未知选项：$1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done

command -v ffmpeg >/dev/null || { echo "缺少 ffmpeg：brew install ffmpeg" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "缺少 ffprobe：brew install ffmpeg" >&2; exit 1; }

if [[ $# -eq 0 ]]; then
    set -- .
fi

if [[ -n "$out_dir" ]]; then
    mkdir -p "$out_dir"
fi

filelist=$(mktemp)
trap 'rm -f "$filelist"' EXIT

for path in "$@"; do
    if [[ -d "$path" ]]; then
        find_args=(-type f -iname '*.wma' -print0)
        [[ $recursive == 1 ]] || find_args=(-maxdepth 1 "${find_args[@]}")
        find "$path" "${find_args[@]}" >>"$filelist"
    elif [[ -f "$path" ]]; then
        printf '%s\0' "$path" >>"$filelist"
    else
        echo "跳过（不存在）：$path" >&2
    fi
done

total=$(tr -cd '\0' <"$filelist" | wc -c | tr -d ' ')
if [[ "$total" == "0" ]]; then
    echo "没有找到 .wma 文件。" >&2
    exit 1
fi

echo "共 $total 个 WMA，输出 $container${out_dir:+ 到 $out_dir}。"

# 两个文件的时长差不超过 1 秒即认为转换完整。
duration_matches() {
    local src_duration dest_duration
    src_duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || echo 0)
    dest_duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$2" 2>/dev/null || echo 0)
    awk -v a="$src_duration" -v b="$dest_duration" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 1.0) }'
}

converted=0
skipped=0
failed=0

while IFS= read -r -d '' src; do
    dir=$(dirname "$src")
    name=$(basename "$src")
    stem=${name%.*}
    dest_dir=${out_dir:-$dir}
    dest="$dest_dir/$stem.$extension"

    if [[ -e "$dest" && $force == 0 ]]; then
        # 输出已经在了：如果用户要求删除源文件，先确认这份输出确实能用。
        if [[ $delete_source == 1 ]] && duration_matches "$src" "$dest"; then
            rm -f "$src"
            echo "跳过（已存在，删除源文件）：$dest"
        else
            echo "跳过（已存在）：$dest"
        fi
        skipped=$((skipped + 1))
        continue
    fi

    if [[ $dry_run == 1 ]]; then
        echo "$src -> $dest"
        continue
    fi

    # 封面在 ASF 里是独立的视频流；没有就不能传 -disposition:v。
    cover_map=()
    if [[ -n "$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$src" 2>/dev/null)" ]]; then
        cover_map=(-map 0:v:0 -c:v copy -disposition:v attached_pic)
    fi

    if ! ffmpeg -nostdin -hide_banner -loglevel error -y \
        -i "$src" -map 0:a:0 ${cover_map[@]+"${cover_map[@]}"} \
        -c:a "$audio_codec" "${audio_opts[@]}" -map_metadata 0 \
        "$dest" </dev/null; then
        echo "失败：$src" >&2
        rm -f "$dest"
        failed=$((failed + 1))
        continue
    fi

    # 时长对得上才算转换成功；WMA 的头部偶尔会谎报，这里以实际解出的长度为准。
    if ! duration_matches "$src" "$dest"; then
        echo "校验失败：$dest" >&2
        failed=$((failed + 1))
        continue
    fi

    echo "完成：$name -> $(basename "$dest")"
    converted=$((converted + 1))

    if [[ $delete_source == 1 ]]; then
        rm -f "$src"
    fi
done <"$filelist"

if [[ $dry_run == 1 ]]; then
    exit 0
fi

echo "完成 $converted 个，跳过 $skipped 个，失败 $failed 个。"
if [[ $delete_source == 0 && $converted -gt 0 ]]; then
    echo "源文件未删除；确认无误后可加 --delete 重跑，或手动清理。"
fi

[[ $failed == 0 ]]
