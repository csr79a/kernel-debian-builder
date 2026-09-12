#!/usr/bin/env bash
#
# build-kernel-debian.sh — Instalador de Kernel csr79a
#
# Descarga la última versión estable del kernel de kernel.org, la compila
# usando la configuración del kernel actualmente en ejecución, genera
# paquetes .deb (linux-image / linux-headers) con el método nativo del
# kernel (bindeb-pkg), los instala y regenera GRUB.
#
# Uso:
#   ./build-kernel-debian.sh [--force]
#
#   --force  Ignora la comprobación de "ya tienes esta versión" y
#            recompila igualmente. Necesario si ya generaste un kernel
#            -custom con este script y quieres repetir el build con un
#            .config distinto (p. ej. tras añadir una nueva opción
#            forzada en la sección 7.x), ya que 'uname -r' seguirá
#            reportando la misma versión con el sufijo -custom.
#
# Requiere: Debian o derivado, con sudo configurado.
#
# Historial de versiones:
#   1.1.4 - Se añade el flag --force para poder recompilar el mismo
#           número de versión con un .config distinto (la comprobación
#           de "ya la tienes" comparaba solo el número de versión, no
#           el contenido del .config). Se añade la sección 7.2, que
#           fuerza CONFIG_SCHED_CLASS_EXT (y sus dependencias BPF/BTF)
#           para poder usar sched-ext (scx_lavd, scx_bpfland, etc.).
#   1.1.3 - Se añade el WKD de kernel.org (resuelto por HTTPS contra su
#           propio dominio) como tercera fuente para importar las claves
#           PGP, por si ambos keyservers estuvieran caídos a la vez.
#   1.1.2 - Se usa 'apt install' en vez de 'dpkg -i' para instalar los
#           paquetes .deb generados, de forma que las dependencias que
#           falten se resuelvan automáticamente en vez de dejar el
#           sistema en estado roto.
#   1.1.1 - Corrección de bugs menores: comprobación de 'sudo', falso
#           positivo al detectar el kernel ya instalado, protección del
#           glob al instalar los .deb, manejo de error en la consulta a
#           kernel.org y validación del formato de versión recibido.
#           Se añade verificación de firma PGP (autenticidad, además del
#           SHA256 ya existente) contra las claves oficiales de
#           kernel.org.
#   1.1.0 - Versión base: descarga desde kernel.org, verificación SHA256,
#           compilación con opciones ASUS forzadas, generación e
#           instalación de paquetes .deb, regeneración de GRUB.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
VERSION="1.1.4"
WORKDIR="${HOME}/kernel-build"
SB_ENABLED="no"
GNUPGHOME="${WORKDIR}/.gnupg-kernel"
FORCE="no"

# Claves PGP oficiales reconocidas para firmar releases de kernel.org.
# Fuente: https://kernel.org/category/signatures.html
# Solo se acepta una firma si coincide con una de estas huellas exactas;
# no se confía en el "web of trust" ni en el nivel de confianza de gpg.
KERNEL_PGP_FPRS=(
    "ABAF11C65A2970B130ABE3C479BE3E4300411886"  # Linus Torvalds
    "647F28654894E3BD457199BE38DBBDC86092693"   # Greg Kroah-Hartman
)

# Correo asociado a cada huella, usado como último recurso vía WKD
# (Web Key Directory de kernel.org, resuelto por HTTPS directamente
# contra su dominio: https://www.kernel.org/signature.html).
declare -A KERNEL_PGP_EMAILS=(
    ["ABAF11C65A2970B130ABE3C479BE3E4300411886"]="torvalds@kernel.org"
    ["647F28654894E3BD457199BE38DBBDC86092693"]="gregkh@kernel.org"
)

log()   { echo -e "\e[1;34m[*]\e[0m $*"; }
ok()    { echo -e "\e[1;32m[OK]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[!]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --force) FORCE="yes" ;;
        *) error "Argumento desconocido: '$arg'. Uso: $0 [--force]" ;;
    esac
done

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Falta el comando '$1'. Instálalo e inténtalo de nuevo."
}

# ---------------------------------------------------------------------------
# 0. Comprobaciones previas
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    error "No ejecutes este script como root directamente. Usa tu usuario normal; se pedirá sudo cuando haga falta."
fi

require_cmd "sudo"

DEPS=(build-essential libncurses-dev bison flex libssl-dev libelf-dev
      dwarves libdw-dev debhelper fakeroot bc rsync curl jq whiptail mokutil
      gnupg xz-utils)

MISSING=()
for pkg in "${DEPS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Instalando paquetes que faltan: ${MISSING[*]}"
    sudo apt update
    sudo apt install -y "${MISSING[@]}"
else
    ok "Todas las dependencias ya están instaladas."
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ---------------------------------------------------------------------------
# 1. Pantalla de bienvenida
# ---------------------------------------------------------------------------
whiptail --title "Instalador de Kernel csr79a" \
    --yesno "Versión del Instalador de Kernel csr79a ${VERSION}\n\nEste programa descargará, verificará (SHA256 + firma PGP), compilará e instalará el último kernel estable desde kernel.org.\n\nEl tiempo dependerá de tu hardware (hilos y RAM disponibles).\n\n¿Desea continuar?" \
    16 70 || exit 0

# ---------------------------------------------------------------------------
# 2. Comprobar espacio en disco
# ---------------------------------------------------------------------------
log "Comprobando espacio en disco disponible..."
AVAIL_GB="$(df --output=avail -BG "$WORKDIR" | tail -1 | tr -d 'G ')"
if (( AVAIL_GB < 50 )); then
    error "Solo hay ${AVAIL_GB}GB libres en ${WORKDIR}. Se recomiendan al menos 50GB para compilar con todos los módulos del kernel de Debian."
fi
ok "Espacio disponible: ${AVAIL_GB}GB."

# ---------------------------------------------------------------------------
# 3. Detectar Secure Boot
# ---------------------------------------------------------------------------
log "Comprobando estado de Secure Boot..."
SB_STATE="$(mokutil --sb-state 2>/dev/null || echo "desconocido")"
if echo "$SB_STATE" | grep -qi "enabled"; then
    SB_ENABLED="yes"
    warn "Secure Boot está ACTIVADO. El kernel compilado no estará firmado y podría no arrancar."
    whiptail --title "Secure Boot activado" \
        --yesno "Secure Boot está activado.\n\nEl kernel compilado no estará firmado y UEFI podría rechazar arrancarlo.\n\nConsulta el MANUAL.md para el proceso de firma con clave MOK.\n\n¿Deseas continuar de todas formas?" \
        14 60 || exit 0
else
    ok "Secure Boot desactivado. No hace falta firmar el kernel."
fi

# ---------------------------------------------------------------------------
# 4. Detectar la última versión estable en kernel.org
# ---------------------------------------------------------------------------
log "Consultando la última versión estable en kernel.org..."

RELEASES_JSON="$(curl -fsSL https://www.kernel.org/releases.json)" \
    || error "No se pudo contactar con kernel.org. Comprueba tu conexión a internet e inténtalo de nuevo."
KVERSION="$(echo "$RELEASES_JSON" | jq -r '.releases[] | select(.moniker=="stable") | .version' | head -n1)"

[[ -n "$KVERSION" ]] || error "No se pudo determinar la última versión estable."
[[ "$KVERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || error "La versión recibida de kernel.org ('${KVERSION}') no tiene el formato esperado."

ok "Última versión estable: ${KVERSION}"

CURRENT_KVER="$(uname -r)"
if [[ "$CURRENT_KVER" == "$KVERSION" || "$CURRENT_KVER" == "$KVERSION".* || "$CURRENT_KVER" == "$KVERSION"-* ]]; then
    if [[ "$FORCE" == "yes" ]]; then
        warn "Ya estás ejecutando el kernel ${KVERSION} (${CURRENT_KVER}), pero se continúa por --force."
    else
        warn "Ya estás ejecutando el kernel ${KVERSION}. Nada que hacer. (Usa --force para recompilar igualmente, p. ej. tras cambiar opciones en la sección 7.x.)"
        exit 0
    fi
fi

KMAJOR="${KVERSION%%.*}"
TARBALL="linux-${KVERSION}.tar.xz"
SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/${TARBALL}"

# ---------------------------------------------------------------------------
# 5. Calcular número de jobs de compilación
# ---------------------------------------------------------------------------
NPROC="$(nproc)"
RAM_GB="$(free -g | awk '/^Mem:/{print $2}')"

# min(nproc, (RAM_GB - 2) / 2), suelo de 1
SAFE_JOBS=$(( (RAM_GB - 2) / 2 ))
(( SAFE_JOBS < 1 )) && SAFE_JOBS=1
(( SAFE_JOBS > NPROC )) && SAFE_JOBS=$NPROC

log "Hilos detectados: ${NPROC} | RAM detectada: ${RAM_GB}GB"
log "Valor recomendado (según hilos y RAM disponible): ${SAFE_JOBS} jobs"

if whiptail --title "Jobs de compilación" \
    --yesno "Hilos detectados: ${NPROC}\nRAM detectada: ${RAM_GB}GB\n\nValor recomendado: ${SAFE_JOBS} jobs\n\n¿Usar el valor recomendado?\n(elegir 'No' para usar todos los hilos disponibles: ${NPROC})" \
    14 60; then
    JOBS=$SAFE_JOBS
else
    JOBS=$NPROC
    if (( JOBS > SAFE_JOBS )); then
        warn "Con ${RAM_GB}GB de RAM y ${JOBS} jobs podrías tener problemas de memoria durante la compilación."
    fi
fi

ok "Jobs de compilación a usar: ${JOBS}"

# ---------------------------------------------------------------------------
# 6. Descargar y verificar el código fuente
# ---------------------------------------------------------------------------
if [[ ! -f "$TARBALL" ]]; then
    log "Descargando ${TARBALL}..."
    curl -fL --progress-bar -o "$TARBALL" "$SRC_URL"
else
    ok "El tarball ya estaba descargado, se reutiliza."
fi

log "Verificando la suma SHA256..."
SHA_LINE="$(curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/sha256sums.asc" | grep " ${TARBALL}\$")"
[[ -n "$SHA_LINE" ]] || error "No se encontró la suma SHA256 para ${TARBALL}."
echo "$SHA_LINE" | sha256sum -c - || error "¡La verificación SHA256 ha fallado! Fuente corrupta o manipulada."
ok "Suma SHA256 verificada correctamente."

# ---------------------------------------------------------------------------
# 6.1 Verificación de firma PGP (autenticidad, además de la integridad SHA256)
# ---------------------------------------------------------------------------
#
# El SHA256 anterior protege contra corrupción de descarga, pero se obtiene
# del mismo servidor que el propio tarball: si un mirror estuviera
# comprometido, podría servir tarball y checksum falsos a la vez. La firma
# PGP añade una capa de autenticidad independiente: solo se acepta si el
# release está firmado por una de las claves oficiales reconocidas en
# $KERNEL_PGP_FPRS.

mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
export GNUPGHOME

log "Importando claves PGP oficiales de kernel.org (si no están ya en el llavero local)..."
for fpr in "${KERNEL_PGP_FPRS[@]}"; do
    if ! gpg --batch --list-keys "$fpr" >/dev/null 2>&1; then
        gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$fpr" >/dev/null 2>&1 \
            || gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$fpr" >/dev/null 2>&1 \
            || gpg --batch --locate-keys "${KERNEL_PGP_EMAILS[$fpr]:-}" >/dev/null 2>&1 \
            || warn "No se pudo importar la clave ${fpr} (fallaron ambos keyservers y el WKD de kernel.org). La verificación fallará si el release está firmado solo con esa clave."
    fi
done

SIGN_FILE="linux-${KVERSION}.tar.sign"
SIGN_URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/${SIGN_FILE}"

log "Descargando firma PGP (${SIGN_FILE})..."
curl -fsSL -o "$SIGN_FILE" "$SIGN_URL"

GPG_LOG="${WORKDIR}/gpg-verify-${KVERSION}.log"
log "Verificando firma PGP contra el tarball (puede tardar unos segundos)..."
if ! xz -cd "$TARBALL" | gpg --batch --status-fd 1 --verify "$SIGN_FILE" - > "$GPG_LOG" 2>&1; then
    cat "$GPG_LOG" >&2
    error "La verificación PGP ha FALLADO para ${TARBALL}. No se continúa: el archivo podría no ser auténtico."
fi

KNOWN_MATCH=0
MATCHED_FPR=""
for fpr in "${KERNEL_PGP_FPRS[@]}"; do
    if grep -q "$fpr" "$GPG_LOG"; then
        KNOWN_MATCH=1
        MATCHED_FPR="$fpr"
        break
    fi
done

if [[ "$KNOWN_MATCH" -ne 1 ]]; then
    cat "$GPG_LOG" >&2
    error "La firma es criptográficamente válida pero de una clave NO reconocida. Se aborta por seguridad."
fi

ok "Firma PGP verificada correctamente (clave reconocida: ${MATCHED_FPR})."

# ---------------------------------------------------------------------------
# 6.2 Extraer el código fuente
# ---------------------------------------------------------------------------
SRC_DIR="linux-${KVERSION}"
if [[ ! -d "$SRC_DIR" ]]; then
    log "Extrayendo código fuente..."
    tar -xf "$TARBALL"
fi

cd "$SRC_DIR"

# ---------------------------------------------------------------------------
# 7. Preparar la configuración (.config)
# ---------------------------------------------------------------------------
log "Preparando configuración a partir del kernel actual ($(uname -r))..."

CURRENT_CONFIG="/boot/config-$(uname -r)"
[[ -f "$CURRENT_CONFIG" ]] || error "No se encontró ${CURRENT_CONFIG}."

cp "$CURRENT_CONFIG" .config
make olddefconfig

# ---------------------------------------------------------------------------
# 7.1 Forzar opciones de hardware ASUS que 'olddefconfig' no activa solo
# ---------------------------------------------------------------------------
#
# 'olddefconfig' hereda tal cual las opciones que ya estaban desactivadas
# en la config de origen; si en algún momento CONFIG_ASUS_ARMOURY quedó
# desactivada (p. ej. por arrancar sin querer un kernel antiguo/de serie
# antes de ejecutar este script), esa ausencia se propagaría para siempre
# de build en build. Se fuerza aquí explícitamente para evitarlo.
log "Forzando opciones de hardware ASUS necesarias (asus_armoury y afines)..."
scripts/config --enable CONFIG_ASUS_WMI
scripts/config --enable CONFIG_ASUS_ARMOURY
scripts/config --enable CONFIG_FIRMWARE_ATTRIBUTES_CLASS
scripts/config --enable CONFIG_ASUS_NB_WMI
scripts/config --enable CONFIG_HID_ASUS
make olddefconfig

# ---------------------------------------------------------------------------
# 7.2 Forzar soporte de sched_ext (scx_*), requerido por csr79a/scx-scheds
# ---------------------------------------------------------------------------
#
# Igual que con las opciones ASUS de arriba: si el kernel de origen no
# tenía esto activado, 'olddefconfig' lo heredaría desactivado para
# siempre. Se fuerza aquí para que el kernel resultante soporte cargar
# schedulers BPF de sched-ext (scx_lavd, scx_bpfland, etc.) sin tener
# que recompilar de nuevo solo por esto.
#
# CONFIG_SCHED_CLASS_EXT depende de BPF_SYSCALL && BPF_JIT && DEBUG_INFO_BTF
# (kernel/Kconfig.preempt). DEBUG_INFO_BTF necesita 'pahole' en el PATH
# durante la compilación para generar BTF desde DWARF; 'dwarves' (ya
# está en DEPS más arriba) lo provee.
log "Forzando soporte de sched_ext (CONFIG_SCHED_CLASS_EXT y dependencias)..."
scripts/config --enable CONFIG_BPF
scripts/config --enable CONFIG_BPF_SYSCALL
scripts/config --enable CONFIG_BPF_JIT
scripts/config --enable CONFIG_BPF_JIT_ALWAYS_ON
scripts/config --enable CONFIG_BPF_JIT_DEFAULT_ON
scripts/config --enable CONFIG_DEBUG_INFO_BTF
scripts/config --enable CONFIG_SCHED_CLASS_EXT
make olddefconfig

if ! grep -q '^CONFIG_SCHED_CLASS_EXT=y' .config; then
    warn "CONFIG_SCHED_CLASS_EXT no quedó activado tras 'olddefconfig' (revisa si falta alguna dependencia no forzada aquí). El kernel se compilará igualmente, pero sin soporte de sched_ext."
fi

# ---------------------------------------------------------------------------
# 8. Compilar y generar los .deb
# ---------------------------------------------------------------------------
LOGFILE="${WORKDIR}/build-${KVERSION}.log"
log "Compilando el kernel ${KVERSION} con ${JOBS} jobs (esto puede tardar)..."
make -j"${JOBS}" bindeb-pkg LOCALVERSION=-custom 2>&1 | tee "$LOGFILE"

ok "Compilación terminada. Paquetes .deb generados en ${WORKDIR}."

# ---------------------------------------------------------------------------
# 9. Instalar los paquetes generados
# ---------------------------------------------------------------------------
cd "$WORKDIR"

shopt -s nullglob
DEBS=(linux-image-"${KVERSION}"-custom_*.deb linux-headers-"${KVERSION}"-custom_*.deb)
shopt -u nullglob

[[ ${#DEBS[@]} -ge 2 ]] || error "No se encontraron los paquetes .deb esperados en ${WORKDIR}. Revisa ${LOGFILE} para ver si la compilación generó otros nombres de archivo."

log "Instalando paquetes: ${DEBS[*]}"
# Se usa 'apt install' (no 'dpkg -i') para que, si al kernel nuevo le
# faltara alguna dependencia, apt la resuelva e instale automáticamente
# en vez de dejar el sistema con paquetes a medio instalar.
#
# Con --force (mismo KVERSION que el ya instalado, p. ej. tras cambiar
# opciones en la sección 7.x y recompilar), el .deb generado tiene el
# mismo número de versión que el ya instalado. Sin --reinstall, apt lo
# detecta como "ya está en su versión más reciente" y NO lo reinstala,
# aunque el contenido (el .config usado) sea distinto.
APT_INSTALL_FLAGS=(-y)
[[ "$FORCE" == "yes" ]] && APT_INSTALL_FLAGS+=(--reinstall)
sudo apt install "${APT_INSTALL_FLAGS[@]}" "${DEBS[@]/#/./}"

# ---------------------------------------------------------------------------
# 10. Regenerar GRUB
# ---------------------------------------------------------------------------
log "Regenerando GRUB..."
sudo update-grub

# ---------------------------------------------------------------------------
# 11. Preguntar si eliminar los archivos generados
# ---------------------------------------------------------------------------
if whiptail --title "Limpiar archivos de compilación" \
    --yesno "¿Desea eliminar los archivos generados durante la compilación (fuente, .deb, etc.)?" \
    10 60; then
    log "Eliminando archivos generados en ${WORKDIR}..."
    rm -rf "${WORKDIR:?}"/*
    ok "Archivos eliminados."
else
    warn "Se conservan los archivos en ${WORKDIR}."
fi

# ---------------------------------------------------------------------------
# 12. Pantalla final y opción de reiniciar
# ---------------------------------------------------------------------------
FINISH_MSG="Kernel ${KVERSION}-custom.\n\nha sido instalado exitosamente."
if [[ "$SB_ENABLED" == "yes" ]]; then
    FINISH_MSG+="\n\nSi inscribió Secure Boot, complete la inscripción durante el reinicio."
fi

if whiptail --title "Instalación completada" \
    --yes-button "Reiniciar ahora" --no-button "Reiniciar después" \
    --yesno "$FINISH_MSG" 14 60; then
    sudo reboot
else
    ok "Recuerda reiniciar manualmente para que el nuevo kernel entre en uso."
fi
