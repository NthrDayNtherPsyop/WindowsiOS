#!/bin/bash
# Build the Windows 11 ARM64 disk for WindowsiOS on a Mac (made for GitHub Actions),
# then compress and ENCRYPT it so it can sit in a public repo's release.
#
#   1. Builds the Mac emulator (build/winvm), the sparse packer (build/hvsparse)
#      and the WinPE registry tool (build/opt_hive_arm64.exe).
#   2. Downloads the official Windows 11 ARM64 ESD from Microsoft's own catalog
#      and checks its SHA-1.
#   3. Runs the repo's scripts/provision_windows_arm64.py and
#      scripts/optimize_windows_lite.py (patched for CI, see below).
#   4. Packs the result to windows11.hvsparse, gzips it, and encrypts it with a
#      random AES-256 key. That key is encrypted with the RSA public key below;
#      only the matching private key (kept off GitHub) can decrypt it.
#
# Output in out/:
#   windows11.hvsparse.gz.enc.part-*   encrypted, compressed disk (split < 2 GB)
#   windows11.key.enc                  AES key, RSA-OAEP encrypted
#   code.fd, vars.fd                   UEFI firmware + its settings (not secret)
#   SHA256SUMS
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export PATH="/opt/homebrew/bin:$PATH"
WORK="$ROOT/work"
OUT="$ROOT/out"
ESD="$WORK/downloads/Win11_24H2_ARM64_en-us.esd"
PY=/opt/homebrew/bin/python3
OPENSSL=/usr/bin/openssl   # LibreSSL, same as macOS on the decrypting Mac
LLVM=/opt/homebrew/opt/llvm/bin
LLD=/opt/homebrew/opt/lld/bin

# Emulator settings for the provisioning VMs (GitHub's arm64 Macs have 3 cores, 7 GB).
VM_CPUS="${VM_CPUS:-3}"
VM_RAM_MB="${VM_RAM_MB:-4096}"
WIN_USER="${WIN_USER:-User}"

step() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
space() { df -h "$ROOT" | tail -1; }

on_error() {
    echo "!! Failed. Recent emulator logs:"
    for f in "$WORK"/prov_*.log "$WORK"/_opt_pe.log; do
        [ -f "$f" ] && { echo "--- $f"; tail -60 "$f"; }
    done
    space
}
trap on_error ERR

mkdir -p "$WORK/downloads" "$OUT" build

step "Runner: $(sysctl -n hw.ncpu) CPUs, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM"
space

# ---------------------------------------------------------------- 1. tools
step "Building Mac emulator and sparse packer"
make -j"$(sysctl -n hw.ncpu)" build/winvm build/hvsparse

step "Building opt_hive_arm64.exe (freestanding ARM64 Windows tool)"
HB="$WORK/hive_build"
mkdir -p "$HB"
printf 'LIBRARY kernel32.dll\nEXPORTS\nGetCurrentProcess\nGetStdHandle\nWriteFile\nExitProcess\n' > "$HB/kernel32.def"
printf 'LIBRARY advapi32.dll\nEXPORTS\nOpenProcessToken\nLookupPrivilegeValueW\nAdjustTokenPrivileges\nRegOpenKeyExW\nRegCreateKeyExW\nRegSetValueExW\nRegCloseKey\n' > "$HB/advapi32.def"
"$LLVM/llvm-dlltool" -m arm64 -d "$HB/kernel32.def" -l "$HB/kernel32.lib"
"$LLVM/llvm-dlltool" -m arm64 -d "$HB/advapi32.def" -l "$HB/advapi32.lib"
"$LLVM/clang" --target=aarch64-pc-windows-msvc -O2 -ffreestanding -fno-builtin -fno-stack-protector \
    -c tools/opt_hive_arm64.c -o "$HB/opt_hive_arm64.o"
"$LLD/lld-link" /nologo /machine:arm64 /subsystem:console /entry:mainCRTStartup /nodefaultlib \
    /out:build/opt_hive_arm64.exe "$HB/opt_hive_arm64.o" "$HB/kernel32.lib" "$HB/advapi32.lib"
ls -l build/winvm build/hvsparse build/opt_hive_arm64.exe

# ---------------------------------------------------------------- 2. Windows ESD
if [ ! -s "$ESD" ]; then
    step "Finding Windows 11 ARM64 (en-us) in Microsoft's media catalog"
    CAT="$WORK/catalog"
    rm -rf "$CAT" && mkdir -p "$CAT"
    curl -fsSL --retry 3 -o "$CAT/products.cab" "https://go.microsoft.com/fwlink/?LinkId=2156292"
    tar -xf "$CAT/products.cab" -C "$CAT"
    read -r ESD_URL ESD_SHA1 ESD_SIZE < <("$PY" -I - "$CAT/products.xml" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
for f in ET.parse(sys.argv[1]).getroot().iter("File"):
    g = lambda t: (f.findtext(t) or "").strip()
    if (g("Architecture") == "ARM64" and g("LanguageCode") == "en-us"
            and g("Edition") == "Professional" and g("FileName").endswith(".esd")):
        print(g("FilePath"), g("Sha1").lower(), g("Size"))
        break
else:
    sys.exit("No ARM64 en-us Professional ESD in products.xml")
PYEOF
    )
    [ -n "${ESD_URL:-}" ] && [ -n "${ESD_SHA1:-}" ] || { echo "Could not read the ESD entry"; exit 1; }
    echo "ESD: $ESD_URL ($ESD_SIZE bytes, sha1 $ESD_SHA1)"
    step "Downloading the ESD from Microsoft"
    curl -fL --retry 5 --retry-delay 5 -C - -o "$ESD.part" "$ESD_URL"
    echo "$ESD_SHA1  $ESD.part" | shasum -a 1 -c -
    mv "$ESD.part" "$ESD"
fi

step "Images inside the ESD"
wimlib-imagex info "$ESD" | grep -E '^(Index|Name):'
PRO_INDEX="$(wimlib-imagex info "$ESD" | awk '/^Index:/{i=$2} /^Name:/{sub(/^Name:[ \t]*/,""); if ($0=="Windows 11 Pro") {print i; exit}}')"
[ -n "$PRO_INDEX" ] || { echo "Windows 11 Pro not found in ESD"; exit 1; }
echo "Windows 11 Pro is image $PRO_INDEX"

# ---------------------------------------------------------------- 3. patch + run repo scripts
step "Patching provisioning scripts for CI (Pro index, account '$WIN_USER', $VM_CPUS vCPUs, longer timeouts)"
PROV=scripts/provision_windows_arm64.py
OPT=scripts/optimize_windows_lite.py
# Pro edition index (the repo hard-codes 6 for the author's ESD).
grep -q 'ESD, "6", wim_root' "$PROV"
perl -pi -e "s/ESD, \"6\", wim_root/ESD, \"$PRO_INDEX\", wim_root/" "$PROV"
# Local account name (the repo uses the author's name).
perl -pi -e "s/Ammaar/$WIN_USER/g" "$PROV" "$OPT"
# Emulator size.
perl -pi -e "s/\"--cpus\", \"4\"/\"--cpus\", \"$VM_CPUS\"/; s/\"--ram\", \"4096\"/\"--ram\", \"$VM_RAM_MB\"/" "$PROV" "$OPT"
# GitHub's Macs are much slower than the author's; give each phase more time.
perl -pi -e 's/max_minutes=40/max_minutes=150/; s/max_minutes=60/max_minutes=180/' "$PROV"
perl -pi -e 's/elapsed > 25 \* 60/elapsed > 90 * 60/; s/exceeded 25 minutes/exceeded 90 minutes/' "$OPT"
grep -n -E '"--cpus"|"--ram"|max_minutes=|elapsed > |wim_root / "sources" / "install.wim"' "$PROV" "$OPT"

step "Provisioning Windows 11 (WinPE + DISM, then first boot/OOBE)"
space
"$PY" -u "$PROV"
rm -f "$WORK/installer_v4.img" "$WORK/.installer_exfat_v4"
space

step "Slimming Windows down (offline WinPE registry + app removal)"
"$PY" -u "$OPT"
rm -f "$WORK/windows11.img" "$ESD"
space

# ---------------------------------------------------------------- 4. pack + encrypt
step "Packing windows11_lite.img into windows11.hvsparse"
./build/hvsparse pack "$WORK/windows11_lite.img" "$WORK/windows11.hvsparse"
rm -f "$WORK/windows11_lite.img"
ls -l "$WORK/windows11.hvsparse"
space

step "Compressing and encrypting the disk"
cat > "$WORK/disk-public-key.pem" <<'KEYEOF'
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAwZQDzX9hxX0P2chRl/Sz
An64IOO6hcga52ZXGcCBP8dEDZfJr4R0VcPQVblbNZ82/JE8z5OdHAfTtKcTqNfd
Oyq6UmvGAEGYqU+6+KouQ7K0OLOFVPoe+3+kLtpmmcTwNb5KOTESA3su2ax9ijFN
9N+m8s1mpEQb58jdhk7dA5ZHkln056L8ttiAeD5xZ7AVrWlyPHB80S/F7ho2K9bo
vnsjSdrrsm3TMvwIzVymCiQE+Gsl9hcohI+woeSvNuQuuyaZDIDvPLe4TGU4q8OQ
PAM3QXjtyDXAQLFyv5nfxh3t9ruppCgRa+9F58wpcO5cAF4pbC+5YY+maff92XhJ
3h0wb5FzFtGMdDzvIzfVbus/j5HGAEy9FJZZnnX3ZmLBPcacGZSL4/fneC7fPqO+
uENnHWXZpPIQudVlHJfFfbfCvZUhOZDc//1lxJ71pkqWXTfFXwdKgStQQRVvrcFR
e58Wc4Zz5XaQavPEsZrwfZ247ALgtU1QV+O4oWrZyvA5nNHAul9fvA+V1n32VoAP
rarGYQOPtUDjHpCUoCyLPU4rHjG4y30+EH+/bdo4Mcyz2/b9ys2xfrW8BKwN+ymr
yxrL2AlJf3WHuGvlkHqwrNF/dABLgZET1WG8BMdAgSg4/H9PrxdehBG+OLosYaJP
4eiOyrU0PL35+wDaqKn0Zx0CAwEAAQ==
-----END PUBLIC KEY-----
KEYEOF
( umask 077; "$OPENSSL" rand -hex 32 > "$WORK/disk.key" )
pigz -6 -c "$WORK/windows11.hvsparse" \
  | "$OPENSSL" enc -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -salt -pass "file:$WORK/disk.key" \
  | split -b 1900m - "$OUT/windows11.hvsparse.gz.enc.part-"
"$OPENSSL" pkeyutl -encrypt -pubin -inkey "$WORK/disk-public-key.pem" \
    -pkeyopt rsa_padding_mode:oaep -in "$WORK/disk.key" -out "$OUT/windows11.key.enc"
rm -f "$WORK/disk.key" "$WORK/windows11.hvsparse"
cp "$WORK/code.fd" "$WORK/vars.fd" "$OUT/"
( cd "$OUT" && shasum -a 256 * > SHA256SUMS )
ls -l "$OUT"
step "Done"
