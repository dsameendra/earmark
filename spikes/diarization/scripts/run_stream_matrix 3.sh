#!/bin/zsh
# Serial streaming matrix. Feeds chunks as fast as possible; records max RSS / peak footprint via /usr/bin/time -l.
# For speed numbers later: run this alone on an idle machine and add `time` around each command (do not run in parallel).
set -u
cd "$(dirname "$0")/../../.."
P=spikes/diarization/.build/debug/diar-poc; A=.model-cache/datasets/ami/audio; R=spikes/diarization/results/stream
KINDS=(${=KINDS:-lseend-ami lseend-dihard3 sortformer-fastV2 sortformer-balancedV2 legacy}); MEETINGS=(${=MEETINGS:-ES2004a ES2004b IS1009a})
for k in $KINDS; do
  for m in $MEETINGS; do
    echo "## $k $m"
    /usr/bin/time -l $P stream $k $A/$m.Mix-Headset.wav --out $R --cache .model-cache 2>&1 | grep -E "finalized|maximum resident|peak memory|rror|Fatal"
  done
done
