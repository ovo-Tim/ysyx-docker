# syntax=docker/dockerfile:1.7
# 一生一芯 / ysyx 2607: Debian latest + Homebrew Verilator (Linux bottles)
# Four build variants: WITH_CHISEL x WITH_EDA. Build tools inside image.
#   docker build -t ysyx:2607 .                        # no Chisel, no EDA
#   docker build --build-arg WITH_CHISEL=1 -t ysyx:2607-chisel .
#   docker build --build-arg WITH_EDA=1 --platform=linux/amd64 -t ysyx:2607-eda .
#   docker build --build-arg WITH_CHISEL=1 --build-arg WITH_EDA=1 --platform=linux/amd64 -t ysyx:2607-full .
FROM debian:latest

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SHELL=/bin/bash \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_ENV_HINTS=1 \
    PATH=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/bin:/opt/oss-cad-suite/bin:${PATH}

ARG MILL_VERSION=1.1.0
ARG BUILD_JOBS=4
ARG NVBOARD_REF=master
ARG CHISEL_REF=master
ARG WITH_CHISEL=0
ARG WITH_EDA=0
ARG OSS_CAD_TAG=2026-10-13
ARG OSS_CAD_DATE=20261013
ARG ECC_TAG=v0.1.0-alpha.10
ARG ECOS_STUDIO_TAG=v0.1.0-alpha.9

# Install only Debian binary packages here. In particular: NO apt verilator.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget git git-lfs openssh-client sudo \
      bash bash-completion coreutils findutils diffutils file less sed grep gawk \
      make build-essential cmake ninja-build pkg-config util-linux bzip2 \
      perl python3 python-is-python3 python3-dev python3-pip python3-venv \
      python3-yaml python3-numpy \
      xz-utils zip unzip gzip tar patch rsync time parallel locales \
      gcc g++ clang clangd clang-format llvm lld \
      gdb gdb-multiarch valgrind strace ltrace ccache \
      zlib1g-dev liblz4-dev libreadline-dev libncurses-dev libelf-dev \
      libfdt-dev libglib2.0-dev libpixman-1-dev libgmp-dev libmpfr-dev \
      libmpc-dev libsystemc-dev \
      libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev \
      iverilog gtkwave yosys z3 graphviz \
      gcc-riscv64-linux-gnu g++-riscv64-linux-gnu \
      binutils-riscv64-linux-gnu libc6-dev-riscv64-cross \
      gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
      qemu-user qemu-system-misc \
      libfuse2t64 libnss3 libgbm1 libasound2t64 libx11-6; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

# Dedicated non-root login user with passwordless sudo; the container's
# default entry user.
RUN set -eux; \
    useradd --create-home --shell /bin/bash ysyx; \
    usermod -aG sudo ysyx; \
    echo 'ysyx ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/ysyx; \
    chmod 0440 /etc/sudoers.d/ysyx

# Homebrew's officially supported Linux prefix is essential for prebuilt bottles.
# Homebrew cannot run "brew install" as root. Use a dedicated brew-owned account.
# Shallow clone both the Homebrew repository and the project repositories.
RUN set -eux; \
    useradd --create-home --shell /bin/bash -K HOME_MODE=0711 linuxbrew; \
    install -d -o linuxbrew -g linuxbrew /home/linuxbrew/.linuxbrew; \
    runuser -u linuxbrew -- git clone --depth=1 \
      https://github.com/Homebrew/brew.git /home/linuxbrew/.linuxbrew/Homebrew; \
    runuser -u linuxbrew -- mkdir -p /home/linuxbrew/.linuxbrew/bin; \
    runuser -u linuxbrew -- ln -s ../Homebrew/bin/brew \
      /home/linuxbrew/.linuxbrew/bin/brew; \
    runuser -u linuxbrew -- /home/linuxbrew/.linuxbrew/bin/brew --version

# Always use the latest stable Homebrew Verilator Linux BOTTLE available at
# image-build time. --force-bottle prefers a precompiled package over source.
# Both x86_64_linux and arm64_linux bottles are published for the formula.
RUN set -eux; \
    runuser -u linuxbrew -- /home/linuxbrew/.linuxbrew/bin/brew install \
      --force-bottle verilator; \
    runuser -u linuxbrew -- /home/linuxbrew/.linuxbrew/bin/brew cleanup --prune=all; \
    rm -rf /home/linuxbrew/.cache/Homebrew; \
    command -v verilator; \
    test "$(command -v verilator)" = /home/linuxbrew/.linuxbrew/bin/verilator; \
    verilator --version; \
    runuser -u linuxbrew -- /home/linuxbrew/.linuxbrew/bin/brew list --versions verilator

# NVBoard is a C++ static library, not an apt binary. Compile it once here
# so an image contains a ready-to-use archive and all its source/include files.
# Only intermediates are discarded: do NOT delete nvboard.a.
RUN set -eux; \
    git clone --depth=1 --branch "${NVBOARD_REF}" \
      https://github.com/NJU-ProjectN/nvboard.git /opt/nvboard; \
    NVBOARD_HOME=/opt/nvboard make -C /opt/nvboard/example \
      -j "${BUILD_JOBS}" nvboard-archive; \
    test -s /opt/nvboard/build/nvboard.a; \
    install -m 0644 /opt/nvboard/build/nvboard.a /usr/local/lib/libnvboard.a; \
    rm -rf /opt/nvboard/.git /opt/nvboard/example/build; \
    find /opt/nvboard/build -type f \( -name '*.o' -o -name '*.d' \) -delete

# Do not set global XDG_CACHE_HOME before Homebrew's non-root installation.
# Chisel dependency caches, when enabled, survive in the final image so a
# new workspace does not have to redownload the entire Scala/Chisel toolchain.
ENV XDG_CACHE_HOME=/opt/ysyx-cache \
    COURSIER_CACHE=/opt/ysyx-cache/coursier

# Pre-create the writable cache root for non-root users in every variant:
# brew (linuxbrew) and runtime students must be able to write here.
RUN set -eux; \
    install -d -m 0777 "${XDG_CACHE_HOME}" "${COURSIER_CACHE}"

# Optional Chisel profile: install Java + Mill, then actually compile and test
# the official Chisel template at build time. Keep dependency caches and out/
# because those are reusable compiled artifacts, not throwaway temp files.
# This profile deliberately uses more image space than the plain Verilog one.
RUN set -eux; \
    if [[ "${WITH_CHISEL}" == 1 ]]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends openjdk-21-jdk-headless; \
      apt-get clean; \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb; \
      curl -fL --retry 5 --retry-all-errors \
        "https://repo1.maven.org/maven2/com/lihaoyi/mill-dist/${MILL_VERSION}/mill-dist-${MILL_VERSION}-mill.sh" \
        -o /usr/local/bin/mill; \
      chmod 0755 /usr/local/bin/mill; \
      mkdir -p "${XDG_CACHE_HOME}" "${COURSIER_CACHE}"; \
      git clone --depth=1 --branch "${CHISEL_REF}" \
        https://github.com/OSCPU/chisel-playground.git /opt/chisel-playground; \
      (cd /opt/chisel-playground && mill -i compile && mill -i test); \
      rm -rf /opt/chisel-playground/.git /opt/chisel-playground/.bsp; \
      find "${XDG_CACHE_HOME}" -type f \( -name '*.tmp' -o -name '*.part' -o -name '*.lock' \) -delete; \
      chmod -R a+rwX "${XDG_CACHE_HOME}"; \
      java -version; \
      mill --version; \
    fi

# Optional full E6/E8 back-end resources. These are precompiled binaries,
# except for the PDK's required unzip/patch (not C/C++ source compilation).
# ECC/ECOS Studio are currently distributed as linux-x86_64 executables.
RUN set -eux; \
    if [[ "${WITH_EDA}" == 1 ]]; then \
      if [[ "$(dpkg --print-architecture)" != amd64 ]]; then \
        echo 'WITH_EDA=1 currently needs linux/amd64' >&2; exit 1; \
      fi; \
      curl -fL --retry 5 --retry-all-errors \
        "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_TAG}/oss-cad-suite-linux-x64-${OSS_CAD_DATE}.tgz" \
        -o /tmp/oss-cad-suite.tgz; \
      tar -xzf /tmp/oss-cad-suite.tgz -C /opt; \
      test -x /opt/oss-cad-suite/bin/yosys; \
      rm -f /tmp/oss-cad-suite.tgz; \
      mkdir -p /opt/ecc; \
      curl -fL --retry 5 --retry-all-errors \
        "https://github.com/openecos-projects/ecc/releases/download/${ECC_TAG}/ecc-cli-linux-x86_64.tar.gz" \
        -o /tmp/ecc-cli.tar.gz; \
      tar -xzf /tmp/ecc-cli.tar.gz -C /opt/ecc; \
      test -x /opt/ecc/ecc; \
      ln -s /opt/ecc/ecc /usr/local/bin/ecc; \
      rm -f /tmp/ecc-cli.tar.gz; \
      curl -fL --retry 5 --retry-all-errors \
        "https://api.github.com/repos/openecos-projects/ecos-studio/releases/tags/${ECOS_STUDIO_TAG}" \
        -o /tmp/ecos-studio-release.json; \
      ecos_url="$(python3 -c 'import json; d=json.load(open("/tmp/ecos-studio-release.json")); a=[v["browser_download_url"] for v in d["assets"] if v["name"].endswith(".AppImage") and ("x86_64" in v["name"] or "amd64" in v["name"])]; assert len(a)==1, a; print(a[0])')"; \
      curl -fL --retry 5 --retry-all-errors "$ecos_url" -o /opt/ECOS-Studio.AppImage; \
      chmod 0755 /opt/ECOS-Studio.AppImage; \
      ln -s /opt/ECOS-Studio.AppImage /usr/local/bin/ecos-studio; \
      rm -f /tmp/ecos-studio-release.json; \
      git clone --depth=1 --branch unconfirmed \
        https://github.com/openecos-projects/icsprout55-pdk.git /opt/icsprout55-pdk; \
      git -C /opt/icsprout55-pdk lfs pull; \
      make -C /opt/icsprout55-pdk unzip; \
      (cd /opt/icsprout55-pdk/patch && bash patch.sh); \
      git -C /opt/icsprout55-pdk lfs prune; \
      rm -rf /opt/icsprout55-pdk/.git; \
    fi; \
    rm -f /tmp/oss-cad-suite.tgz /tmp/ecc-cli.tar.gz /tmp/ecos-studio-release.json

# Environment variables are available without sourcing a per-user shell rc.
# IMPORTANT: Homebrew/bin comes FIRST, before OSS CAD Suite and /usr/bin.
ENV ICS55_PDK=/opt/icsprout55-pdk \
    YSYX_HOME=/home/ysyx/ysyx-workbench \
    NEMU_HOME=/home/ysyx/ysyx-workbench/nemu \
    AM_HOME=/home/ysyx/ysyx-workbench/abstract-machine \
    NAVY_HOME=/home/ysyx/ysyx-workbench/navy-apps \
    NVBOARD_HOME=/home/ysyx/ysyx-workbench/nvboard \
    NPC_HOME=/home/ysyx/ysyx-workbench/npc \
    BENCH_HOME=/home/ysyx/ysyx-workbench/archbench

# Original init.sh performs shallow clones itself. Only copy the template in
# the image; call init.sh later within the student's mounted workspace.
RUN set -eux; \
    git clone --depth=1 --branch master \
      https://github.com/OSCPU/ysyx-workbench.git /opt/ysyx-workbench-template; \
    git config --system url."https://github.com/".insteadOf 'git@github.com:'; \
    test -s /usr/local/lib/libnvboard.a; \
    test "$(command -v verilator)" = /home/linuxbrew/.linuxbrew/bin/verilator; \
    riscv64-linux-gnu-gcc --version | head -n 1; \
    riscv64-unknown-elf-gcc --version | head -n 1

RUN <<'SCRIPT'
cat >/usr/local/bin/ysyx-setup <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
all=false
chisel=false
for arg in "$@"; do
  case "$arg" in
    --all) all=true ;;
    --chisel) chisel=true ;;
    -h|--help)
      echo 'Usage: ysyx-setup [--all] [--chisel]'
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

repo=/home/ysyx/ysyx-workbench
if [[ ! -e "$repo" ]]; then
  # cp -R, not cp -a: a bind-mounted /home/ysyx may belong to another uid; as
  # the non-root user we have created the copy with our own ownership.
  cp -R /opt/ysyx-workbench-template "$repo"
  echo "Initialized workbench at $repo"
elif [[ ! -d "$repo/.git" || ! -f "$repo/init.sh" ]]; then
  echo "ERROR: $repo exists and is not a workbench git repo" >&2
  exit 1
fi
cd "$repo"

if $all || $chisel; then
  if [[ -z "$(git config user.name || :)" || -z "$(git config user.email || :)" ]]; then
    echo 'Configure git user.name and user.email before running init.sh' >&2
    exit 1
  fi
fi

if $all; then
  for component in nemu abstract-machine am-kernels nanos-lite navy-apps \
    nvboard ysyxSoC riscv-tests riscv-arch-test archbench rt-thread; do
    bash init.sh "$component"
  done
  bash init.sh npc
fi

if $chisel; then
  if [[ ! -x /usr/local/bin/mill ]]; then
    echo 'This image was built without Chisel support (no mill/OpenJDK; only the chisel/full variants include it).' >&2
    echo 'Rebuild with --build-arg WITH_CHISEL=1 to enable Chisel.' >&2
    exit 1
  fi
  if [[ -d npc/playground ]]; then
    echo 'Chisel NPC already initialized'
  else
    if [[ -d npc && -n "$(git status --porcelain --untracked-files=all --ignored -- npc)" ]]; then
      echo 'Refusing to remove npc containing changes/untracked artifacts.' >&2
      exit 1
    fi
    # The upstream npc-chisel operation deletes the original npc directory.
    bash init.sh npc-chisel
  fi
fi
printf 'Workbench: %s\n' "$repo"
echo 'Precompiled NVBoard: /opt/nvboard (set NVBOARD_HOME=/opt/nvboard to use the prebuilt archive).' 
BASH
chmod 0755 /usr/local/bin/ysyx-setup
SCRIPT

# The container runs as the dedicated non-root user; ~/.workspaces live in
# /home/ysyx, and passwordless sudo is available for installation work.
WORKDIR /home/ysyx
USER ysyx
CMD ["/bin/bash"]
