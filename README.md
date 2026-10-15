# 一生一芯 2607（Debian latest + Homebrew Verilator）

**重点：Verilator 不使用 Debian APT 版本！** Homebrew 安装在官方 Linux prefix `/home/linuxbrew/.linuxbrew`，在 `Docker build` 时以专用非 root 用户执行 `brew install --force-bottle verilator`，优先 Linux bottle（预编译 binary），并确保 `PATH` 中的 Homebrew `verilator` 优先于 `/usr/bin` 和可选 OSS CAD Suite。

Homebrew formula 2026-10-10 数据显示 Verilator **5.052**（同时间 Debian 13 APT 约为 **5.032**）；Homebrew 当前提供 `x86_64_linux` / `arm64_linux` bottles。版本随构建时 formula 更新，Dockerfile 不固定 Verilator patch version。

`git clone` 全部使用 `--depth=1`；官方 `ysyx-workbench/init.sh` 自带 `git clone --depth 1`，因此不改写上游脚本。

## 1. 构建

基础 E4 / E6：

```bash
docker build --progress=plain -t ysyx:2607 .
```

包含 E6/E8 更完整的 EDA 工具（x86_64，额外下载较大）：

```bash
docker build --platform=linux/amd64 --progress=plain \
  --build-arg WITH_EDA=1 -t ysyx:2607-full .
```

安装来源：

| Tool | Installation source |
| --- | --- |
| **Verilator** | **Homebrew Linux bottle**（默认），不是 apt/source build |
| GTKWave、Icarus、Yosys、Z3 | Debian binary packages |
| GCC/G++、Clang、GDB、QEMU、RISC-V Linux + ELF GCC | Debian binary packages |
| NVBoard 的 SDL2、image、ttf 开发依赖 | Debian binary packages |
| Python、NumPy、time、parallel、OpenJDK | Debian binary packages |
| Mill 1.1.0 | 官方 GitHub release executable |
| OSS CAD Suite、ECC、ECOS Studio | `WITH_EDA=1` 下载官方发布的 Linux binaries |
| ICsprout55 PDK | `WITH_EDA=1` shallow clone + 官方解包/patch |
| NEMU、AM、NPC、NVBoard | 在课程 workspace 使用官方 `init.sh` 初始化（学生源码应保持可编辑） |

`--force-bottle` 优先使用 bottle。在系统或网络条件不满足时，请通过 Docker build log 检查 Homebrew 是否真的使用了 bottle；若出现源码编译行为，应检查镜像架构、glibc、brew prefix 和 bottle 可用性，而不是回退到 Debian 的旧 Verilator。

## 2. 启动容器

Linux host：

```bash
mkdir -p "$HOME/ysyx-work"
docker run --rm -it \
  --user "$(id -u):$(id -g)" -e HOME=/workspace \
  -v "$HOME/ysyx-work:/workspace" \
  ysyx:2607
```

容器内部：

```bash
which verilator
verilator --version
# 应指向 /home/linuxbrew/.linuxbrew/bin/verilator

brew --version
brew list --versions verilator
riscv64-linux-gnu-gcc --version
riscv64-unknown-elf-gcc --version

# Git 账号需要自己配置，课程 init.sh 会自动创建跟踪 commits
git config --global user.name 'Your Name'
git config --global user.email 'you@example.com'
ysyx-setup --all
```

如只需要特定子工程：`ysyx-setup` 创建 workbench，之后执行 `cd "$YSYX_HOME"; bash init.sh nvboard` 等。

`ysyx-setup --chisel` 会调用官方 Chisel 初始化，但它会删除原 NPC starter：只在 `npc` 无本地修改和生成文件时允许执行。`mill` 在首次编译时从 Maven 下载 Chisel/Scala 依赖。推荐持久化用户的 cache 目录以避免重复下载。

## 3. GUI / EDA 说明

GTKWave、NVBoard 和 ECOS Studio 需要宿主机提供 X11/Wayland 图形转发，容器本身不会自动产生窗口。

`WITH_EDA=1` 是大型后端资源包，需要 linux/amd64、更多磁盘、GitHub release/PDK 下载访问；虽然尽量使用二进制，但 PDK 仍须执行自带的 unzip / patch。若出于工具版本冲突需要直接用 OSS CAD Suite 的 Verilator，可显式运行 `/opt/oss-cad-suite/bin/verilator`，默认命令 `verilator` 总是 Homebrew 版本。

## 4. 已检查及限制

- 已对生成的 `ysyx-setup` 执行 `bash -n` 静态检查，确认 Dockerfile 内的所有 `git clone` 都有 `--depth=1`。
- 当前执行环境没有 Docker daemon；**尚未实际完成 `docker build`**。Brew bottle、EDA binary 下载及版本兼容性需要在能访问网络的 Docker host 实测。
- 若未来 `debian:latest`、Homebrew formula、GitHub release assets 更改，可能需要固定版本或 SHA，尤其是可选的 EDA profile。

## 5. CI / Docker Hub（GitHub Actions）

`.github/workflows/docker.yml` 在 push 到 `main` 或打 `v*` tag 时自动构建 `linux/amd64` 基础镜像，在容器内执行冒烟测试（Verilator 路径必须为 Homebrew 安装、Mill、RISC-V gcc、yosys/iverilog/z3、`ysyx-setup` 初始化 workbench），通过后才推送到 Docker Hub：

| Tag | 说明 |
| --- | --- |
| `ovo-tim/ysyx:latest` | `main` 分支每次构建 |
| `ovo-tim/ysyx:sha-xxxxxxx` | 每次构建的 commit 标签 |
| `ovo-tim/ysyx:<vx.y.z>` | `v*` tag |
| `ovo-tim/ysyx:eda` / `:sha-xxxxxxx-eda` | `WITH_EDA=1` 完整 EDA 版，仅在 Actions 页手动触发并勾选 `with_eda` 时构建 |

必需的仓库 secrets（Settings → Secrets and variables → Actions）：

- `DOCKERHUB_USERNAME`：Docker Hub 用户名（如 `ovo-tim`）
- `DOCKERHUB_TOKEN`：Docker Hub → Account Settings → Security → New Access Token 生成的 token（Read/Write 权限）

PR 触发时只构建和测试，不推送。首次推送会自动在 Docker Hub 创建同名仓库。


### 参考

- [Homebrew Verilator formula](https://formulae.brew.sh/formula/verilator)
- [Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux)
- [YSYX 2607 E4](https://ysyx.oscc.cc/docs/2607/e/4.html)
- [YSYX workbench init.sh](https://github.com/OSCPU/ysyx-workbench/blob/master/init.sh)
