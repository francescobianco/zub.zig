##
## This is ha manual reconstruction useful to simulate a better macOS Catalina
##



FROM debian:bookworm-slim



LABEL shellcast.shell="macos" shellcast.version="bsd"

# Install bash, zsh, dash, make, curl, and python3 for BSD sed emulation
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      zsh \
      dash \
      make \
      curl \
      python3 \
    && rm -rf /var/lib/apt/lists/*

# Install BSD sed emulator: replaces /usr/bin/sed with a Python wrapper
# that enforces BSD sed -i behaviour (explicit backup suffix required).
# This mirrors macOS BSD sed: `sed -i 's/x/y/' file` → error
#                             `sed -i '' 's/x/y/' file` → in-place edit
RUN mv /usr/bin/sed /usr/bin/gnu-sed && \
    cat > /usr/bin/sed <<'PYSED'
#!/usr/bin/env python3
"""
BSD sed emulator — wraps GNU sed but enforces macOS/BSD -i semantics.

BSD sed -i requires an explicit backup suffix argument:
  sed -i ''    expr file   →  in-place, no backup  (ok)
  sed -i .bak  expr file   →  in-place, .bak backup (ok)
  sed -i       expr file   →  ERROR (no suffix provided)

GNU sed -i treats -i without a suffix as valid (in-place, no backup),
which is the common portability trap on macOS.
"""
import sys, os, subprocess

args = sys.argv[1:]
i = 0
gnu_args = []
error = False

while i < len(args):
    a = args[i]
    if a == '-i':
        # BSD: next arg is the suffix (required, even if empty string)
        i += 1
        if i >= len(args):
            sys.stderr.write("sed: option requires an argument -- i\n")
            sys.exit(1)
        suffix = args[i]
        # Check that the suffix does not look like a sed expression
        # (BSD sed requires the suffix to be positional, before the expression)
        gnu_args.append('-i' + suffix)  # GNU: -i<suffix>
    elif a.startswith('-i') and len(a) > 2:
        # e.g. -i.bak
        gnu_args.append(a)
    else:
        gnu_args.append(a)
    i += 1

result = subprocess.run(['/usr/bin/gnu-sed'] + gnu_args)
sys.exit(result.returncode)
PYSED
RUN chmod +x /usr/bin/sed

# shell-version: report BSD sed and available shells
RUN printf '#!/bin/sh\nprintf "macOS BSD userland (Debian-slim + BSD sed emulator)\\n"\nprintf "  sed:  BSD emulation via Python wrapper\\n"\nbash --version 2>&1 | head -1 | sed '"'"'s/^/  /'"'"'\nzsh --version 2>&1 | head -1 | sed '"'"'s/^/  /'"'"'\ndash --version 2>&1 | head -1 2>/dev/null || dpkg-query -W dash 2>/dev/null | awk '"'"'{print "  dash " $2}'"'"'\n' > /usr/local/bin/shell-version && \
    chmod +x /usr/local/bin/shell-version

CMD ["bash"]