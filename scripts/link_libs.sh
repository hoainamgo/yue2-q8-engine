#!/bin/bash
# Recreate SONAME symlinks for ggml libs next to this script (dataset uploads may drop symlinks).
cd "$(dirname "$0")"
for n in ggml ggml-base ggml-cpu ggml-cuda; do
  if [ -f "lib$n.so.0.27.0" ]; then
    ln -sf "lib$n.so.0.27.0" "lib$n.so.0"
    ln -sf "lib$n.so.0.27.0" "lib$n.so"
  fi
done
echo "links ok in $PWD"
