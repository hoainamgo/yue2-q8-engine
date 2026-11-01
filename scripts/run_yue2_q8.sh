#!/usr/bin/env bash
# ============================================================================
# run_yue2_q8.sh — Runner YuE2 route Q8 dùng chung cho Colab / Kaggle / máy
# Linux bất kỳ có GPU NVIDIA T4 (sm_75).
#
# Luồng (Giải pháp 2): tải gói engine build sẵn từ GitHub Release -> kiểm
# sha256 -> giải nén -> tải weights GGUF từ HuggingFace -> chạy yue-synth
# bằng ĐÚNG lệnh + LD_LIBRARY_PATH của driver đã proven -> in hậu kiểm.
#
# Cách dùng:
#   1) Điền RELEASE_TARBALL_URL (+ RELEASE_TARBALL_SHA256) ở khối cấu hình
#      dưới sau khi workflow build-yue2-cpp đã phát hành Release đầu tiên.
#      (Hoặc đặt ENGINE_TARBALL=/đường/dẫn/file.tar.gz nếu đã tải tay.)
#   2) bash scripts/run_yue2_q8.sh [request.json]
#      Mặc định dùng ../request_millroad.json (bài nghiệm thu đã proven).
#
# Yêu cầu trên máy chạy: GPU T4 + driver NVIDIA, curl hoặc wget, tar,
# python3 (tải GGUF qua huggingface_hub như driver proven; thiếu thì script
# tự rơi về curl), ffmpeg + ffprobe (hậu kiểm).
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CẤU HÌNH — sửa tại đây
# ---------------------------------------------------------------------------
# TODO: điền URL file yue2-cpp-linux-x64-cuda12.tar.gz trên GitHub Release
# (dạng https://github.com/<owner>/<repo>/releases/download/engine-v1.0.0/yue2-cpp-linux-x64-cuda12.tar.gz)
RELEASE_TARBALL_URL="${RELEASE_TARBALL_URL:-}"
# TODO: điền sha256 của tarball (nội dung file .tar.gz.sha256 kèm Release)
RELEASE_TARBALL_SHA256="${RELEASE_TARBALL_SHA256:-}"
# Đường dẫn tarball có sẵn trên máy (thay cho tải từ URL) — để trống nếu dùng URL
ENGINE_TARBALL="${ENGINE_TARBALL:-}"

# Weights: đúng repo/revision/file đã proven trong BUILD_INFO + driver Colab.
HF_REPO="Serveurperso/YuE2-GGUF"
HF_REVISION="e630f2b8f6aedf8254c3186438633c1b5eeaf80a"
MODEL_FILE="YuE2-3B-Q8_0.gguf"
MODEL_BYTES=3810232064
MODEL_SHA256="41121ce97786d7795a325bcf123ca196956c03bb252c9e75384cfc1f2fc19e6b"
VAE_FILE="YuE2-Vae-F32.gguf"
VAE_BYTES=530497344
VAE_SHA256="93e49dfb1970e89ad64cacb17cf13b5d05f6bb30ef7ed3adae3050bcb728638a"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$PWD/yue2q8_run}"
REQUEST_FILE="${1:-${REQUEST_FILE:-$SCRIPT_DIR/../request_millroad.json}}"
OUT_WAV="$WORK_DIR/song.wav"
OUT_FLAC="$WORK_DIR/song.flac"
OUT_SCORE="$WORK_DIR/score_out.abc"
OUT_TOKENS="$WORK_DIR/tokens.csv"
ENGINE_DIR="$WORK_DIR/engine"
GGUF_DIR="$WORK_DIR/gguf"

# ---------------------------------------------------------------------------
# Tiện ích
# ---------------------------------------------------------------------------
die() { echo "LỖI: $*" >&2; exit 1; }
info() { echo "[run_yue2_q8] $*"; }

download() { # url dest
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$2" "$1"
  else
    die "cần curl hoặc wget để tải file"
  fi
}

check_file() { # path bytes sha256 label
  local p="$1" want_bytes="$2" want_sha="$3" label="$4"
  [ -f "$p" ] || die "$label: không thấy file $p"
  local got_bytes got_sha
  got_bytes=$(stat -c %s "$p")
  [ "$got_bytes" = "$want_bytes" ] || die "$label: dung lượng lệch — có $got_bytes byte, cần $want_bytes ($p)"
  got_sha=$(sha256sum "$p" | awk '{print $1}')
  [ "$got_sha" = "$want_sha" ] || die "$label: sha256 lệch — có $got_sha, cần $want_sha ($p)"
  info "$label: OK ($got_bytes byte, sha256 khớp)"
}

# ---------------------------------------------------------------------------
# Kiểm tra đầu vào + công cụ
# ---------------------------------------------------------------------------
for tool in tar sha256sum ffmpeg ffprobe; do
  command -v "$tool" >/dev/null 2>&1 || die "thiếu công cụ: $tool"
done
[ -f "$REQUEST_FILE" ] || die "không thấy file request: $REQUEST_FILE"
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi | head -12 || \
  echo "CẢNH BÁO: không thấy nvidia-smi — máy này có thể không có GPU NVIDIA" >&2
mkdir -p "$WORK_DIR" "$ENGINE_DIR" "$GGUF_DIR"

# ---------------------------------------------------------------------------
# 1) Engine: tải gói build sẵn -> kiểm sha256 -> giải nén
# ---------------------------------------------------------------------------
TARBALL="$WORK_DIR/yue2-cpp-linux-x64-cuda12.tar.gz"
if [ -n "$ENGINE_TARBALL" ]; then
  [ -f "$ENGINE_TARBALL" ] || die "ENGINE_TARBALL không tồn tại: $ENGINE_TARBALL"
  cp "$ENGINE_TARBALL" "$TARBALL"
elif [ -n "$RELEASE_TARBALL_URL" ]; then
  [ -f "$TARBALL" ] || download "$RELEASE_TARBALL_URL" "$TARBALL"
else
  die "chưa cấu hình nguồn engine: điền RELEASE_TARBALL_URL trong script hoặc đặt ENGINE_TARBALL=<file.tar.gz>"
fi
if [ -n "$RELEASE_TARBALL_SHA256" ]; then
  got=$(sha256sum "$TARBALL" | awk '{print $1}')
  [ "$got" = "$RELEASE_TARBALL_SHA256" ] || die "sha256 gói engine lệch: $got != $RELEASE_TARBALL_SHA256"
  info "gói engine: sha256 OK"
fi
tar -xzf "$TARBALL" -C "$ENGINE_DIR"
[ -x "$ENGINE_DIR/yue-synth" ] || die "giải nén xong nhưng không thấy $ENGINE_DIR/yue-synth"
# Khôi phục symlink SONAME nếu tarball/đường truyền làm rớt (script đã proven)
[ -f "$ENGINE_DIR/link_libs.sh" ] && bash "$ENGINE_DIR/link_libs.sh" || true
for so in libggml.so.0.27.0 libggml-base.so.0.27.0 libggml-cpu.so.0.27.0 libggml-cuda.so.0.27.0; do
  [ -f "$ENGINE_DIR/$so" ] || die "thiếu thư viện trong gói engine: $so"
done
info "engine sẵn sàng tại $ENGINE_DIR"

# ---------------------------------------------------------------------------
# 2) Weights GGUF từ HuggingFace (đúng revision đã proven)
# ---------------------------------------------------------------------------
fetch_gguf() { # filename
  local f="$1" dest="$GGUF_DIR/$1"
  if [ -f "$dest" ]; then info "$f: đã có, bỏ qua tải"; return 0; fi
  if python3 -c "import huggingface_hub" >/dev/null 2>&1; then
    python3 - "$HF_REPO" "$HF_REVISION" "$f" "$GGUF_DIR" <<'PYEOF'
import sys
from huggingface_hub import hf_hub_download
repo, rev, fname, outdir = sys.argv[1:5]
hf_hub_download(repo, fname, revision=rev, local_dir=outdir)
PYEOF
  else
    download "https://huggingface.co/${HF_REPO}/resolve/${HF_REVISION}/${f}" "$dest"
  fi
}
fetch_gguf "$MODEL_FILE"
fetch_gguf "$VAE_FILE"
check_file "$GGUF_DIR/$MODEL_FILE" "$MODEL_BYTES" "$MODEL_SHA256" "model GGUF"
check_file "$GGUF_DIR/$VAE_FILE" "$VAE_BYTES" "$VAE_SHA256" "VAE GGUF"
# Bố cục đã proven: weights nằm cạnh binary trong thư mục engine
cp "$GGUF_DIR/$MODEL_FILE" "$GGUF_DIR/$VAE_FILE" "$ENGINE_DIR/"

# ---------------------------------------------------------------------------
# 3) Chạy engine — ĐÚNG lệnh của driver đã proven (Kaggle kernel + Colab)
#    yue-synth mang RUNPATH trỏ về thư mục build gốc nên LUÔN chạy kèm
#    LD_LIBRARY_PATH=<thư mục engine>.
# ---------------------------------------------------------------------------
info "render: $REQUEST_FILE"
LD_LIBRARY_PATH="$ENGINE_DIR" "$ENGINE_DIR/yue-synth" \
  --model "$ENGINE_DIR/$MODEL_FILE" \
  --vae "$ENGINE_DIR/$VAE_FILE" \
  --request "$REQUEST_FILE" \
  --out "$OUT_WAV" \
  --score "$OUT_SCORE" \
  --tokens "$OUT_TOKENS"
[ -f "$OUT_WAV" ] || die "engine chạy xong nhưng không có file out: $OUT_WAV"

# ---------------------------------------------------------------------------
# 4) Hậu kiểm: WAV -> FLAC, ffprobe thời lượng, sha256, đối chiếu phổ
# ---------------------------------------------------------------------------
ffmpeg -y -v error -i "$OUT_WAV" -codec:a flac "$OUT_FLAC"
echo "================ HẬU KIỂM ================"
for f in "$OUT_WAV" "$OUT_FLAC"; do
  echo "-- $f"
  ffprobe -v error -show_entries format=duration,size \
    -show_entries stream=codec_name,sample_rate,channels -of default=noprint_wrappers=1 "$f"
done
echo "sha256 FLAC: $(sha256sum "$OUT_FLAC" | awk '{print $1}')"
echo "score-out  : $OUT_SCORE"
if python3 - "$REQUEST_FILE" "$OUT_SCORE" <<'PYEOF'
import json, sys
req = json.load(open(sys.argv[1]))
abc_in = req.get("abc") or ""
if not abc_in:
    print("đối chiếu phổ: bỏ qua (request planner-first, abc rỗng)")
    sys.exit(0)
got = open(sys.argv[2], encoding="utf-8").read()
print(f"đối chiếu phổ: nạp {len(abc_in)} ký tự / xuất {len(got)} ký tự / "
      f"khớp tuyệt đối: {got == abc_in} / khớp sau strip: {got.strip() == abc_in.strip()}")
PYEOF
then :; fi
echo "tokens     : $OUT_TOKENS"
echo "HOÀN TẤT."
