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
#   ./build-kernel-debian.sh
#
# Requiere: Debian o derivado, con sudo configurado.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
WORKDIR="${HOME}/kernel-build"
SB_ENABLED="no"

log()   { echo -e "\e[1;34m[*]\e[0m $*"; }
ok()    { echo -e "\e[1;32m[OK]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[!]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Falta el comando '$1'. Instálalo e inténtalo de nuevo."
}

# ---------------------------------------------------------------------------
# 0. Comprobaciones previas
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    error "No ejecutes este script como root directamente. Usa tu usuario normal; se pedirá sudo cuando haga falta."
fi

DEPS=(build-essential libncurses-dev bison flex libssl-dev libelf-dev
      dwarves libdw-dev debhelper fakeroot bc rsync curl jq whiptail mokutil)

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
    --yesno "Versión del Instalador de Kernel csr79a 1.1.0\n\nEste programa descargará, compilará e instalará el último kernel estable desde kernel.org.\n\nEl tiempo dependerá de tu hardware (hilos y RAM disponibles).\n\n¿Desea continuar?" \
    14 60 || exit 0

# ---------------------------------------------------------------------------
# 2. Comprobar espacio en disco
# ---------------------------------------------------------------------------
log "Comprobando espacio en disco disponible..."
AVAIL_GB="$(df --output=avail -BG "$WORKDIR" | tail -1 | tr -d 'G ')"
if (( AVAIL_GB < 20 )); then
    error "Solo hay ${AVAIL_GB}GB libres en ${WORKDIR}. Se recomiendan al menos 20-25GB para compilar."
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

RELEASES_JSON="$(curl -fsSL https://www.kernel.org/releases.json)"
KVERSION="$(echo "$RELEASES_JSON" | jq -r '.releases[] | select(.moniker=="stable") | .version' | head -n1)"

[[ -n "$KVERSION" ]] || error "No se pudo determinar la última versión estable."

ok "Última versión estable: ${KVERSION}"

if uname -r | grep -q "^${KVERSION}"; then
    warn "Ya estás ejecutando el kernel ${KVERSION}. Nada que hacer."
    exit 0
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
DEBS=(linux-image-"${KVERSION}"-custom_*.deb linux-headers-"${KVERSION}"-custom_*.deb)

log "Instalando paquetes: ${DEBS[*]}"
sudo dpkg -i "${DEBS[@]}"

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
