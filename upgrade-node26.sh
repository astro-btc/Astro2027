#!/usr/bin/env bash
# Self-contained host launcher. All structured work runs inside the Node 26 image.
set -Eeuo pipefail
umask 077
SCRIPT_VERSION=v1
CONTAINER=astro-app
IMAGE=astrobtc/astro:3.3
BACKUP_BASE=/var/backups/astro-node26
ROLLBACK=
SKIP_PULL=0
CHECK=0
HEALTH_TIMEOUT=180
WORK=
RUN_PID=
log() { printf '[astro-node26] %s\n' "$*"; }
log "迁移脚本版本: $SCRIPT_VERSION"
die() { log "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<HELP
Usage: sudo bash upgrade-node26.sh [options]
使用 Node 26.12.1 新镜像重建 astro-app，恢复用户数据，保留旧容器。
目标镜像固定为 ${IMAGE}；原容器已使用 Node 26.x 时直接提示无需迁移。
只需要宿主机 Bash、Docker 和常用系统命令，无需安装其他语言运行时或 JSON 工具。
  --container NAME       原容器名（默认 astro-app）
  --backup-dir DIR       备份父目录（默认 /var/backups/astro-node26）
  --skip-pull            使用已下载的本地镜像
  --check                检查环境与镜像，不停止原容器
  --rollback BACKUP_DIR  切回备份对应的旧容器和旧数据
  --health-timeout SEC   服务健康等待秒数（30—1800，默认 180）
  -h, --help             显示帮助

迁移成功后可选择删除 home.tar、restore.tar 数据备份，回车默认保留。
非交互运行自动保留备份；旧容器、回滚记录和新容器数据不会被清理。
HELP
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container|--backup-dir|--rollback|--health-timeout)
      [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
      case "$1" in
        --container) CONTAINER=$2 ;;
        --backup-dir) BACKUP_BASE=$2 ;;
        --rollback) ROLLBACK=$2 ;; --health-timeout) HEALTH_TIMEOUT=$2 ;;
      esac
      shift 2 ;;
    --skip-pull) SKIP_PULL=1; shift ;; --check) CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;; *) die "Unknown argument: $1" ;;
  esac
done
[[ -z "$ROLLBACK" || "$CHECK" == 0 ]] || die '--check 与 --rollback 不能同时使用'
[[ "$(id -u)" == 0 ]] || die '请在 Docker 宿主机以 root 运行：sudo bash upgrade-node26.sh'
for name in docker mkdir mktemp dirname basename rm rmdir; do
  command -v "$name" >/dev/null || die "缺少系统命令: $name"
done
[[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$ ]] || die '非法容器名称'
[[ "$IMAGE" =~ ^[A-Za-z0-9][A-Za-z0-9_./:@-]+$ ]] || die '非法镜像名称'
[[ "$HEALTH_TIMEOUT" =~ ^[0-9]{2,4}$ ]] || die '健康检查超时需在 30—1800 秒之间'
((10#$HEALTH_TIMEOUT >= 30 && 10#$HEALTH_TIMEOUT <= 1800)) || die '健康检查超时需在 30—1800 秒之间'
HEALTH_TIMEOUT=$((10#$HEALTH_TIMEOUT))
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
SCRIPT="$SCRIPT_DIR/$(basename -- "$0")"
[[ -f "$SCRIPT" ]] || die '请把脚本保存为文件后运行，不支持 curl | bash'
docker info >/dev/null || die 'Docker daemon 不可用'
if [[ -n "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]]; then ENDPOINT=$DOCKER_HOST
else ENDPOINT=$(docker context inspect --format '{{.Endpoints.docker.Host}}'); fi
[[ "$ENDPOINT" == unix://* ]] || die '只支持 Docker 宿主机本地 Unix socket，不支持远程 context'
SOCKET=${ENDPOINT#unix://}
[[ -S "$SOCKET" ]] || die 'Docker Unix socket 不存在'
check_path() {
  [[ "$1" != *','* && "$1" != *':'* && "$1" != *$'\n'* && "$1" != *$'\r'* ]] ||
    die '目录不能包含逗号、冒号或换行'
}
check_path "$SCRIPT"; check_path "$SOCKET"
MOUNTS=()
if [[ -n "$ROLLBACK" ]]; then
  ROLLBACK=$(cd -- "$ROLLBACK" && pwd -P)
  check_path "$ROLLBACK"
  [[ -f "$ROLLBACK/state.json" ]] || die '缺少 state.json'
  if [[ -f "$ROLLBACK/recovery-name" ]]; then
    IFS= read -r CONTAINER < "$ROLLBACK/recovery-name"
  fi
  if [[ -f "$ROLLBACK/recovery-image" ]]; then
    IFS= read -r RECOVERY_IMAGE < "$ROLLBACK/recovery-image"
    [[ "$RECOVERY_IMAGE" =~ ^sha256:[0-9a-f]{64}$ ]] || die '备份中的镜像 ID 无效'
    IMAGE=$RECOVERY_IMAGE
    SKIP_PULL=1
  fi
  MOUNTS+=(--mount "type=bind,src=$ROLLBACK,dst=$ROLLBACK")
fi
[[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$ ]] || die '备份中的容器名称无效'
CONTROLLER="astro-node26-migrator-$CONTAINER"
if EXISTING=$(docker inspect --format '{{.Id}}' "$CONTROLLER" 2>/dev/null); then
  ROLE=$(docker inspect --format '{{index .Config.Labels "io.astro.migration.role"}}' "$EXISTING")
  OWNER=$(docker inspect --format '{{index .Config.Labels "io.astro.migration.container"}}' "$EXISTING")
  RUNNING=$(docker inspect --format '{{.State.Running}}' "$EXISTING")
  [[ "$ROLE" == controller && "$OWNER" == "$CONTAINER" && "$RUNNING" == false ]] ||
    die "迁移工具名称已被占用或迁移仍在运行: $CONTROLLER"
  docker rm "$EXISTING" >/dev/null
fi
if [[ -z "$ROLLBACK" ]]; then
  CURRENT_NODE=$(docker exec "$CONTAINER" node -p 'process.versions.node') ||
    die "无法读取容器 $CONTAINER 的 Node 版本，请确认容器正在运行且未暂停"
  if [[ "$CURRENT_NODE" == 26.* ]]; then
    log "容器 $CONTAINER 已使用 Node ${CURRENT_NODE}，无需迁移。"
    exit 0
  fi
  [[ "$CURRENT_NODE" == 23.* ]] || die "当前 Node ${CURRENT_NODE}，此脚本仅支持从 Node 23.x 迁移"
  check_path "$BACKUP_BASE"
  if ((CHECK == 0)); then
    mkdir -p -- "$BACKUP_BASE"
    BACKUP_BASE=$(cd -- "$BACKUP_BASE" && pwd -P)
    MOUNTS+=(--mount "type=bind,src=$BACKUP_BASE,dst=$BACKUP_BASE")
  fi
fi
if ((SKIP_PULL == 0)); then
  log "拉取 Node 26 镜像: $IMAGE"
  docker pull --platform linux/amd64 "$IMAGE"
fi
IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE") ||
  die '镜像不可用，请先下载指定的新镜像'
if [[ -n "$ROLLBACK" ]]; then
  log "准备回滚容器 ${CONTAINER}；使用备份记录: $ROLLBACK"
elif ((CHECK)); then
  log "仅检查容器 $CONTAINER 和新镜像，不停止服务、不迁移数据。"
else
  log "准备迁移容器: $CONTAINER → Node 26.12.1"
  log "备份父目录: $BACKUP_BASE"
  log '沿用原 .env 文件挂载；其他配置与数据恢复到新容器内部，不新增宿主机数据目录。'
  log '迁移包含停机；成功后请在面板确认配置，再手动启动交易核心。'
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/astro-node26-tools.XXXXXXXX")
WORK=$(cd -- "$WORK" && pwd -P)
check_path "$WORK"
cleanup() {
  local result=$?
  trap - EXIT
  [[ -z "$WORK" ]] || {
    rm -f -- "$WORK/controller.cjs" "$WORK/controller.cid"
    rmdir -- "$WORK" 2>/dev/null || true
  }
  exit "$result"
}
interrupt() {
  local signum=$1 code=$2 cid=
  trap '' INT TERM HUP
  if [[ -s "$WORK/controller.cid" ]]; then
    IFS= read -r cid < "$WORK/controller.cid" || true
    [[ -z "$cid" ]] || docker kill --signal "$signum" "$cid" >/dev/null 2>&1 || true
  elif [[ -n "$RUN_PID" ]]; then kill "-$signum" "$RUN_PID" 2>/dev/null || true; fi
  [[ -z "$RUN_PID" ]] || wait "$RUN_PID" || true
  exit "$code"
}
trap cleanup EXIT
trap 'interrupt SIGINT 130' INT
trap 'interrupt SIGTERM 143' TERM
trap 'interrupt SIGHUP 129' HUP
cat > "$WORK/controller.cjs" <<'JS_MIGRATION'
'use strict'
const fs = require('fs')
const path = require('path')
const http = require('http')
const crypto = require('crypto')
const readline = require('readline')
const { createRequire } = require('module')
const { pipeline } = require('stream/promises')
function loadTar(server = '/home/ubuntu/astro-server/package.json') {
    const fromServer = createRequire(server)
    try { return fromServer('tar-stream') } catch (error) { if (error.code !== 'MODULE_NOT_FOUND') throw error }
    // Older images may keep archiver's dependency nested instead of hoisting it.
    try { return createRequire(fromServer.resolve('archiver'))('tar-stream') }
    catch (error) { if (error.code !== 'MODULE_NOT_FOUND') throw error }
    return require('tar-stream') // Local development/test environment.
}
const tar = loadTar()
const NODE = '26.12.1'
const ROOT = '/home/ubuntu'
const DU_TIMEOUT = 10 * 60 * 1000
const ARCHIVE_IDLE_TIMEOUT = 3 * 60 * 1000
const SQLITE_TIMEOUT = 5 * 60 * 1000
const TREES = ['astro-core/config', 'astro-core/cache', 'astro-core/data', 'astro-core/logs',
    'astro-server/data', 'astro-server/cache', 'astro-server/logs']
const CONTROL_FILES = ['bn-btcu', 'bn-btcusd1', 'bn-ethu', 'bn-ethusd1', 'bn-bnbu', 'bn-bnbusd1']
const FILES = ['astro-server/.env', 'astro-core/strategy.json', 'astro-core/data.db',
    'astro-core/data.db-wal', 'astro-core/data.db-shm', 'astro-core/data.db-journal', ...CONTROL_FILES]
const STAGING = '.astro-node26-restore'
const RUNTIME_ENV = new Set(['PATH', 'NODE_VERSION', 'YARN_VERSION', 'PM2_HOME', 'HOME', 'HOSTNAME', 'NODE_ENV',
    'NODE_OPTIONS', 'NODE_PATH', 'LD_LIBRARY_PATH', 'LD_PRELOAD'])
const IMAGE_PROBE = '(' + function imageProbe() {
    const fs = require('fs'), assert = require('assert')
    assert.equal(process.versions.node, '26.12.1')
    assert.equal(process.platform, 'linux'); assert.equal(process.arch, 'x64')
    assert.notEqual(process.getuid(), 0, 'Astro image must run as a non-root user')
    const base = '/home/ubuntu/'
    for (const app of ['astro-core', 'astro-server']) {
        const p = require(base + app + '/package.json')
        assert.equal(p.engines.node, '26.12.1'); assert.equal(p.dependencies.bytenode, '1.7.0')
    }
    const b = require(base + 'astro-server/node_modules/bytenode')
    for (const [app, files] of Object.entries({
        'astro-server': ['src/main.jsc', 'bin/www.jsc', 'upgrade.jsc'],
        'astro-core': ['src/main.jsc', 'bin/www.jsc', 'src/monitor/index.jsc', 'src/3rd/lighter/index.jsc'],
    })) for (const file of files)
        assert.equal(typeof b.runBytecode(fs.readFileSync(base + app + '/' + file)), 'function', file)
    assert.deepEqual(require(base + 'ecosystem.config.cjs').apps.map(a => a.name), ['astro-server'])
    assert.equal(fs.existsSync(base + '.astro-node26-restore'), false, 'Image contains migration staging data')
    const D = require(base + 'astro-core/node_modules/better-sqlite3'), db = new D(':memory:')
    assert.equal(db.prepare('SELECT 1 AS ok').get().ok, 1); db.close()
    console.log(JSON.stringify({ uid: process.getuid(), gid: process.getgid(), node: process.versions.node,
        version: require(base + 'astro-server/package.json').version }))
}.toString() + ')()'
const OLD_PROBE = '(' + function oldProbe() {
    const fs = require('fs'), path = require('path')
    if (!process.versions.node.startsWith('23.')) throw Error('Current Node must be 23.x')
    fs.accessSync('/home/ubuntu/astro-server/.env', fs.constants.R_OK)
    process.loadEnvFile('/home/ubuntu/astro-server/.env')
    for (const name of ['SESSION_STORE_FILE', 'SSL_KEY_PATH', 'SSL_CERT_PATH']) {
        if (!process.env[name]) continue
        const p = path.resolve('/home/ubuntu/astro-server', process.env[name])
        if (!p.startsWith('/home/ubuntu/astro-server/data/')) throw Error(name + ' must be inside astro-server/data')
    }
    for (const p of ['/home/ubuntu/astro-server/.env', '/home/ubuntu/astro-core/strategy.json',
        '/home/ubuntu/astro-core/config/settings.json'])
        if (!fs.statSync(p).isFile()) throw Error('Missing ' + p)
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone
    if (!timezone) throw Error('Cannot determine the original container timezone')
    console.log(JSON.stringify({ node: process.versions.node, arch: process.arch, platform: process.platform,
        port: Number(process.env.PORT || 12321), timezone }))
}.toString() + ')()'
const HEALTH = '(' + function healthProbe() {
    const fs = require('fs'), net = require('net')
    if (process.versions.node !== process.argv[1]) process.exit(1)
    process.loadEnvFile('/home/ubuntu/astro-server/.env')
    const home = process.env.PM2_HOME || process.env.HOME + '/.pm2'
    if (!fs.existsSync(home + '/rpc.sock')) process.exit(1)
    const pm2 = require('/home/ubuntu/astro-server/node_modules/pm2')
    setTimeout(() => process.exit(1), 7000)
    // Connect only to the existing RPC socket: never launch a replacement daemon.
    pm2.Client.launchRPC(error => {
        if (error) process.exit(1)
        pm2.list((error, apps) => {
            pm2.disconnect()
            if (error || !Array.isArray(apps)) process.exit(1)
            if (!apps.some(a => a.name === 'astro-server' && a.pm2_env.status === 'online')) process.exit(1)
            if (process.argv[2] === '--core-stopped' &&
                apps.some(a => a.name === 'astro-core' && a.pm2_env.status === 'online')) process.exit(1)
            const s = net.connect({ host: '127.0.0.1', port: Number(process.env.PORT || 12321) })
            s.setTimeout(2000)
            s.on('connect', () => { s.end(); process.exit(0) })
            s.on('error', () => process.exit(1)); s.on('timeout', () => process.exit(1))
        })
    })
}.toString() + ')()'

function ensure(ok, message) { if (!ok) throw new Error(message) }
function log(message) { console.log('[astro-node26] ' + message) }
const DATA_PROBE = '(' + function runtimeDataProbe() {
    const fs = require('fs'), assert = require('assert')
    const base = '/home/ubuntu/'
    assert.equal(process.getuid(), Number(process.argv[1]), 'Unexpected runtime UID')
    for (const dir of ['astro-core', 'astro-core/config', 'astro-core/cache', 'astro-core/logs',
        'astro-server/data', 'astro-server/cache', 'astro-server/logs'])
        fs.accessSync(base + dir, fs.constants.R_OK | fs.constants.W_OK | fs.constants.X_OK)
    fs.accessSync(base + 'astro-server/.env', fs.constants.R_OK |
        (process.argv[2] === '--env-readonly' ? 0 : fs.constants.W_OK))
    for (const file of ['astro-core/strategy.json', 'astro-core/config/settings.json'])
        fs.accessSync(base + file, fs.constants.R_OK | fs.constants.W_OK)
    for (const file of ['astro-core/strategy.json', 'astro-core/config/settings.json'])
        JSON.parse(fs.readFileSync(base + file, 'utf8'))
    const file = base + 'astro-core/data.db'
    if (fs.existsSync(file)) {
        fs.accessSync(file, fs.constants.R_OK | fs.constants.W_OK)
        const D = require(base + 'astro-core/node_modules/better-sqlite3')
        const db = new D(file, { fileMustExist: true })
        try {
            // The cold data copy already passed quick_check before restoration.
            // Here verify this user's schema access and writable SQLite locking.
            db.prepare('SELECT name FROM sqlite_schema LIMIT 1').get()
            // Validate writable SQLite locking without changing any business rows.
            db.exec('BEGIN IMMEDIATE; ROLLBACK;')
        } finally { db.close() }
    }
}.toString() + ')()'
const ENV_PROBE = '(' + function envProbe() {
    const fs = require('fs'), file = '/home/ubuntu/astro-server/.env'
    try {
        if (process.argv[1] === 'fix') {
            const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK)
            try {
                const stat = fs.fstatSync(fd)
                if (!stat.isFile() || stat.nlink !== 1) throw Error('.env 不是独立的普通文件，停止权限修复')
                fs.fchownSync(fd, Number(process.argv[2]), Number(process.argv[3]))
                fs.fchmodSync(fd, 0o600)
            } finally { fs.closeSync(fd) }
            return
        }
        if (!fs.statSync(file).isFile()) throw Error('.env 不是普通文件')
        fs.accessSync(file, fs.constants.R_OK | (process.argv[1] === 'rw' ? fs.constants.W_OK : 0))
    } catch (error) {
        if (['EACCES', 'EPERM'].includes(error.code))
            console.error('权限不足（' + error.code + '），请调整原 .env 文件权限')
        else console.error((error.code ? error.code + ': ' : '') + error.message)
        process.exitCode = 1
    }
}.toString() + ')()'
// Docker exec has no kill endpoint. A private token identifies only this command;
// aborting HTTP alone would leave du/SQLite running in the container.
const EXEC_RUNNER = '(' + function execRunner() {
    const fs = require('fs'), { spawn } = require('child_process')
    const [file, command, ...args] = process.argv.slice(1), cancel = file + '.cancel'
    const clean = () => { for (const name of [file, cancel]) fs.rmSync(name, { force: true }) }
    if (fs.existsSync(cancel)) { clean(); return }
    let child, stopping = false
    const stop = () => {
        stopping = true
        if (child?.pid) try { process.kill(-child.pid, 'SIGTERM') } catch (error) { if (error.code !== 'ESRCH') throw error }
    }
    process.on('SIGTERM', stop)
    child = spawn(command, args, { detached: true, stdio: ['ignore', 'inherit', 'inherit'] })
    child.once('error', error => { clean(); console.error(error.message); process.exitCode = 1 })
    child.once('exit', code => { clean(); process.exitCode = stopping ? 130 : (code ?? 1) })
    if (child.pid) {
        try {
            fs.writeFileSync(file, String(process.pid), { flag: 'wx', mode: 0o600 })
            if (stopping || fs.existsSync(cancel)) stop()
        } catch (error) { stop(); console.error(error.message) }
    }
}.toString() + ')()'
const EXEC_CANCEL = '(' + function cancelExec() {
    const fs = require('fs'), file = process.argv[1]
    // Keep a cancellation marker if exec/start has not launched the runner yet.
    fs.writeFileSync(file + '.cancel', '', { mode: 0o600 })
    if (!fs.existsSync(file)) return
    const pid = Number(fs.readFileSync(file, 'utf8'))
    if (!Number.isInteger(pid) || pid <= 1) throw Error('无效的检查进程 PID')
    try {
        if (!fs.readFileSync('/proc/' + pid + '/cmdline', 'utf8').split('\0').includes(file))
            throw Error('检查进程身份不匹配，拒绝终止')
        process.kill(pid, 'SIGTERM')
    } catch (error) { if (!['ENOENT', 'ESRCH'].includes(error.code)) throw error }
}.toString() + ')()'
async function withProgress(message, action) {
    const progress = setInterval(() => log(message), 30000)
    try { return await action() } finally { clearInterval(progress) }
}
function checkDiskSpace(size, backup, statfs = fs.statfsSync) {
    // Overlay and bind mounts can have different device IDs but share one pool.
    // Reserve the combined worst case on each pool instead of assuming independence.
    const required = BigInt(size) * 4n + 512n * 1024n ** 2n
    for (const [directory, label] of [[backup, '备份盘'], ['/', 'Docker 容器可写层及临时数据盘']]) {
        const stat = statfs(directory, { bigint: true })
        ensure(stat.bavail * stat.bsize > required,
            label + '空间不足，保守需预留 ' + required.toString() + ' 字节: ' + directory)
    }
}
function shellQuote(value) { return "'" + value.replace(/'/g, "'\\''") + "'" }
function selected(name) { return FILES.includes(name) || TREES.some(p => name === p || name.startsWith(p + '/')) }
function archiveName(name) {
    ensure(!/[\x00-\x1f\\]/.test(name) && !name.startsWith('/'), '备份包含非法路径')
    const parts = name.split('/').filter(p => p && p !== '.')
    ensure(!parts.includes('..') && parts[0] === 'ubuntu', '备份路径越界: ' + name)
    return parts.slice(1).join('/')
}
function writeJSON(filename, value) {
    const temporary = filename + '.tmp'
    const fd = fs.openSync(temporary, 'w', 0o600)
    try { fs.writeFileSync(fd, JSON.stringify(value, null, 2) + '\n'); fs.fsyncSync(fd) }
    finally { fs.closeSync(fd) }
    fs.renameSync(temporary, filename)
    const dir = fs.openSync(path.dirname(filename), 'r')
    try { fs.fsyncSync(dir) } finally { fs.closeSync(dir) }
}
async function sha256(filename) {
    const hash = crypto.createHash('sha256')
    for await (const chunk of fs.createReadStream(filename)) hash.update(chunk)
    return hash.digest('hex')
}
async function extractData(archive, destination) {
    const seen = new Set(), extract = tar.extract()
    const pumping = pipeline(fs.createReadStream(archive), extract)
    pumping.catch(() => {})
    try {
        for await (const entry of extract) {
            const h = entry.header, name = archiveName(h.name)
            if (!selected(name)) { for await (const unused of entry) {} continue }
            ensure(!seen.has(name), '备份包含重复数据路径: ' + name); seen.add(name)
            ensure(['file', 'directory'].includes(h.type), '数据含符号链接/特殊文件，需要手动迁移: ' + name)
            const out = path.join(destination, name)
            if (h.type === 'directory') {
                fs.mkdirSync(out, { recursive: true, mode: 0o700 })
                for await (const unused of entry) {}
            } else {
                fs.mkdirSync(path.dirname(out), { recursive: true, mode: 0o700 })
                await pipeline(entry, fs.createWriteStream(out, { flags: 'wx', mode: 0o600 }))
                fs.utimesSync(out, h.mtime, h.mtime)
            }
        }
        await pumping
    } catch (error) { extract.destroy(error); await pumping.catch(() => {}); throw error }
    for (const name of ['astro-server/.env', 'astro-core/strategy.json', 'astro-core/config/settings.json'])
        ensure(fs.statSync(path.join(destination, name)).isFile(), '缺少必要用户数据: ' + name)
    ensure(['keys.json', 'keys.datav2'].some(n => fs.existsSync(path.join(destination, 'astro-core/config', n))),
        '缺少 keys.json / keys.datav2')
    for (const name of TREES) fs.mkdirSync(path.join(destination, name), { recursive: true, mode: 0o700 })
}
async function restoreArchive(data, output, uid, gid, envMounted = false) {
    const pack = tar.pack(), pumping = pipeline(pack, fs.createWriteStream(output, { flags: 'wx', mode: 0o600 }))
    pumping.catch(() => {})
    async function visit(directory, relative = '') {
        for (const name of fs.readdirSync(directory).sort()) {
            const rel = relative ? relative + '/' + name : name, file = path.join(directory, name)
            const s = fs.lstatSync(file)
            ensure(s.isDirectory() || s.isFile(), '恢复数据类型不支持: ' + rel)
            ensure(rel === 'astro-core' || rel === 'astro-server' || selected(rel), '恢复路径不在数据白名单: ' + rel)
            if (envMounted && rel === 'astro-server/.env') continue
            const header = { name: 'home/ubuntu/' + STAGING + '/' + rel, uid, gid, uname: '', gname: '',
                type: s.isDirectory() ? 'directory' : 'file', mode: s.isDirectory() ? 0o700 : 0o600,
                size: s.isFile() ? s.size : 0, mtime: s.mtime }
            if (s.isDirectory()) {
                await new Promise((resolve, reject) => pack.entry(header, e => e ? reject(e) : resolve()))
                await visit(file, rel)
            } else await pipeline(fs.createReadStream(file), pack.entry(header))
        }
    }
    try {
        await new Promise((resolve, reject) => pack.entry({ name: 'home/ubuntu/' + STAGING,
            type: 'directory', mode: 0o700, uid, gid, uname: '', gname: '' }, e => e ? reject(e) : resolve()))
        await visit(data); pack.finalize(); await pumping
    }
    catch (error) { pack.destroy(error); await pumping.catch(() => {}); throw error }
}
// Replace complete data directories before the application starts. In particular,
// image-provided keys.json must not survive beside the user's keys.datav2.
const RESTORE_DATA = '(' + function installRestoredData(trees, files, staging) {
    const fs = require('fs'), path = require('path'), root = process.argv[1], source = path.join(root, staging)
    if (!fs.existsSync(source)) return // Later restarts keep the current live data.
    for (const name of trees) {
        const from = path.join(source, name), to = path.join(root, name)
        if (!fs.existsSync(from)) continue // Also permits resuming an interrupted first start.
        fs.rmSync(to, { recursive: true, force: true })
        fs.renameSync(from, to)
    }
    for (const name of files) {
        const from = path.join(source, name)
        if (fs.existsSync(from)) fs.renameSync(from, path.join(root, name))
    }
    fs.rmSync(source, { recursive: true })
}.toString() + ')(' + [TREES, FILES, STAGING].map(v => JSON.stringify(v)).join(',') + ')'
function restoredCommand(command) {
    return { Entrypoint: ['/bin/sh', '-c'], Cmd: ['node -e "$1" "$2" && shift 2 && exec "$@"',
        'astro-node26-restore', RESTORE_DATA, ROOT, ...command] }
}
function publishedPorts(old) {
    const ports = JSON.parse(JSON.stringify(old.HostConfig.PortBindings || {}))
    const actual = old.NetworkSettings.Ports || {}
    for (const [port, bindings] of Object.entries(ports)) for (const binding of bindings || []) {
        if (binding.HostPort && binding.HostPort !== '0') continue
        const ip = binding.HostIp || ''
        const matches = (actual[port] || []).filter(v => ip ? v.HostIp === ip : ['', '0.0.0.0', '::'].includes(v.HostIp))
        const assigned = new Set(matches.map(v => v.HostPort))
        ensure(assigned.size === 1, '无法确定现有容器的动态端口（IPv4/IPv6 不一致或映射缺失）: ' + port)
        binding.HostPort = [...assigned][0]
        ensure(/^\d+$/.test(binding.HostPort) && +binding.HostPort > 0 && +binding.HostPort <= 65535, '现有动态端口无效')
    }
    if (old.HostConfig.PublishAllPorts) for (const [port, bindings] of Object.entries(actual)) {
        if (ports[port]?.length || !bindings?.length) continue
        ports[port] = bindings.map(v => ({ HostIp: v.HostIp, HostPort: v.HostPort }))
    }
    return ports
}
function oldOptions(old) {
    const h = old.HostConfig, config = old.Config, networks = old.NetworkSettings.Networks || {}
    ensure(!h.Privileged && !h.ReadonlyRootfs, '不支持 privileged / 只读根文件系统容器')
    for (const key of ['Devices', 'DeviceRequests', 'VolumesFrom', 'Links', 'CapAdd', 'CapDrop', 'SecurityOpt', 'Tmpfs'])
        ensure(!h[key] || (Array.isArray(h[key]) ? !h[key].length : !Object.keys(h[key]).length),
            '存在自定义 Docker 设置，需要手动适配: ' + key)
    for (const key of ['BlkioWeight', 'BlkioWeightDevice', 'BlkioDeviceReadBps', 'BlkioDeviceWriteBps',
        'BlkioDeviceReadIOps', 'BlkioDeviceWriteIOps', 'StorageOpt', 'CgroupParent', 'UsernsMode', 'GroupAdd',
        'CpuPeriod', 'CpuRealtimePeriod', 'CpuRealtimeRuntime', 'CpusetMems']) {
        const value = h[key]
        ensure(!value || (typeof value === 'object' && !Object.keys(value).length),
            '存在自定义 Docker 设置，需要手动适配: ' + key)
    }
    ensure(!h.Runtime || ['runc', 'io.containerd.runc.v2'].includes(h.Runtime), '自定义 Runtime 需要手动迁移: ' + h.Runtime)
    ensure(!h.UTSMode, '共享 UTS namespace 需要手动迁移')
    ensure(!h.PidMode && ['', 'private'].includes(h.IpcMode || ''), '不支持共享 PID / IPC namespace')
    const network = h.NetworkMode || 'bridge'
    ensure(!network.startsWith('container:') && network !== 'none', '不支持此网络模式: ' + network)
    ensure(Object.keys(networks).length <= 1, '多网络容器需要手动迁移')
    for (const settings of Object.values(networks)) {
        ensure(!settings.IPAMConfig && !settings.Aliases?.length, '固定 IP / 网络别名需要手动迁移')
        ensure(!Object.keys(settings.DriverOpts || {}).length, '自定义网络驱动参数需要手动迁移')
    }
    const mounts = old.Mounts || [], envTarget = ROOT + '/astro-server/.env'
    ensure(mounts.length <= 1, '仅支持原 .env 文件挂载，其他挂载需要手动迁移')
    const envMount = mounts[0]
    if (envMount) {
        ensure(envMount.Destination === envTarget && envMount.Type === 'bind' && path.isAbsolute(envMount.Source || ''),
            '仅支持原 .env 文件的 bind 挂载，其他挂载需要手动迁移')
        ensure(typeof envMount.RW === 'boolean', '无法确定原 .env 挂载的读写模式')
    }
    const host = { NetworkMode: network, RestartPolicy: { Name: 'no', MaximumRetryCount: 0 },
        LogConfig: { Type: 'json-file', Config: { 'max-size': '20m', 'max-file': '3' } },
        PortBindings: publishedPorts(old), PublishAllPorts: !!h.PublishAllPorts }
    if (envMount) {
        // Retain the original -v / --mount definition, including ro/rw and SELinux options.
        if (h.Binds?.length) host.Binds = [...h.Binds]
        else if (h.Mounts?.length) host.Mounts = JSON.parse(JSON.stringify(h.Mounts))
        else host.Mounts = [{ Type: 'bind', Source: envMount.Source, Target: envTarget,
            ReadOnly: !envMount.RW, BindOptions: { Propagation: envMount.Propagation || 'rprivate' } }]
    }
    for (const key of ['ExtraHosts', 'Dns', 'DnsSearch', 'Memory', 'MemorySwap', 'PidsLimit',
        'ShmSize', 'NanoCpus', 'CpuShares', 'Sysctls', 'Ulimits', 'Init', 'Runtime']) if (h[key] != null) host[key] = h[key]
    ensure(!h.CpuQuota && !h.CpusetCpus, '自定义 CPU 配额需要手动迁移')
    const environment = (config.Env || []).filter(entry => {
        ensure(!/[\n\r\x00]/.test(entry), '环境变量含换行，需手动迁移')
        return !RUNTIME_ENV.has(entry.split('=', 1)[0])
    })
    const [networkName, endpoint] = Object.entries(networks)[0] || []
    const macAddress = config.MacAddress || endpoint?.MacAddress || ''
    ensure(!macAddress || /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(macAddress), '原 MAC 地址无效')
    return { host, environment, macAddress, networkName, envMount,
        restart: h.RestartPolicy || { Name: 'no', MaximumRetryCount: 0 } }
}
function demux(buffer) {
    let offset = 0, stdout = [], stderr = []
    while (offset < buffer.length) {
        ensure(offset + 8 <= buffer.length && [0, 1, 2].includes(buffer[offset]), 'Docker 输出格式错误')
        const type = buffer[offset], size = buffer.readUInt32BE(offset + 4); offset += 8
        ensure(offset + size <= buffer.length, 'Docker 输出被截断')
        ;(type === 2 ? stderr : stdout).push(buffer.subarray(offset, offset + size)); offset += size
    }
    return { stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString() }
}
class Docker {
    constructor(socketPath = '/migration/docker.sock') { this.socketPath = socketPath; this.version = '' }
    async raw(method, route, { body, headers = {}, stream = false, timeout = 120000, signal } = {}) {
        let failure, incoming
        const response = await new Promise((resolve, reject) => {
            const req = http.request({ socketPath: this.socketPath, method, path: this.version + route, headers, signal },
                response => { incoming = response; resolve(response) })
            const fail = error => {
                failure ||= error
                body?.destroy?.(error); incoming?.destroy(error); reject(error)
            }
            req.once('error', fail)
            req.setTimeout(timeout, () => {
                const error = new Error('Docker 请求超时')
                // Hijacked exec streams may otherwise report a clean EOF on timeout.
                fail(error); req.destroy(error)
            })
            if (body?.pipe) { body.once('error', e => req.destroy(e)); body.pipe(req) }
            else req.end(body)
        })
        if (response.statusCode >= 400) {
            const chunks = []
            for await (const b of response) chunks.push(b)
            let message = Buffer.concat(chunks).toString()
            try { message = JSON.parse(message).message } catch {}
            const error = new Error('Docker 操作失败: ' + message); error.statusCode = response.statusCode
            throw error
        }
        if (stream) return response
        const chunks = []; let size = 0
        for await (const b of response) {
            size += b.length; ensure(size <= 32 * 1024 * 1024, 'Docker 输出超过限制'); chunks.push(b)
        }
        if (failure) throw failure
        return Buffer.concat(chunks)
    }
    async json(method, route, value, options = {}) {
        const body = value === undefined ? undefined : Buffer.from(JSON.stringify(value))
        const buffer = await this.raw(method, route, { ...options, body,
            headers: body ? { 'Content-Type': 'application/json', 'Content-Length': body.length } : {} })
        return buffer.length ? JSON.parse(buffer.toString()) : null
    }
    async init() {
        const v = await this.json('GET', '/version')
        ensure(/^1\.\d+$/.test(v.ApiVersion), '无法确定 Docker Engine API 版本')
        this.version = '/v' + v.ApiVersion
        return this.json('GET', '/info')
    }
    inspect(id) { return this.json('GET', '/containers/' + encodeURIComponent(id) + '/json') }
    async optional(id) { try { return await this.inspect(id) } catch (e) { if (e.statusCode === 404) return null; throw e } }
    create(name, config) {
        return this.json('POST', '/containers/create' + (name ? '?name=' + encodeURIComponent(name) : ''), config)
    }
    start(id) { return this.json('POST', '/containers/' + id + '/start') }
    stop(id) { return this.json('POST', '/containers/' + id + '/stop?t=60') }
    rename(id, name) { return this.json('POST', '/containers/' + id + '/rename?name=' + encodeURIComponent(name)) }
    update(id, restart) { return this.json('POST', '/containers/' + id + '/update', { RestartPolicy: restart }) }
    async exec(id, cmd, user = '', timeout = 120000, { signal } = {}) {
        signal?.throwIfAborted()
        const token = signal ? '/tmp/astro-node26-exec-' + crypto.randomBytes(16).toString('hex') : null
        const execution = await this.json('POST', '/containers/' + id + '/exec',
            { Cmd: token ? ['node', '-e', EXEC_RUNNER, token, ...cmd] : cmd, User: user, AttachStdout: true, AttachStderr: true },
            { signal })
        let output
        try {
            output = demux(await this.raw('POST', '/exec/' + execution.Id + '/start', {
                body: Buffer.from('{"Detach":false,"Tty":false}'), timeout, signal, headers: { 'Content-Type': 'application/json' } }))
            // A cancelled hijacked Docker stream can end without throwing.
            signal?.throwIfAborted()
        } catch (error) {
            if (token) {
                try { await this.exec(id, ['node', '-e', EXEC_CANCEL, token], user, 10000) }
                catch (cancelError) { log('未能确认本次后台检查已停止: ' + cancelError.message) }
            }
            throw error
        }
        const result = await this.json('GET', '/exec/' + execution.Id + '/json')
        ensure(!result.Running && result.ExitCode === 0,
            '容器命令失败（exitCode=' + result.ExitCode + ', running=' + result.Running + '）: ' + output.stderr.trim())
        return output.stdout
    }
    async probe(image, cmd, { Binds, Mounts, User } = {}) {
        // A preflight must not relabel a host file still used by the old service.
        ensure(!Binds?.some(bind => bind.split(':').at(-1).split(',').some(mode => mode === 'z' || mode === 'Z')),
            '.env 挂载含 SELinux 自动重标记选项（z/Z），需要手动适配，原容器未停止')
        const created = await this.create('', { Image: image, Entrypoint: ['node'], Cmd: cmd, User,
            HostConfig: { NetworkMode: 'none', Binds, Mounts }, Healthcheck: { Test: ['NONE'] },
            Labels: { 'io.astro.migration.role': 'probe' } })
        try {
            await this.start(created.Id)
            const result = await this.json('POST', '/containers/' + created.Id + '/wait?condition=not-running')
            const output = demux(await this.raw('GET', '/containers/' + created.Id + '/logs?stdout=1&stderr=1'))
            ensure(result.StatusCode === 0, '镜像检查失败: ' + output.stderr.trim())
            return output.stdout
        } finally { await this.json('DELETE', '/containers/' + created.Id + '?force=1').catch(() => {}) }
    }
}
function validateData(data, uid, gid) {
    function fix(file) {
        const s = fs.lstatSync(file)
        ensure(s.isFile() || s.isDirectory(), '数据含符号链接/特殊文件: ' + file)
        if (s.isDirectory()) for (const name of fs.readdirSync(file)) fix(path.join(file, name))
        fs.chownSync(file, uid, gid); fs.chmodSync(file, s.isDirectory() ? 0o700 : 0o600)
    }
    fix(data)
    for (const name of ['astro-core/config/settings.json', 'astro-core/strategy.json']) {
        try { JSON.parse(fs.readFileSync(path.join(data, name), 'utf8')) }
        catch { throw new Error('Invalid JSON in ' + name) }
    }
    const file = path.join(data, 'astro-core/data.db')
    if (fs.existsSync(file)) {
        const Database = require('/home/ubuntu/astro-core/node_modules/better-sqlite3')
        const db = new Database(file, { fileMustExist: true })
        try { ensure(JSON.stringify(db.pragma('quick_check')) === '[{"quick_check":"ok"}]', 'SQLite quick_check 失败') }
        finally { db.close() }
        fix(path.join(data, 'astro-core'))
    }
}
class Migration {
    constructor(args, api) {
        this.args = args; this.api = api; this.state = {}; this.changed = false
        this.interrupted = false; this.recovering = false; this.abortController = new AbortController()
    }
    checkSignal() { ensure(!this.interrupted || this.recovering, '收到中断信号') }
    interrupt() {
        this.interrupted = true
        this.abortController.abort(Error('收到中断信号'))
    }
    async longExec(id, cmd, user, timeout, message) {
        this.checkSignal()
        const output = await withProgress(message, () => this.api.exec(id, cmd, user, timeout,
            { signal: this.abortController.signal }))
        this.checkSignal()
        return output
    }
    async exportArchive(id, file) {
        this.checkSignal()
        await withProgress('仍在导出完整备份，旧容器保持停止，请稍候…', async () => {
            const signal = this.abortController.signal
            await pipeline(await this.api.raw('GET', '/containers/' + id + '/archive?path=' + encodeURIComponent(ROOT),
                { stream: true, timeout: ARCHIVE_IDLE_TIMEOUT, signal }),
            fs.createWriteStream(file, { flags: 'wx', mode: 0o600 }), { signal })
        })
        this.checkSignal()
    }
    async checkEnv(image, options, info) {
        if (!options.envMount) return
        log('沿用原 .env 挂载: ' + options.envMount.Source + (options.envMount.RW ? '（读写）' : '（只读）'))
        try {
            // Test the original host mount in the target image as its default user.
            // Old root-owned application directories may legitimately be mode 0700.
            const check = () => this.api.probe(image, ['-e', ENV_PROBE, options.envMount.RW ? 'rw' : 'ro'], options.host)
            try { await check() }
            catch (error) {
                if (this.args.check || !/权限不足（(?:EACCES|EPERM)）/.test(error.message)) throw error
                log('仅修复原 .env 文件权限: ' + options.envMount.Source + ' → ' + info.uid + ':' + info.gid + ' / 600')
                await this.api.probe(image, ['-e', ENV_PROBE, 'fix', String(info.uid), String(info.gid)], {
                    User: '0', Mounts: [{ Type: 'bind', Source: options.envMount.Source,
                        Target: ROOT + '/astro-server/.env', ReadOnly: false }],
                })
                await check()
                log('.env 文件权限修复并检查通过，文件内容及原挂载方式保持不变。')
            }
        } catch (error) {
            throw Error('原 .env 挂载预检查失败（UID/GID ' + info.uid + '/' + info.gid +
                '，源文件 ' + options.envMount.Source + '）: ' + error.message)
        }
    }
    save(phase) {
        if (phase) this.state.phase = phase
        writeJSON(path.join(this.backup, 'state.json'), this.state)
    }
    deleteBackupArchives() {
        ensure(this.state.phase === 'complete', '只能清理迁移成功后的数据备份')
        // Delete only these two regular files. Never recursively remove a directory.
        const archives = ['home.tar', 'restore.tar'].map(name => path.join(this.backup, name))
        for (const file of archives) {
            const stat = fs.lstatSync(file)
            ensure(stat.isFile() && stat.nlink === 1, '备份归档类型异常，停止清理: ' + file)
        }
        this.state.backup_cleanup = 'deleting'; this.save()
        for (const file of archives) fs.unlinkSync(file)
        this.state.backup_cleanup = 'deleted'
        this.state.backup_deleted_at = new Date().toISOString(); this.save()
    }
    async offerBackupCleanup(input = process.stdin, output = process.stdout) {
        log('数据备份目录: ' + this.backup)
        if (this.state.env_mount) log('沿用原 .env 挂载文件（不可删除）: ' + this.state.env_mount.Source)
        else log('原容器未挂载 .env，新容器的 .env 也保存在容器内部。')
        log('astro-server/data、astro-core/config、数据库、策略、缓存和日志均保存在新容器内部。')
        log('未新增宿主机数据挂载目录；后续完整备份请包含容器内当前数据及原 .env 挂载文件。')
        log('删除或重建容器前必须另行备份；此处归档仅保存迁移时的数据。')
        log('可清理的数据备份: home.tar（完整旧目录）、restore.tar（恢复用数据）。')
        log('删除后无法使用这两份归档进行人工恢复；仍可通过保留的旧容器回滚。')
        if (!this.args.interactive || this.interrupted) {
            log('未进行交互选择，已自动保留全部数据备份: ' + this.backup); return
        }
        try {
            const answer = await new Promise(resolve => {
                const prompt = readline.createInterface({ input, output, terminal: false })
                this.cleanupPrompt = prompt
                prompt.once('line', resolve)
                prompt.once('close', () => resolve(''))
                prompt.once('error', () => resolve(''))
                output.write('[astro-node26] 是否删除上述两份数据备份？[y/N]（回车保留）: ')
            })
            this.cleanupPrompt.close(); this.cleanupPrompt = null
            output.write('\n')
            if (this.interrupted || !/^(y|yes)$/i.test(answer.trim())) {
                log('已保留全部数据备份: ' + this.backup); return
            }
            this.deleteBackupArchives()
            log('已删除 home.tar、restore.tar；回滚记录仍保留在: ' + this.backup)
            log('旧容器及新容器正在使用的数据均未删除。')
        } catch (error) {
            this.cleanupPrompt?.close(); this.cleanupPrompt = null
            log('备份清理未完成: ' + error.message)
            log('迁移已成功，未删除的归档和回滚记录保留在: ' + this.backup)
        }
    }
    async healthy(id, node = NODE, coreStopped = true) {
        const deadline = Date.now() + this.args.healthTimeout * 1000; let good = 0
        while (Date.now() < deadline) {
            this.checkSignal()
            if (!(await this.api.inspect(id)).State.Running) return false
            try {
                await this.api.exec(id, ['node', '-e', HEALTH, node, coreStopped ? '--core-stopped' : '--allow-core'])
                if (++good >= 6) return true
            } catch { good = 0 }
            await new Promise(resolve => setTimeout(resolve, 3000))
        }
        return false
    }
    async rollback() {
        const s = this.state, api = this.api
        ensure(s.endpoint === this.args.endpoint, 'Docker context 与备份不一致')
        ensure(!s.daemon_id || s.daemon_id === this.daemonID, 'Docker daemon 与备份不一致')
        const old = await api.inspect(s.old_id)
        ensure(old.Image === s.old_image, '旧容器身份与备份不一致')
        const current = await api.optional(s.name)
        if (current && current.Id !== old.Id) {
            ensure(current.Config.Labels?.['io.astro.migration.id'] === s.migration_id,
                '原容器名称被无关容器占用，拒绝回滚')
            await api.update(current.Id, { Name: 'no', MaximumRetryCount: 0 }); await api.stop(current.Id)
            await api.rename(current.Id, s.failed_name); log('新容器已停止保留: ' + s.failed_name)
        } else {
            const next = await api.optional(s.new_name)
            if (next) {
                ensure(next.Config.Labels?.['io.astro.migration.id'] === s.migration_id, '新容器名称被其他容器占用')
                await api.update(next.Id, { Name: 'no', MaximumRetryCount: 0 }); await api.stop(next.Id)
            }
        }
        if (old.Name.slice(1) !== s.name) await api.rename(old.Id, s.name)
        // Format 1 was the unpublished host-runtime implementation.
        const restart = typeof s.restart === 'string'
            ? { Name: s.restart.split(':')[0], MaximumRetryCount: Number(s.restart.split(':')[1] || 0) } : s.restart
        await api.update(old.Id, restart); await api.start(old.Id)
        ensure(await this.healthy(old.Id, s.old_node, false), '旧容器服务检查失败，请检查其日志')
        this.save('rolled_back'); this.changed = false
        log('已恢复旧容器及原重启策略；备份记录已保留，请检查交易核心状态。')
        const dynamicPorts = old.HostConfig?.PublishAllPorts || Object.values(old.HostConfig?.PortBindings || {})
            .some(bindings => (bindings || []).some(b => !b.HostPort || b.HostPort === '0'))
        if (dynamicPorts) {
            try {
                const restored = await api.inspect(old.Id)
                const ports = Object.entries(restored.NetworkSettings.Ports || {}).flatMap(([port, bindings]) =>
                    (bindings || []).map(b => (b.HostIp.includes(':') ? '[' + b.HostIp + ']' : b.HostIp) + ':' + b.HostPort + ' → ' + port))
                log('旧容器的随机发布端口由 Docker 在重启时分配，请按当前映射访问: ' + ports.join(', '))
            } catch { log('旧服务已恢复；随机端口可能已变化，请运行 docker port ' + shellQuote(s.name) + ' 查看当前映射。') }
        }
    }
    async run() {
        const a = this.args, api = this.api
        this.daemonID = (await api.init()).ID
        if (a.rollback) {
            this.backup = a.rollback
            this.state = JSON.parse(fs.readFileSync(path.join(this.backup, 'state.json'), 'utf8'))
            ensure([1, 2].includes(this.state.format) && this.state.name === a.container, '备份格式或容器名称不一致')
            log('回滚会切回迁移前的旧容器和旧数据；新数据副本仍会保留。')
            this.recovering = true; await this.rollback(); return
        }
        const old = await api.inspect(a.container)
        ensure(old.State.Running && !old.State.Paused, '旧容器必须处于运行状态')
        // Recheck inside the controller in case the runtime changed after the host preflight.
        const currentNode = (await api.exec(old.Id, ['node', '-p', 'process.versions.node'])).trim()
        if (currentNode.startsWith('26.')) {
            log('容器 ' + a.container + ' 已使用 Node ' + currentNode + '，无需迁移。'); return
        }
        ensure(currentNode.startsWith('23.'), '此脚本仅支持从 Node 23.x 迁移，当前为 ' + currentNode)
        log('[1/6] 检查原容器的配置、Node 版本和服务状态')
        const options = oldOptions(old)
        const probe = JSON.parse(await api.exec(old.Id, ['node', '-e', OLD_PROBE]))
        ensure(probe.platform === 'linux' && probe.arch === 'x64', '只支持 Linux x64 Astro 容器')
        ensure(Number.isInteger(probe.port) && probe.port > 0 && probe.port <= 65535, '原服务端口无效')
        options.environment = options.environment.filter(e => !e.startsWith('PORT=')).concat('PORT=' + probe.port)
        if (!options.environment.some(e => e.startsWith('TZ='))) options.environment.push('TZ=' + probe.timezone)
        log('保留原容器时区: ' + probe.timezone)
        const runtimeOverrides = (old.Config.Env || []).map(e => e.split('=', 1)[0])
            .filter(name => ['NODE_OPTIONS', 'NODE_PATH', 'LD_LIBRARY_PATH', 'LD_PRELOAD'].includes(name))
        if (runtimeOverrides.length) log('以下旧运行时变量改用新镜像的值: ' + runtimeOverrides.join(', '))
        ensure(await this.healthy(old.Id, probe.node, false), '旧容器服务未通过检查，迁移前请先修复')
        log('[2/6] 检查新镜像、全部字节码和原生 SQLite 模块')
        const image = await api.json('GET', '/images/' + encodeURIComponent(a.image) + '/json')
        ensure(image.Os === 'linux' && image.Architecture === 'amd64', '新镜像必须为 linux/amd64')
        ensure(!Object.keys(image.Config.Volumes || {}).length, '新镜像不能声明额外的数据卷')
        ensure(JSON.stringify(image.Config.Cmd) === JSON.stringify([
            '/home/ubuntu/astro-server/node_modules/.bin/pm2-runtime', '/home/ubuntu/ecosystem.config.cjs']) &&
            !image.Config.Entrypoint?.length, '新镜像不符合标准 Astro 启动布局')
        const info = JSON.parse(await api.probe(image.Id, ['-e', IMAGE_PROBE]))
        log('镜像检查通过：Node ' + info.node + ' / Astro ' + info.version)
        await this.checkEnv(image.Id, options, info)
        this.checkSignal()
        if (a.check) { log('检查完成，原容器未停止，未创建迁移备份。'); return }
        log('统计旧应用目录体积，大目录可能耗时较长（最多等待 10 分钟）')
        const du = await this.longExec(old.Id, ['du', '-sk', '--apparent-size', ROOT], '0',
            DU_TIMEOUT, '仍在统计目录体积，旧容器保持运行，请稍候…')
        const size = Number(du.split(/\s+/)[0]) * 1024
        ensure(Number.isSafeInteger(size) && size > 0, '无法确定旧目录大小')
        checkDiskSpace(size, a.backupDir)
        const token = new Date().toISOString().replace(/[-:.]/g, '').slice(0, 15) + 'Z-' + crypto.randomBytes(4).toString('hex')
        this.backup = path.join(a.backupDir, a.container + '-' + token)
        fs.mkdirSync(this.backup, { mode: 0o700 })
        // Only the temporary controller uses this copy; no host path becomes a new application mount.
        const data = this.temporaryData = fs.mkdtempSync('/tmp/astro-node26-data-')
        this.state = { format: 2, migration_id: token, endpoint: a.endpoint, daemon_id: this.daemonID,
            name: a.container, old_id: old.Id, old_image: old.Image, old_node: probe.node,
            restart: options.restart, old_name: a.container + '-backup-' + token,
            new_name: a.container + '-node26-preparing-' + token, failed_name: a.container + '-node26-failed-' + token,
            image: image.Id, node: NODE, astro: info.version, timezone: probe.timezone, env_mount: options.envMount || null }
        writeJSON(path.join(this.backup, 'old-inspect.json'), old)
        fs.copyFileSync('/migration/script.sh', path.join(this.backup, 'upgrade-node26.sh'))
        fs.writeFileSync(path.join(this.backup, 'recovery-image'), image.Id + '\n', { mode: 0o600 })
        fs.writeFileSync(path.join(this.backup, 'recovery-name'), a.container + '\n', { mode: 0o600 })
        this.save('prepared'); log('备份目录: ' + this.backup)
        this.checkSignal(); this.changed = true; this.save('stopping')
        await api.update(old.Id, { Name: 'no', MaximumRetryCount: 0 }); await api.stop(old.Id)
        log('[3/6] 旧容器已停止，正在备份完整 /home/ubuntu，请勿中断')
        const archive = path.join(this.backup, 'home.tar')
        await this.exportArchive(old.Id, archive)
        const fd = fs.openSync(archive, 'r'); try { fs.fsyncSync(fd) } finally { fs.closeSync(fd) }
        this.state.backup_sha256 = await sha256(archive); this.save('backed_up'); this.checkSignal()
        await extractData(archive, data)
        fs.writeFileSync(path.join(this.backup, 'container.env'), options.environment.join('\n') + '\n', { mode: 0o600 })
        log('[4/6] 验证数据副本与 SQLite 数据库，并适配新容器 UID/GID')
        validateData(data, info.uid, info.gid); this.checkSignal()
        const restored = path.join(this.backup, 'restore.tar')
        await restoreArchive(data, restored, info.uid, info.gid, !!options.envMount); this.checkSignal()
        log('[5/6] 创建新容器并恢复用户数据，保留原容器用于回滚')
        const containerConfig = { Image: image.Id, Env: options.environment, ...restoredCommand(image.Config.Cmd),
            ExposedPorts: old.Config.ExposedPorts || {}, HostConfig: options.host,
            Labels: { 'io.astro.migration.id': token, 'io.astro.migration.backup': this.backup } }
        if (options.macAddress) {
            if (Number(api.version.split('.')[1]) >= 44) {
                ensure(options.networkName, '无法确定 MAC 对应的网络')
                containerConfig.NetworkingConfig = { EndpointsConfig: {
                    [options.networkName]: { MacAddress: options.macAddress } } }
            } else containerConfig.MacAddress = options.macAddress
        }
        const next = await api.create(this.state.new_name, containerConfig)
        this.state.new_id = next.Id; this.save('created'); this.checkSignal()
        await withProgress('仍在向新容器写入恢复数据，请稍候…', () =>
            api.raw('PUT', '/containers/' + next.Id + '/archive?path=/&copyUIDGID=true&noOverwriteDirNonDir=true',
                { body: fs.createReadStream(restored), headers: { 'Content-Type': 'application/x-tar',
                    'Content-Length': fs.statSync(restored).size }, timeout: ARCHIVE_IDLE_TIMEOUT, signal: this.abortController.signal }))
        this.save('restored'); this.checkSignal()
        await api.rename(old.Id, this.state.old_name); await api.rename(next.Id, a.container)
        this.save('starting'); log('[6/6] 启动并验证新服务；完成前请勿在面板启动交易核心')
        await api.start(next.Id)
        ensure(await this.healthy(next.Id), '新容器未通过服务健康检查')
        log('使用新容器默认用户验证配置权限及 SQLite 读写锁（最多等待 5 分钟）')
        await this.longExec(next.Id, ['node', '-e', DATA_PROBE, String(info.uid),
            options.envMount && !options.envMount.RW ? '--env-readonly' : '--env-writable'], '', SQLITE_TIMEOUT,
        '仍在验证新容器的数据权限和 SQLite 读写锁，请稍候…')
        this.checkSignal(); await api.update(next.Id, options.restart); this.save('complete'); this.changed = false
        log('迁移完成：Node ' + NODE + ' / 镜像内 Astro ' + info.version)
        log('旧容器已停止保留: ' + this.state.old_name)
        log('请在面板确认配置，按需升级应用，然后手动恢复交易核心。')
        log('本次已检查服务、字节码、SQLite 和数据权限；交易核心未启动，交易功能需手动验证。')
        log('回滚命令: sudo bash ' + shellQuote(path.join(this.backup, 'upgrade-node26.sh')) +
            ' --rollback ' + shellQuote(this.backup))
        await this.offerBackupCleanup()
    }
}
async function main() {
    ensure(process.versions.node === NODE, '新镜像必须使用 Node ' + NODE)
    const [container, image, backupDir, endpoint, rollback, check, healthTimeout, interactive] = process.argv.slice(2)
    const args = { container, image, backupDir, endpoint, rollback, check: check === '1',
        healthTimeout: Number(healthTimeout), interactive: interactive === '1' }
    const migration = new Migration(args, new Docker())
    for (const name of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(name, () => {
        if (!migration.recovering) {
            migration.interrupt()
            if (migration.state.phase === 'complete') {
                migration.cleanupPrompt?.close()
                log('迁移已经完成；中断清理选择，保留尚未删除的备份。')
            } else log('收到中断信号，将停止迁移并按需恢复旧容器。')
        }
    })
    try { await migration.run() }
    catch (error) {
        if (migration.changed) {
            migration.recovering = true; log('迁移失败，开始恢复旧容器')
            try { await migration.rollback() }
            catch (recovery) {
                log('自动恢复失败: ' + recovery.message)
                log('保留所有容器和备份，请使用 --rollback 恢复: ' + migration.backup)
            }
        }
        throw error
    } finally { if (migration.temporaryData) fs.rmSync(migration.temporaryData, { recursive: true, force: true }) }
}
module.exports = { archiveName, selected, extractData, restoreArchive, oldOptions, publishedPorts, demux, Docker, Migration,
    validateData, shellQuote, checkDiskSpace, loadTar, DATA_PROBE, HEALTH, OLD_PROBE, CONTROL_FILES,
    RESTORE_DATA, restoredCommand, STAGING, DU_TIMEOUT, ARCHIVE_IDLE_TIMEOUT, SQLITE_TIMEOUT, ENV_PROBE, EXEC_RUNNER, EXEC_CANCEL }
if (require.main === module) main().catch(error => { log('ERROR: ' + error.message); process.exitCode = 1 })
JS_MIGRATION
INTERACTIVE=0
if [[ -t 0 && -t 1 ]]; then INTERACTIVE=1; exec 3<&0
else exec 3</dev/null; fi
docker run --interactive --rm --platform linux/amd64 --name "$CONTROLLER" --cidfile "$WORK/controller.cid" \
  --network none --user 0 --no-healthcheck --stop-timeout 120 --entrypoint node \
  --label io.astro.migration.role=controller \
  --label "io.astro.migration.container=$CONTAINER" \
  --mount "type=bind,src=$SOCKET,dst=/migration/docker.sock" \
  --mount "type=bind,src=$WORK,dst=/migration/work,readonly" \
  --mount "type=bind,src=$SCRIPT,dst=/migration/script.sh,readonly" \
  ${MOUNTS[@]+"${MOUNTS[@]}"} "$IMAGE_ID" /migration/work/controller.cjs \
  "$CONTAINER" "$IMAGE_ID" "$BACKUP_BASE" "$ENDPOINT" "$ROLLBACK" "$CHECK" "$HEALTH_TIMEOUT" "$INTERACTIVE" <&3 &
RUN_PID=$!
exec 3<&-
if wait "$RUN_PID"; then exit 0; else exit "$?"; fi
