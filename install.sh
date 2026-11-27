#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./install.sh --pg-config /path/bin/pg_config --data-dir /path/to/PGDATA
                    [--config-file /path/postgresql.conf] [--pg-user postgres]
                    [--database mydb --port 5432 --socket /var/run/postgresql]
                    [--configure-only | --files-only] [--no-service]

The default installs files, configures the cluster and, when --database is
specified, installs a systemd service definition. It does not restart PostgreSQL.
EOF
}

pg_config=${PG_CONFIG:-pg_config}
datadir=${PGDATA:-}
config_file=''
pg_user=''
database=''
port=5432
socket=/var/run/postgresql
mode=all
service=yes
while (($#)); do
    case "$1" in
        --pg-config|--data-dir|--config-file|--pg-user|--database|--port|--socket)
            [[ $# -ge 2 && -n $2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --pg-config) pg_config=$2 ;;
                --data-dir) datadir=$2 ;;
                --config-file) config_file=$2 ;;
                --pg-user) pg_user=$2 ;;
                --database) database=$2 ;;
                --port) port=$2 ;;
                --socket) socket=$2 ;;
            esac
            shift 2 ;;
        --configure-only) mode=configure; shift ;;
        --files-only) mode=files; shift ;;
        --no-service) service=no; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

command -v python3 >/dev/null || { echo 'Python 3 is required.' >&2; exit 1; }
pg_config=$(command -v "$pg_config")
bindir=$("$pg_config" --bindir)
sharedir=$("$pg_config" --sharedir)
pkglibdir=$("$pg_config" --pkglibdir)
libdir=$("$pg_config" --libdir)
major=$("$pg_config" --version | sed -nE 's/^PostgreSQL ([0-9]+).*/\1/p')
[[ $major =~ ^(14|15|16|17|18|19)$ && $(uname -s) == Linux ]] || { echo 'Linux PostgreSQL 14–19 required.' >&2; exit 1; }
arch=$(uname -m)
case "$arch" in x86_64|aarch64) ;; *) echo 'Unsupported architecture.' >&2; exit 1;; esac
base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ $mode != files ]]; then
    [[ -n $datadir ]] || { echo 'Specify --data-dir or PGDATA.' >&2; exit 1; }
    datadir=$(realpath -e -- "$datadir")
    [[ $(cat "$datadir/PG_VERSION") == "$major" ]] || { echo 'PGDATA and pg_config major versions differ.' >&2; exit 1; }
    config_file=$(realpath -e -- "${config_file:-$datadir/postgresql.conf}")
    pg_user=${pg_user:-$(stat -c %U "$datadir")}
    if ((EUID == 0)); then
        as_pg=(runuser -u "$pg_user" --)
    else
        [[ $(id -un) == "$pg_user" ]] || { echo 'Use the PostgreSQL OS owner or root.' >&2; exit 1; }
        as_pg=()
    fi
    preload=$("${as_pg[@]}" "$bindir/postgres" -D "$datadir" -c "config_file=$config_file" -C shared_preload_libraries)
    for setting in auto_create maintenance_window auto_drop_existing auto_drop_managed; do
        if value=$("${as_pg[@]}" "$bindir/postgres" -D "$datadir" -c "config_file=$config_file" \
                    -C "pg_index_steward.$setting" 2>/dev/null); then
            printf -v "steward_$setting" '%s' "$value"
        fi
    done
fi

if [[ $mode != configure ]]; then
    module="$base/payload/$arch/pg$major/pg_index_steward.so"
    [[ -f $module ]] || { echo "Binary missing for $arch / PostgreSQL $major." >&2; exit 1; }
    if [[ -f $base/SHA256SUMS ]]; then
        (cd "$base" && sha256sum -c SHA256SUMS >/dev/null)
    fi
    python3 - "$module" "$arch" <<'PY'
import struct
import sys
with open(sys.argv[1], 'rb') as f:
    elf = f.read(20)
expected = {'x86_64': 62, 'aarch64': 183}[sys.argv[2]]
if elf[:6] != b'\x7fELF\x02\x01' or struct.unpack('<H', elf[18:20])[0] != expected:
    sys.exit('Binary architecture does not match the host')
PY
    [[ -f $sharedir/extension/pg_stat_statements.control ]] || { echo 'Install matching pg_stat_statements first.' >&2; exit 1; }
    atomic_install() {
        local src=$1 dst=$2 perms=$3 tmp
        tmp=$(mktemp "$(dirname "$dst")/.pgsteward.XXXXXX")
        install -m "$perms" -- "$src" "$tmp"
        mv -fT -- "$tmp" "$dst"
    }
    atomic_install "$module" "$pkglibdir/pg_index_steward.so" 0755
    atomic_install "$base/pg_index_steward.control" "$sharedir/extension/pg_index_steward.control" 0644
    atomic_install "$base/sql/pg_index_steward--0.1.0.sql" "$sharedir/extension/pg_index_steward--0.1.0.sql" 0644
    atomic_install "$base/bin/pg-index-steward" "$bindir/pg-index-steward" 0755
fi

if [[ $mode != files ]]; then
    python3 - "$config_file" "$preload" "${steward_auto_create:-on}" "${steward_maintenance_window:-23:00-06:00}" \
       "${steward_auto_drop_existing:-off}" "${steward_auto_drop_managed:-on}" <<'PY'
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path

path = Path(sys.argv[1])
begin, end = '# BEGIN PG INDEX STEWARD', '# END PG INDEX STEWARD'
original = path.read_bytes()
text = original.decode('utf-8', errors='surrogateescape')
if text.count(begin) != text.count(end) or text.count(begin) > 1:
    sys.exit('Invalid Steward configuration block')
if begin in text and text.index(begin) >= text.index(end):
    sys.exit('Invalid Steward configuration block ordering')
text = re.sub(re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', '', text, flags=re.S)
libraries = sys.argv[2].strip()
for lib in ('pg_stat_statements', 'pg_index_steward'):
    if lib not in [v.strip().strip('"') for v in libraries.split(',')]:
        libraries = f'{libraries},{lib}' if libraries else lib
opts = dict(zip(('auto_create','maintenance_window','auto_drop_existing','auto_drop_managed'), sys.argv[3:]))
for k, value in opts.items():
    if k == 'maintenance_window':
        if not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d-(?:[01]\d|2[0-3]):[0-5]\d', value) or value[:5] == value[6:]:
            sys.exit('Invalid existing maintenance window')
    elif value.lower() not in ('on','off','true','false','yes','no','0','1'):
        sys.exit(f'Invalid existing setting {k}')
def quote(v):
    return "'" + v.replace('\\','\\\\').replace("'", "''") + "'"
block = [begin, f'shared_preload_libraries = {quote(libraries)}']
block.extend(f'pg_index_steward.{k} = {quote(v)}' for k, v in opts.items())
new = (text.rstrip() + '\n\n' + '\n'.join(block + [end, ''])).encode('utf-8',errors='surrogateescape')
if original != new:
    info = path.stat()
    backup = path.with_name(path.name + '.pg-index-steward.' + datetime.now().strftime('%Y%m%d%H%M%S%f') + '.bak')
    shutil.copy2(path, backup)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.pgsteward-', delete=False) as temp:
        temp.write(new)
        temp.flush()
        os.fchmod(temp.fileno(), info.st_mode & 0o777)
        if os.geteuid() == 0:
            os.fchown(temp.fileno(), info.st_uid, info.st_gid)
        os.fsync(temp.fileno())
    os.replace(temp.name, path)
    print(f'Configuration backup: {backup}')
PY
    if [[ -n $database && $service == yes ]]; then
        [[ $EUID == 0 && -d /etc/systemd/system ]] || { echo 'Root and systemd are required for --database.' >&2; exit 1; }
        [[ $database =~ ^[a-zA-Z0-9_.-]+$ && $pg_user =~ ^[a-zA-Z0-9_.-]+$ && $port =~ ^[0-9]+$ &&
           $socket =~ ^/[a-zA-Z0-9_./-]+$ && $bindir =~ ^/[a-zA-Z0-9_./-]+$ && $libdir =~ ^/[a-zA-Z0-9_./-]+$ ]] ||
           { echo 'For nonstandard service options use --no-service and start the runner directly.' >&2; exit 1; }
        instance=$(printf '%s' "$datadir/$database" | sha256sum | cut -c1-12)
        unit="pg-index-steward-$instance.service"
        unit_file=$(mktemp /etc/systemd/system/.pgsteward.XXXXXX)
        cat > "$unit_file" <<EOF
[Unit]
Description=PG Index Steward for $database
After=network.target

[Service]
Type=simple
User=$pg_user
Environment=PGDATABASE=$database PGHOST=$socket PGPORT=$port PGUSER=$pg_user PGCONNECT_TIMEOUT=5
ExecStart=$bindir/pg-index-steward --libpq $libdir/libpq.so.5
Restart=on-failure
RestartSec=10s
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$unit_file"
        mv -fT "$unit_file" "/etc/systemd/system/$unit"
        printf 'After initializing the extension, run systemctl daemon-reload && systemctl enable --now %s\n' "$unit"
    fi
fi
printf 'Installation finished for PostgreSQL %s on %s.\n' "$major" "$arch"
