# Giải pháp 2 — Build engine YuE2 Q8 một lần trên GitHub Actions

> Trạng thái: **tài sản đã chuẩn bị sẵn ở local, CHƯA đẩy lên GitHub.**
> Khi Noah hoàn tất đăng nhập GitHub, làm theo mục "Các bước còn lại" là chạy được ngay.

## Sơ đồ giải pháp

```
                 ┌──────────────────────────────────────────────┐
                 │  GitHub Actions (ubuntu-22.04, CUDA 12.8)    │
                 │  build yue2.cpp @ commit đã proven, sm_75    │
                 │  -> yue2-cpp-linux-x64-cuda12.tar.gz         │
                 └───────────────┬──────────────────────────────┘
                                 │  GitHub Release (binary ~68 MB)
              ┌──────────────────┴──────────────────┐
              ▼                                     ▼
     Colab (T4, phiên mới)                  Kaggle (T4, kernel mới)
     scripts/run_yue2_q8.sh                 scripts/run_yue2_q8.sh
       tải tarball + GGUF từ HF               tải tarball + GGUF từ HF
       -> render ~5-6 phút                    -> render ~5-6 phút

     Weights GGUF (4,34 GB) LUÔN tải từ HuggingFace Serveurperso/YuE2-GGUF
     — KHÔNG để lên GitHub vì file model 3,81 GB vượt giới hạn 2 GB/file
     của GitHub Release.
```

Vấn đề được giải quyết: trước đây mỗi phiên Colab/Kaggle phải **build engine
tại chỗ 22 phút (Kaggle, 4 nhân) tới 49 phút (Colab free, 2 nhân)** và Colab
free còn có rủi ro thu hồi phiên giữa chừng build. Giải pháp 2 tách khâu build
ra khỏi khâu chạy: build một lần trên GitHub Actions, mọi nền tảng chỉ tải
binary về (~1 phút) + tải weights (~1 phút) + render (~5–6 phút).

## Các file trong thư mục này

| File | Vai trò |
|---|---|
| `.github/workflows/build-yue2-cpp.yml` | Workflow build engine: trigger `workflow_dispatch` hoặc push tag `engine-v*`; cài CUDA 12.8 qua APT của NVIDIA trên `ubuntu-22.04`; build target `yue-synth`; đóng gói tarball + sha256; upload artifact; nếu là tag thì tạo GitHub Release. |
| `scripts/run_yue2_q8.sh` | Runner dùng chung Colab/Kaggle/máy bất kỳ: tải gói engine → kiểm sha256 → giải nén → tải GGUF (đúng repo/revision/file đã proven, kiểm cả dung lượng + sha256) → chạy `yue-synth` đúng lệnh + `LD_LIBRARY_PATH` của driver đã proven → hậu kiểm (ffprobe, sha256 FLAC, đối chiếu phổ nạp/xuất). |
| `scripts/link_libs.sh` | Script đã proven từ gói engine gốc: khôi phục symlink SONAME của libggml nếu khâu đóng gói/truyền file làm rớt. Workflow chép kèm vào tarball; runner tự chạy khi thấy file này. |
| `request_millroad.json` | Request nghiệm thu = **đúng raw bytes của request đã chạy thật** trên Kaggle + Colab (style/lyrics nguyên văn, `abc` = phổ fed, `cot="full"`, `lm_seed`/`seed` = 20261101, `steps=32`, `output_format="wav24"`). |
| `score_fed.abc` | Phổ nạp của bài nghiệm thu — bản sao của `out/DownTheOldMillRoad_score_fed.abc`; nội dung trường `abc` trong `request_millroad.json` khớp byte-for-byte với file này (2.714 ký tự). |

## Nguồn recipe (không tự chế)

- `~/workspace/yue2-engine-bin/yue2.cpp-t4/BUILD_INFO.md` — engine
  `ServeurpersoCom/yue2.cpp` commit `8af01740686824ffd4a1839a457954f42e2a8ce7`,
  ggml 0.27.0, cờ `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=75`, CUDA 12.8.
- `~/workspace/yue2-cover-test-20261101/kaggle_kernel_q8/kernel.py` — cách
  kernel build tại chỗ + chạy engine + kiểm dung lượng file.
- `~/workspace/yue2-cover-test-20261101/colab_q8/` — driver Colab đã chạy thật
  (build target `yue-synth`, `-j2`) + README ghi nguồn GGUF:
  HF `Serveurperso/YuE2-GGUF` revision `e630f2b8f6aedf8254c3186438633c1b5eeaf80a`,
  `YuE2-3B-Q8_0.gguf` (3.810.232.064 byte, sha256 `41121ce9…`) +
  `YuE2-Vae-F32.gguf` (530.497.344 byte, sha256 `93e49dfb…`).

## Các bước còn lại khi có GitHub

1. **Tạo repo** (private hay public đều được) rồi đẩy nguyên thư mục này lên:
   `git init && git add -A && git commit -m "yue2 gh-actions kit" && git remote add origin <url> && git push -u origin main`.
2. **Chạy workflow**: tab Actions → `build-yue2-cpp` → *Run workflow*
   (để trống ô engine_ref = dùng commit đã proven). Chờ build xong, tải
   artifact về kiểm tra nếu muốn. Lần build đầu cũng là lúc rà các điểm
   `# TODO-VERIFY` trong file workflow (xem mục dưới).
3. **Phát hành chính thức**: `git tag engine-v1.0.0 && git push origin engine-v1.0.0`
   → workflow tự tạo Release kèm `yue2-cpp-linux-x64-cuda12.tar.gz` +
   file `.tar.gz.sha256`.
4. **Điền vào runner**: mở `scripts/run_yue2_q8.sh`, điền
   `RELEASE_TARBALL_URL` = URL tải tarball trên Release vừa tạo và
   `RELEASE_TARBALL_SHA256` = nội dung file `.tar.gz.sha256`. Commit + push lại.
5. **Notebook v1.1 (Colab)**: rút gọn notebook Colab v1.0 thành bản
   "tải-về-chạy": ô tải `run_yue2_q8.sh` + `request_millroad.json` từ repo
   (raw URL hoặc git clone) rồi gọi script — thay cho ô build ~49 phút.
   Chưa làm ở lượt chuẩn bị này; làm ngay sau khi có URL Release thật.
6. **Nghiệm thu** theo mục dưới trên cả Colab và Kaggle, ghi kết quả vào
   REPORT của dự án `yue2-cover-test-20261101`.

## Tương thích (đã khóa trong workflow)

- **Runner `ubuntu-22.04`** (glibc 2.35): Colab và Kaggle đều dùng image
  Ubuntu 22.04 → một binary dùng chung. Không nâng lên 24.04 (glibc 2.39 sẽ
  làm binary không nạp được trên image 22.04).
- **CUDA 12.8 + `CMAKE_CUDA_ARCHITECTURES=75`**: đích là Tesla T4 (sm_75)
  của Colab/Kaggle free. Build không cần GPU (nvcc biên dịch device code;
  link dùng stub libcuda của toolkit — driver thật chỉ cần ở máy chạy).
- **`GGML_NATIVE=OFF`**: tắt `-march=native` để binary không dính instruction
  set riêng của CPU máy build. Đây là điểm khác duy nhất so với build proven
  (vốn để mặc định) — lý do có tiêu chí nghiệm thu phụ ở dưới.
- **GGUF để ở HuggingFace**, không lên GitHub Release (giới hạn 2 GB/file;
  file model 3,81 GB). Tarball engine chỉ ~68 MB (binary 847 KB + libggml-cuda
  ~64 MB + các lib phụ).
- Chạy engine **luôn kèm `LD_LIBRARY_PATH=<thư mục engine>`** vì `yue-synth`
  mang RUNPATH trỏ về thư mục build gốc (đã proven ở cả Kaggle và Colab).

## Bài kiểm nghiệm thu (bắt buộc, trên CẢ Colab và Kaggle)

Chạy `scripts/run_yue2_q8.sh` với `request_millroad.json` mặc định trên một
phiên/kernel MỚI TINH của từng nền tảng, rồi đối chiếu với bản chuẩn
(bản Kaggle gốc ngày 2026-11-01, chính request này):

| Tiêu chí | Bản chuẩn |
|---|---|
| sha256 FLAC | `7fdc8e2a8b02d265fd3e2d1d739905b2dcab3f0e7193b930e833c2fc51833a09` |
| Thời lượng | 229,358667s |
| EOS semantic | token 5.734 / 9.000 (kết thúc tự nhiên, không truncation) |
| Phổ engine xuất | khớp 100% phổ nạp (2.714/2.714 ký tự) |

- **Khớp cả 4** → khóa binary Release đó làm chuẩn cho mọi lượt chạy sau.
- **Nếu sha256 lệch** nhưng phổ xuất vẫn khớp 100%, thời lượng và EOS vẫn
  đúng → ghi nhận riêng là "binary GH build (GGML_NATIVE=OFF) cho audio khác
  byte nhưng cùng phổ/cấu trúc", kèm số đo thực tế, và báo Noah quyết có khóa
  chuẩn mới hay giữ binary Kaggle làm chuẩn. Không tự ý bỏ qua.
- Đo và ghi lại thời gian từng khâu (tải engine / tải GGUF / render) để đối
  chiếu với con số kỳ vọng ~10 phút/bài ở phiên mới.

## Điểm còn mở (TODO-VERIFY trong workflow)

1. **gcc của runner**: môi trường proven dùng gcc 13.3; image ubuntu-22.04
   mặc định gcc 11/12. Nếu nvcc phàn nàn host compiler → cài gcc-13 và truyền
   `-DCMAKE_CUDA_HOST_COMPILER` (đã ghi sẵn hướng xử lý trong workflow).
2. **Hai fix Kaggle** (fake `CUDAToolkit_ROOT` + sed `CUDA::cuda_driver`):
   trên GitHub runner (toolkit đầy đủ, có quyền ghi) khả năng cao không cần;
   nếu configure/link dính lỗi tương tự thì áp dụng nguyên văn theo BUILD_INFO
   (đã ghi sẵn trong workflow dạng comment).

## Nhật ký thực thi (2026-11-01)

Repo đã tạo: **https://github.com/hoainamgo/yue2-q8-engine** (public, chỉ chứa
code: `.github/`, `scripts/`, `README.md`, `.gitignore` —
`request_millroad.json` + `score_fed.abc` được giữ local bằng `.gitignore`,
không đưa lên repo công khai).

**Cả 3 lần chạy workflow đều bị chấm dứt từ bên ngoài ở bước Build** — không
phải lỗi code/workflow (Configure xanh, biên dịch đi tới 95%, đang biên dịch
`ggml-cuda`):

| Run | Bắt đầu build (UTC) | Bị ngắt (UTC) | Sau | Tiến độ |
|---|---|---|---|---|
| 41294175664 | 09:44:35 | 09:45:26 | ~51s | 95% |
| 41294563095 | 09:51:31 | 09:52:42 | ~71s | 95% |
| 41295053355 | 09:58:22 | 09:59:34 | ~72s | 95% |

Dấu hiệu giống hệt nhau cả 3 lần: log ghi `The runner has received a shutdown
signal` + `Process completed with exit code 143` (SIGTERM gửi cho runner),
không có một lỗi biên dịch nào trước đó. Tính đều đặn (ngắt trong ~1 phút đầu
của pha biên dịch nặng, 3/3 lần) cho thấy đây là **chấm dứt tự động từ phía
nền tảng/giám sát**, không phải hạ tầng lỗi ngẫu nhiên và không phải lỗi của
workflow. Đã DỪNG thử tiếp và không lách sang cơ chế khác (không upload binary
build sẵn thay thế, không đổi tên workflow/tách build) — chờ quyết định của
Noah: hoặc anh tự bấm chạy workflow từ giao diện GitHub của mình, hoặc bỏ
route GitHub Actions này.

Hệ quả: chưa có Release, nên các bước kiểm chứng Colab/Kaggle bằng binary
GitHub và đóng gói notebook v1.1 **chưa thực hiện được ở lượt này**. Mọi tài
sản (workflow, runner, request nghiệm thu) đã sẵn sàng; chỉ cần MỘT lần build
xanh là đi tiếp được ngay từ bước phát hành.

## Bản quyền

Engine yue2.cpp = MIT. Weights YuE2 = CC BY-NC 4.0 + Individual Creator
Permission (2026-09-16 — creator cá nhân được monetize output; công ty cần
license riêng).
