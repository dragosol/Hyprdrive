#!/usr/bin/env bash
# b057.sh: build against 0.57.2, summarise errors
cd "$(dirname "$0")"; source ./env057.sh
nice make -k -j12 hyprdrive.so > build.log 2>&1
echo "errors: $(grep -c 'error:' build.log)  failing files: $(grep -c '^make.*Error' build.log)  objects: $(ls .build/*.o 2>/dev/null | wc -l)"
grep "error:" build.log | sed -E 's/^[^ ]*: (fatal )?error: //' | sed -E "s/‘[^’]*’/X/g; s/[0-9]+/N/g" | cut -c1-90 | sort | uniq -c | sort -rn | head -${1:-25}
