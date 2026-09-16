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
#   1.7.1 - Corrección en 7.2 (sched-ext): forzar CONFIG_DEBUG_INFO_BTF por
#           sí solo no bastaba. Depende de "!DEBUG_INFO_NONE" (choice en
#           lib/Kconfig.debug), y un kernel de Debian normal hereda
#           CONFIG_DEBUG_INFO_NONE=y en la config base — 'olddefconfig'
#           descartaba CONFIG_DEBUG_INFO_BTF pese al --enable, sin que
#           faltara 'pahole' para nada. Ahora se desactiva explícitamente
#           CONFIG_DEBUG_INFO_NONE y se selecciona CONFIG_DEBUG_INFO_DWARF5
#           antes de pedir CONFIG_DEBUG_INFO_BTF. El aviso de la sección
#           7.5 también se corrige para apuntar a esta causa real.
#   1.7.0 - Las secciones 7.1 (ASUS), 7.2 (sched-ext) y 7.3 (NTSYNC) dejan
#           de forzarse directamente: ahora cada una pregunta por separado
#           vía 'whiptail --yesno' propio, con su propia explicación. Nada
#           se activa sin que el usuario lo confirme explícitamente.
#           * 7.1 ASUS: se añade detección DMI (sys_vendor contra
#             /sys/class/dmi/id/sys_vendor) que NO decide nada por sí sola
#             — solo cambia el texto de la pregunta y qué botón queda
#             resaltado por defecto (Sí si se detecta ASUS, No si no).
#             La decisión sigue siendo siempre del usuario.
#           * 7.2 sched-ext: el texto explica el coste real de activarlo
#             (CONFIG_DEBUG_INFO_BTF vía pahole alarga el build y añade
#             símbolos de depuración extra al kernel).
#           * 7.3 NTSYNC: el texto deja claro que solo aporta algo si se
#             usa Wine/Proton.
#           Se introducen $ASUS_APPLIED, $SCHED_EXT_APPLIED y
#           $NTSYNC_APPLIED (mismo patrón que $BORE_APPLIED) para que la
#           sección 7.5 solo avise si el símbolo esperado no quedó activo
#           CUANDO el usuario sí lo pidió — antes los avisos eran
#           incondicionales porque el forzado también lo era. También se
#           actualiza el mensaje final para que no mencione "coexistencia
#           sched-ext" si el usuario rechazó sched-ext en la 7.2, aunque sí
#           se haya aplicado el parche de coexistencia de la sección 6.4.
#   1.6.1 - Dos cambios:
#           * Corregida la cabecera del changelog: la línea "Historial de
#             versiones:" había quedado duplicada por error al escribir la
#             entrada 1.6.0 (puramente cosmético, sin efecto en la
#             ejecución, pero se deja limpio).
#           * Nueva sección 7.3: se fuerza CONFIG_NTSYNC=y (primitivas de
#             sincronización NT que usa Wine/Proton para juegos). Mismo
#             patrón que ASUS (7.1) y sched-ext (7.2): forzado directo, sin
#             pregunta whiptail, porque no es experimental ni tiene
#             contrapartida negativa conocida — solo activa un driver más.
#             Comprobado con el propio César que Debian testing NO lo trae
#             activado por defecto (a diferencia de ASUS/sched-ext, que sí),
#             así que aquí forzarlo sí aporta algo real.
#   1.6.0 - El kernel instalado ya no usa siempre el sufijo fijo "-custom":
#           ahora es "-custom-${MARCH_TAG}" (generic/v3/znver3, según lo
#           que de verdad se haya aplicado en la sección 5.5 — nunca lo
#           que se ofreció o eligió si al final no se pudo usar). Motivo:
#           antes, la única forma de saber qué microarquitectura se había
#           compilado era revisar el log de build, que la sección 11
#           puede borrar sin dejar rastro. Ahora basta con 'uname -r' o
#           'dpkg -l | grep custom' para verlo, sin depender de ningún log.
#           Se actualizaron todos los puntos que daban por hecho el
#           sufijo "-custom" fijo: el propio LOCALVERSION del build, el
#           glob que busca los .deb generados, el patrón de detección de
#           kernels -custom antiguos en la sección 10.5 (ahora
#           'linux-image-*-custom-*', para seguir cubriendo las tres
#           variantes al limpiar) y el mensaje final.
#   1.5.2 - Corrección de bug real (reportado en uso): la instalación
#           automática de 'lld' (sección 0.1) podía fallar en silencio
#           porque el 'apt update' solo se ejecutaba si faltaba algo de
#           $DEPS — en una máquina donde ya estaba todo eso instalado (caso
#           típico en ejecuciones repetidas), 'apt install lld' se
#           intentaba contra un índice de apt potencialmente desactualizado,
#           con el error silenciado. Se añade la bandera $APT_UPDATED para
#           refrescar el índice exactamente una vez por ejecución cuando
#           haga falta (nunca cero, nunca dos), y se deja de silenciar la
#           salida de 'apt install lld': ahora se captura y solo se muestra
#           si el intento falla. De paso, se corrige un bug introducido al
#           escribir este mismo arreglo: con 'set -e' activo, asignar
#           LLD_INSTALL_LOG="$(...)" como sentencia suelta habría abortado
#           el script ENTERO si 'apt install' fallaba (justo lo contrario
#           del fail-soft buscado); la asignación se mueve dentro de la
#           condición del 'if' para que 'set -e' no la trate como fallo del
#           script. Verificado con una simulación forzando el fallo de apt.
#   1.5.1 - Cuatro ajustes de robustez/precisión, sin cambios de fondo en el
#           flujo de compilación:
#           * Eliminada la sección 7.0 ('make localmodconfig'): con ccache
#             ya en su sitio (1.3.0), el beneficio de recortar módulos por
#             'lsmod' es marginal frente al riesgo de que falte un driver
#             si se conecta hardware distinto más tarde.
#           * znver3 ahora exige, además de que GCC acepte el flag, que la
#             CPU real detectada sea AMD familia 25 (Zen3/Zen3+/Zen4, que
#             comparten el mismo juego de instrucciones que znver3 usa),
#             comprobado contra /proc/cpuinfo (vendor_id + cpu family). Que
#             GCC acepte '-march=znver3' no implica que la CPU de la
#             máquina lo sea (GCC puede generar código para cualquier
#             microarquitectura que conozca, no solo la real) — mismo tipo
#             de fallo silencioso que 'mold' en la 1.3.0, aquí evitado
#             antes de llegar a ofrecer la opción.
#           * Corregida la descripción de la opción znver3 en el menú:
#             decía "específico para tu Zen 3", pero el Ryzen 7 6800HS es
#             Zen 3+, no Zen 3 clásico (aunque znver3 sigue siendo el
#             target correcto, al no existir un target de GCC/Kbuild
#             separado para Zen 3+). Ahora dice "Zen 3/Zen 3+".
#           * Ampliado el texto del diálogo de confirmación de BORE para
#             dejar explícito que es una modificación opcional y
#             EXPERIMENTAL del scheduler, no necesaria para que el kernel
#             funcione ni para usar sched_ext, con resultados dependientes
#             del hardware/uso, y fail-soft si falla al aplicarse.
#   1.5.0 - CORRECCIÓN DE BUG REAL (reportado en uso): 'mold' hacía fallar
#           la compilación con "unknown linker" / "Sorry, this linker is
#           not supported" en la fase de syncconfig, ANTES de compilar
#           nada. Causa raíz confirmada contra el propio scripts/
#           ld-version.sh del kernel: Kbuild solo acepta un $(LD) cuyo
#           --version empiece por "GNU ld" o contenga "LLD"; la salida de
#           mold ("mold X.Y.Z (compatible with GNU ld)") no cumple
#           ninguna de las dos condiciones, así que Kbuild lo rechaza
#           SIEMPRE, en cualquier kernel, no es un problema de esta
#           versión en concreto. La comprobación de la 1.3.0/1.4.x solo
#           validaba que el binario existiera (command -v mold), no que
#           Kbuild lo aceptara, por eso el fail-soft no lo detectó.
#           Sustituido por 'ld.lld' (LLVM), que SÍ está reconocido por
#           Kbuild (comprobado igual, contra ld-version.sh) y cumple el
#           mismo objetivo (linker más rápido que 'ld' en el enlazado).
#           La detección ahora comprueba también la salida real de
#           --version, no solo si el binario existe.
#   1.4.1 - Corrección menor de seguridad: el fichero temporal de prueba
#           de compilador (sección 5.5) usaba /tmp/march-test-$$.c, con
#           nombre predecible (PID) en /tmp compartido → vulnerable a
#           symlink attack. Cambiado a mktemp (nombre no predecible,
#           creación atómica).
#   1.4.0 - Nueva sección 5.5: optimización opcional de microarquitectura de
#           CPU (march/mtune), vía KCFLAGS. Opt-in (por defecto: sin
#           cambios, igual que Debian), con comprobación real de que el
#           compilador soporta el target antes de ofrecerlo (fail-soft, si
#           no lo soporta se sigue sin optimizar). Dos niveles: x86-64-v3
#           (portable a CPUs Haswell/Excavator-Zen1+) y znver3 (específico,
#           ajusta también el modelo de coste/scheduling al núcleo
#           concreto, sin portabilidad ni entre generaciones Zen).
#   1.3.1 - Corrección: KDEB_COMPRESS=xz de la 1.3.0 no cumplía su objetivo
#           declarado. xz YA es el valor por defecto de dpkg-deb (fijarlo
#           no cambiaba nada) y además es más LENTO que gzip al empaquetar
#           (hay un parche del propio kernel upstream que añade soporte de
#           compresión configurable precisamente para poder usar gzip en
#           builds de desarrollo por ser "mucho más rápido que xz"). Se
#           cambia a KDEB_COMPRESS=gzip, que si acelera el empaquetado a
#           cambio de un .deb algo más grande (solo importa si lo mueves/
#           archivas; para instalar localmente es irrelevante).
#   1.3.0 - Tanda de optimizaciones y correcciones de robustez:
#           * ccache (obligatorio, siempre disponible en repos Debian):
#             acelera recompilaciones sobre el mismo árbol (--force, tocar
#             sección 7.x). CCACHE_DIR bajo WORKDIR, tope de 10G.
#           * mold como linker (opcional/fail-soft: si no está disponible
#             en los repos, se usa 'ld' sin abortar). Se pasa vía LD=mold
#             a bindeb-pkg; ahorra tiempo en la fase de enlazado.
#           * KDEB_COMPRESS=xz para empaquetar los .deb más rápido
#             (corregido en 1.3.1, ver arriba: el efecto real era el
#             contrario).
#           * Nueva sección 7.0: 'make localmodconfig' opcional (pregunta
#             whiptail, igual que BORE), para compilar solo los módulos
#             que tu hardware usa ahora mismo. Se coloca ANTES de forzar
#             ASUS/sched-ext/BORE, para que esos forzados sobrevivan al
#             recorte pase lo que pase.
#           * Se consolidan las llamadas a 'make olddefconfig' de las
#             secciones 7.1/7.2/7.3 en una sola pasada final.
#           * Comprobación de espacio en disco subida de 50GB a 60GB para
#             dejar margen a la caché de ccache.
#           * Nueva sección 10.5: gestión del ciclo de vida de kernels
#             -custom antiguos (checklist whiptail para desinstalarlos),
#             ya que a diferencia de los kernels oficiales de Debian estos
#             no se limpian solos con 'apt autoremove' y podían llenar
#             /boot con el tiempo.
#           * Parche BORE: se deja de usar 'git clone --depth=1' a ciegas
#             sobre la rama por defecto sin más control. Ahora se resuelve
#             y muestra el commit exacto aplicado (registrado también en
#             un fichero bore-commit-<version>.txt), se intenta verificar
#             la firma del commit (fail-soft: si no hay firma o clave, se
#             avisa pero no se aborta), y se añade la variable opcional
#             BORE_PIN_COMMIT para fijar el parche a un commit concreto en
#             vez de usar siempre la punta de la rama.
#           * Secure Boot: si está activo, la pantalla final ya NO ofrece
#             "Reiniciar ahora". Se fuerza reinicio manual con aviso de
#             completar antes la firma/inscripción MOK (antes, el botón de
#             reinicio inmediato estaba disponible igual, sin comprobar
#             nada, pudiendo dejar el sistema sin arrancar).
#   1.2.1 - Se añade --allow-downgrades a la instalación de los .deb
#           cuando se usa --force, porque el contador de revisión
#           Debian (el "-1"/"-2" del número de paquete) vive dentro del
#           árbol de fuentes extraído: si ese árbol se volvió a extraer
#           desde cero entre una compilación anterior ya instalada y
#           esta, el contador se reinicia y el .deb nuevo puede quedar
#           con una revisión MENOR que la instalada, lo que apt
#           interpreta como downgrade y rechaza sin este flag.
#   1.2.0 - Se añade soporte opcional para el parche BORE (scheduler) del
#           repo firelzrd/bore-scheduler: comprobación de disponibilidad
#           para la serie del kernel ANTES de ofrecerlo (si no hay parche
#           para esa serie, no se pregunta), pregunta whiptail (aplicar
#           sí/no), verificación con --dry-run antes de tocar el código
#           fuente de verdad, filosofía "fail-soft" (si no hay parche o
#           falla al aplicarse, el kernel se compila igual sin BORE, sin
#           abortar el build — mismo patrón que ya usa este script con
#           asusd en la sección 3), y detección de "parche ya aplicado"
#           para no romper reintentos con --force sobre el mismo árbol de
#           fuentes reutilizado. Se fuerza CONFIG_SCHED_BORE tras aplicar
#           el parche, igual que se hace con las opciones ASUS/sched-ext.
#           Se ofrece además, bajo la misma filosofía fail-soft, un
#           posible parche adicional de coexistencia BORE + sched-ext si
#           el repo lo trae para tu serie (nota: no se puede garantizar
#           que ese parche exista siempre como fichero independiente; si
#           no se encuentra, simplemente no se ofrece). Se añaden 'git' y
#           'patch' a las dependencias.
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
VERSION="1.7.1"
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

# Repo de terceros con el parche BORE (opcional). Ver secciones 6.3/6.4.
BORE_REPO_URL="https://github.com/firelzrd/bore-scheduler.git"

# Opcional: si quieres fijar el parche BORE a un commit concreto (más
# reproducible entre ejecuciones) en vez de usar siempre la punta de la
# rama por defecto, pon aquí el hash completo. Vacío = usar siempre lo
# último disponible (comportamiento anterior).
BORE_PIN_COMMIT=""

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
# Funciones auxiliares para el parche BORE opcional (secciones 6.3/6.4)
# ---------------------------------------------------------------------------
#
# Se buscan los parches por contenido de ruta/nombre de archivo en vez de
# asumir una carpeta fija (p. ej. "patches/stable/linux-X.Y-bore/"), porque
# el repo reorganiza su estructura de vez en cuando y no queremos que el
# script se quede "ciego" (sin ofrecer nada) solo por un cambio de carpeta.
# Si de verdad no hay nada para tu serie, la búsqueda simplemente no
# encuentra nada y el script no te lo ofrece (fail-soft, ver 6.3/6.4).

find_bore_main_patch() {
    # Parche principal de BORE para $KMAJOR.$KMINOR. Se excluyen los
    # parches complementarios (SMT / wakeup) que el mismo repo incluye,
    # para no ofrecerlos por error como si fueran el parche BORE en sí.
    find "$BORE_REPO_DIR" -type f -iname '*.patch' 2>/dev/null \
        | grep -iE "(^|[^0-9])${KMAJOR}\.${KMINOR}([^0-9]|$)" \
        | grep -i 'bore' \
        | grep -viE '(smt|wakeup)' \
        | sort -V | tail -n1
}

find_bore_coexist_patch() {
    # Posible parche de coexistencia BORE + sched-ext. No se puede
    # garantizar que exista siempre como fichero independiente en el
    # repo; se intenta primero con coincidencia de serie exacta y, si no
    # hay nada, con una búsqueda genérica (por si no está atado a una
    # versión de kernel concreta).
    local match
    match="$(find "$BORE_REPO_DIR" -type f -iname '*.patch' 2>/dev/null \
        | grep -iE '(sched.?ext|(^|/)scx|addition)' \
        | grep -iE "(^|[^0-9])${KMAJOR}\.${KMINOR}([^0-9]|$)" \
        | sort -V | tail -n1)"
    if [[ -z "$match" ]]; then
        match="$(find "$BORE_REPO_DIR" -type f -iname '*.patch' 2>/dev/null \
            | grep -iE '(sched.?ext|(^|/)scx|addition)' \
            | sort -V | tail -n1)"
    fi
    echo "$match"
}

apply_patch_safely() {
    # $1 = ruta al .patch ya localizado. $2 = etiqueta para los mensajes.
    # Debe ejecutarse con $PWD dentro del árbol de fuentes del kernel.
    local patch_file="$1" label="$2"

    # ¿Ya está aplicado? (p. ej. reintento con --force sobre el mismo
    # SRC_DIR reutilizado de una ejecución anterior). Un --dry-run en
    # modo reverso que tiene éxito significa "esto ya está aplicado".
    if patch -p1 --dry-run --silent -R < "$patch_file" >/dev/null 2>&1; then
        ok "El parche de ${label} ya estaba aplicado en el árbol de fuentes (reutilizado). No se vuelve a tocar."
        return 0
    fi

    if ! patch -p1 --dry-run --silent < "$patch_file" >/dev/null 2>&1; then
        warn "El parche de ${label} no se pudo aplicar en modo de ensayo (--dry-run) sobre el kernel ${KVERSION}. Se continúa SIN ${label}; el resto de la compilación sigue con normalidad."
        return 1
    fi

    if patch -p1 < "$patch_file"; then
        ok "Parche de ${label} aplicado correctamente."
        return 0
    else
        warn "El parche de ${label} pasó el --dry-run pero falló al aplicarse de verdad. Se continúa SIN ${label}."
        return 1
    fi
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
      gnupg xz-utils git patch ccache)

MISSING=()
for pkg in "${DEPS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done

APT_UPDATED="no"
if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Instalando paquetes que faltan: ${MISSING[*]}"
    sudo apt update && APT_UPDATED="yes"
    sudo apt install -y "${MISSING[@]}"
else
    ok "Todas las dependencias ya están instaladas."
fi

# ---------------------------------------------------------------------------
# 0.1 'ld.lld' (LLVM) como linker opcional, más rápido que 'ld' (GNU/BFD) en
# la fase de enlazado del kernel. Fail-soft: si no está disponible, se
# sigue con 'ld' sin abortar el script.
#
# NOTA (1.5.0): aquí se usaba 'mold'. Se retiró porque Kbuild EXIGE que
# $(LD) --version se identifique como "GNU ld" o contenga el token "LLD"
# (scripts/ld-version.sh) — si no, aborta con "unknown linker" en la fase
# de syncconfig, antes de compilar nada. La salida de mold ("mold X.Y.Z
# (compatible with GNU ld)") no empieza por esos dos tokens exactos, así
# que Kbuild lo rechaza SIEMPRE, en cualquier versión de kernel, lo
# comprobamos contra el propio scripts/ld-version.sh del kernel. No es un
# fallo de disponibilidad (que era lo único que comprobaba el 'command -v'
# de antes) sino de compatibilidad real con Kbuild, por eso la detección
# ahora también valida la salida de --version, no solo si el binario
# existe.
# NOTA (1.5.1): se detectó (en uso real) que este intento de instalación
# podía fallar en silencio si el índice de 'apt' estaba desactualizado: el
# 'apt update' de arriba SOLO se ejecuta si faltaba algo de $DEPS, así que
# en una máquina donde ya estaba todo eso instalado (caso típico en
# ejecuciones repetidas de este script), 'apt install lld' se intentaba
# contra un índice potencialmente viejo, sin haberlo refrescado antes. Se
# usa la bandera $APT_UPDATED para refrescar el índice aquí exactamente
# una vez si no se hizo ya arriba (nunca cero veces, que era el bug; nunca
# dos, que sería desperdiciar red/tiempo sin necesidad). Además, ya no se
# silencia la salida de 'apt install': se captura y solo se muestra si el
# intento falla, para poder ver el motivo real en vez de un aviso genérico.
LLD_FLAGS=()
lld_ld_usable() {
    command -v ld.lld >/dev/null 2>&1 && ld.lld --version 2>/dev/null | grep -q LLD
}
if lld_ld_usable; then
    ok "'ld.lld' ya está instalado y Kbuild lo reconoce; se usará como linker para acelerar el enlazado."
    LLD_FLAGS=(LD=ld.lld)
else
    log "Intentando instalar 'lld' (linker opcional, más rápido que 'ld' en la fase de enlazado del kernel)..."
    [[ "$APT_UPDATED" == "no" ]] && { sudo apt update && APT_UPDATED="yes"; }
    # OJO: el script usa 'set -e'. Si esta asignación fuera una sentencia
    # suelta (LLD_INSTALL_LOG="$(...)"), un fallo de 'apt install' abortaría
    # el script ENTERO ahí mismo, antes de llegar siquiera al 'warn' de
    # abajo — justo lo contrario de "fail-soft". Por eso la asignación va
    # dentro de la condición del 'if': así 'set -e' no la trata como fallo
    # del script, solo como una rama más a evaluar.
    if LLD_INSTALL_LOG="$(sudo apt install -y lld 2>&1)" && lld_ld_usable; then
        ok "'lld' instalado correctamente; se usará como linker."
        LLD_FLAGS=(LD=ld.lld)
    else
        warn "'lld' no se pudo instalar o Kbuild no lo reconoce. Se usará el linker por defecto (ld); el kernel se compila igual."
        echo "${LLD_INSTALL_LOG:-}" >&2
    fi
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ---------------------------------------------------------------------------
# 0.2 ccache: acelera recompilaciones sobre el mismo árbol de fuentes
# ---------------------------------------------------------------------------
#
# La primera compilación de una versión nueva tarda igual (caché vacía). Las
# siguientes sobre el mismo árbol (--force tras tocar una opción de la
# sección 7.x, probar BORE sí/no, etc.) pueden bajar de horas a minutos,
# porque solo se recompilan los objetos que realmente cambiaron.
export CCACHE_DIR="${WORKDIR}/.ccache"
export PATH="/usr/lib/ccache:${PATH}"
mkdir -p "$CCACHE_DIR"
ccache --max-size=10G >/dev/null 2>&1 || true

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
if (( AVAIL_GB < 60 )); then
    error "Solo hay ${AVAIL_GB}GB libres en ${WORKDIR}. Se recomiendan al menos 60GB (50GB para compilar con todos los módulos del kernel de Debian + margen para la caché de ccache, tope 10GB)."
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
_KVERSION_REST="${KVERSION#*.}"
KMINOR="${_KVERSION_REST%%.*}"
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
# 5.5 Optimización opcional de microarquitectura de CPU (march/mtune)
# ---------------------------------------------------------------------------
#
# Por defecto el kernel se compila para el baseline genérico de x86-64 (lo
# que informalmente se llama x86-64-v1), igual que el kernel oficial de
# Debian: sin esto, ni ccache ni ld.lld cambian ninguna instrucción generada,
# solo cachean/enlazan más rápido. Kbuild respeta la variable KCFLAGS para
# añadir flags extra de compilador sin tocar el resto de la config.
#
# Se ofrecen dos niveles, ambos opcionales (por defecto: sin cambios):
#   - x86-64-v3: baseline portable a cualquier CPU moderna que lo soporte
#     (Intel Haswell 2013+ / AMD Excavator-Zen1 2015+ en adelante).
#   - znver3: además del mismo juego de instrucciones que v3, ajusta el
#     modelo de coste/scheduling al núcleo Zen 3 concreto. Más específico,
#     mejor aprovechado en TU CPU, pero no portable ni siquiera a otra
#     generación Zen distinta.
#
# ADVERTENCIA importante: a diferencia de una app de usuario mal compilada
# (que simplemente crashea), un kernel compilado con instrucciones que la
# CPU no soporta puede fallar durante el arranque. El kernel de Debian
# sigue instalado en paralelo (no se sobreescribe), así que el peor caso es
# elegir "Advanced options for Debian" en GRUB y arrancar con el de serie.
#
# NOTA: 'znver3' solo se ofrece si, además de que GCC acepte el flag, la
# CPU detectada es realmente AMD familia 25 (Zen3/Zen3+/Zen4 en adelante,
# que incluyen el mismo juego de instrucciones que znver3 usa). Que GCC
# acepte '-march=znver3' NO significa que la CPU de esta máquina lo sea:
# GCC puede generar código para cualquier microarquitectura que conozca,
# aunque no coincida con la CPU real (igual que pasó con 'mold', que
# "existía" pero no era compatible; aquí el flag "existe" mas no implica
# que la CPU sea la adecuada). Se comprueba contra /proc/cpuinfo, no
# contra el string de 'model name' (que varía de formato entre BIOS).
CPU_MARCH_FLAGS=()
# MARCH_TAG queda reflejado en el sufijo del kernel instalado (ver sección 8:
# LOCALVERSION=-custom-${MARCH_TAG}), para poder comprobar con 'uname -r' qué
# se compiló de verdad sin depender del log de build (que la sección 11 puede
# borrar). Por defecto "generic"; solo cambia si el flag se aplicó de
# verdad, nunca si solo se ofreció/eligió en el menú.
MARCH_TAG="generic"
CPU_MODEL="$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')"
CPU_VENDOR="$(grep -m1 '^vendor_id' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')"
CPU_FAMILY="$(grep -m1 '^cpu family' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')"

CPU_IS_ZEN3_OR_LATER="no"
if [[ "$CPU_VENDOR" == "AuthenticAMD" && "$CPU_FAMILY" =~ ^[0-9]+$ && "$CPU_FAMILY" -ge 25 ]]; then
    CPU_IS_ZEN3_OR_LATER="yes"
fi

GCC_ZNVER3_OK="no"
GCC_V3_OK="no"
MARCH_TEST_C="$(mktemp --suffix=.c)"
echo "int main(void){return 0;}" > "$MARCH_TEST_C"
if gcc -march=znver3 -o /dev/null "$MARCH_TEST_C" >/dev/null 2>&1; then
    GCC_ZNVER3_OK="yes"
fi
if gcc -march=x86-64-v3 -o /dev/null "$MARCH_TEST_C" >/dev/null 2>&1; then
    GCC_V3_OK="yes"
fi
rm -f "$MARCH_TEST_C"

# znver3 solo entra en el menú si además de que GCC lo soporte, la CPU
# real detectada es AMD Zen3/Zen3+ (o posterior, compatible hacia atrás).
OFFER_ZNVER3="no"
[[ "$GCC_ZNVER3_OK" == "yes" && "$CPU_IS_ZEN3_OR_LATER" == "yes" ]] && OFFER_ZNVER3="yes"

if [[ "$OFFER_ZNVER3" == "yes" || "$GCC_V3_OK" == "yes" ]]; then
    MARCH_MENU_ITEMS=("generic" "Sin cambios (igual que el kernel de Debian, máxima portabilidad)")
    [[ "$GCC_V3_OK" == "yes" ]] && MARCH_MENU_ITEMS+=("v3" "x86-64-v3 (portable a CPUs Haswell/Excavator-Zen1 en adelante)")
    [[ "$OFFER_ZNVER3" == "yes" ]] && MARCH_MENU_ITEMS+=("znver3" "znver3 (Zen 3/Zen 3+, optimizado para Ryzen 6000 y similares)")

    MARCH_CHOICE="$(whiptail --title "Optimización de CPU (opcional)" --menu \
        "CPU detectada: ${CPU_MODEL:-desconocida}\n\nPor defecto se compila para el baseline genérico (igual que Debian). Puedes optar por optimizar para tu CPU concreta a cambio de perder portabilidad del .deb a otras máquinas.\n\nElige una opción:" \
        20 78 3 \
        "${MARCH_MENU_ITEMS[@]}" \
        3>&1 1>&2 2>&3)" || MARCH_CHOICE="generic"

    case "$MARCH_CHOICE" in
        znver3)
            if [[ "$OFFER_ZNVER3" == "yes" ]]; then
                CPU_MARCH_FLAGS=(KCFLAGS="-march=znver3 -mtune=znver3")
                MARCH_TAG="znver3"
                ok "Se compilará optimizado para znver3 (Zen 3/Zen 3+)."
            else
                warn "znver3 no es válido en esta máquina (CPU no reconocida como Zen3/Zen3+ o GCC no lo soporta). Se compila sin optimización de CPU."
            fi
            ;;
        v3)
            if [[ "$GCC_V3_OK" == "yes" ]]; then
                CPU_MARCH_FLAGS=(KCFLAGS="-march=x86-64-v3 -mtune=x86-64-v3")
                MARCH_TAG="v3"
                ok "Se compilará para el baseline x86-64-v3."
            else
                warn "El compilador no soporta '-march=x86-64-v3'. Se compila sin optimización de CPU."
            fi
            ;;
        *)
            log "Se compila para el baseline genérico (sin optimización de CPU)."
            ;;
    esac
else
    log "No hay ninguna optimización de CPU aplicable en esta máquina (GCC demasiado antiguo para x86-64-v3, y znver3 no aplica por CPU o por GCC). Se compila sin optimización de CPU."
fi

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
# 6.3 Parche opcional: BORE (scheduler)
# ---------------------------------------------------------------------------
#
# BORE (firelzrd/bore-scheduler) es un parche de terceros, opcional, que
# modifica el scheduler CFS/EEVDF para priorizar procesos con ráfagas
# cortas de CPU (más responsividad bajo carga). No es necesario para que
# el kernel funcione ni para nada de lo que ya hace este script (ASUS,
# sched-ext); es puramente una mejora que puedes elegir o no.
#
# IMPORTANTE: esto tiene que pasar ANTES de la sección 7 (preparar el
# .config), porque el parche añade el símbolo CONFIG_SCHED_BORE al
# Kconfig del scheduler. Si se aplicara después de generar el .config con
# 'olddefconfig', el símbolo todavía no existiría en el árbol de Kconfig
# en ese momento y 'olddefconfig' lo descartaría en silencio (el mismo
# fallo que ya contemplasteis con CONFIG_SCHED_CLASS_EXT en 7.2).
#
# Filosofía "fail-soft", igual que con asusd (sección 3): si el parche no
# existe para esta serie, o si existe pero no aplica limpiamente
# (--dry-run falla), NUNCA se aborta el build completo por esto. En el
# peor caso te quedas sin BORE pero con tu kernel de siempre compilando
# con normalidad.

BORE_APPLIED="no"
BORE_COEXIST_APPLIED="no"
BORE_REPO_DIR="${WORKDIR}/bore-scheduler"
BORE_COMMIT="desconocido"
BORE_SIGNED="no"

log "Comprobando si hay parche BORE disponible para la serie ${KMAJOR}.${KMINOR}..."

# NOTA DE CONFIANZA: a diferencia del kernel (sección 6/6.1, verificado con
# SHA256 + firma PGP contra huellas fijas), este es un repo de terceros sin
# el mismo nivel de control. Como mínimo, se resuelve y muestra SIEMPRE el
# commit exacto que se va a aplicar (ver más abajo) para que la decisión sea
# informada, y se intenta (fail-soft) verificar la firma del commit por si el
# mantenedor firma su historial.
if [[ -n "$BORE_PIN_COMMIT" ]]; then
    # Con un commit fijado, necesitamos el historial completo (no shallow)
    # para poder hacer checkout de cualquier punto pasado, no solo la punta.
    if [[ ! -d "$BORE_REPO_DIR/.git" ]]; then
        rm -rf "$BORE_REPO_DIR"
        git clone --quiet "$BORE_REPO_URL" "$BORE_REPO_DIR" \
            || warn "No se pudo clonar el repo de BORE. El parche BORE no estará disponible en esta ejecución."
    fi
    if [[ -d "$BORE_REPO_DIR/.git" ]]; then
        (cd "$BORE_REPO_DIR" && git fetch --quiet --all && git checkout --quiet "$BORE_PIN_COMMIT") \
            || warn "No se pudo fijar el repo de BORE al commit ${BORE_PIN_COMMIT} indicado en BORE_PIN_COMMIT. Se usa lo que haya en el árbol local."
    fi
else
    if [[ -d "$BORE_REPO_DIR/.git" ]]; then
        (cd "$BORE_REPO_DIR" && git pull --ff-only --quiet) \
            || warn "No se pudo actualizar el repo local de BORE (¿sin conexión?). Se usa la copia ya descargada."
    else
        rm -rf "$BORE_REPO_DIR"
        git clone --quiet --depth=1 "$BORE_REPO_URL" "$BORE_REPO_DIR" \
            || warn "No se pudo clonar el repo de BORE. El parche BORE no estará disponible en esta ejecución."
    fi
fi

if [[ -d "$BORE_REPO_DIR/.git" ]]; then
    BORE_COMMIT="$(git -C "$BORE_REPO_DIR" rev-parse HEAD 2>/dev/null || echo "desconocido")"
    # Intento fail-soft de verificar la firma del commit. No todos los repos
    # firman su historial ni tenemos por qué tener la clave del mantenedor en
    # el llavero ($GNUPGHOME, el mismo usado para las claves de kernel.org):
    # si falla, simplemente se avisa más abajo, nunca se aborta por esto.
    if git -C "$BORE_REPO_DIR" verify-commit HEAD >/dev/null 2>&1; then
        BORE_SIGNED="yes"
    fi
fi

BORE_PATCH_FILE=""
if [[ -d "$BORE_REPO_DIR" ]]; then
    BORE_PATCH_FILE="$(find_bore_main_patch)"
fi

if [[ -z "$BORE_PATCH_FILE" ]]; then
    warn "No hay parche BORE disponible todavía para la serie ${KMAJOR}.${KMINOR} (es habitual en series muy recientes: el mantenedor tarda un tiempo en adaptarlo). Se continúa sin ofrecerlo."
else
    ok "Parche BORE encontrado para la serie ${KMAJOR}.${KMINOR}: $(basename "$BORE_PATCH_FILE")"

    if [[ "$BORE_SIGNED" == "yes" ]]; then
        TRUST_NOTE="Commit: ${BORE_COMMIT}\nFirma del commit: verificada."
    else
        TRUST_NOTE="Commit: ${BORE_COMMIT}\nFirma del commit: SIN verificar (repo de terceros sin firma reconocida; a diferencia del kernel, que sí se verifica por SHA256+PGP)."
    fi

    if whiptail --title "Instalador de Kernel csr79a" \
        --yesno "Se encontró el parche BORE (scheduler) para la serie ${KMAJOR}.${KMINOR}:\n\n$(basename "$BORE_PATCH_FILE")\n\n${TRUST_NOTE}\n\nIMPORTANTE:\nBORE es una modificación OPCIONAL y EXPERIMENTAL del scheduler del kernel. No es necesario para que el kernel funcione ni para utilizar sched_ext.\n\nSu objetivo es experimentar con la respuesta del sistema bajo determinadas cargas. Puede mejorar la responsividad en algunos escenarios, pero los resultados dependen del hardware y del uso del sistema.\n\nSi algo falla al aplicar el parche, el kernel se compilará igualmente sin BORE.\n\n¿Deseas aplicar este parche experimental?" \
        22 76; then
        if apply_patch_safely "$BORE_PATCH_FILE" "BORE"; then
            BORE_APPLIED="yes"
            echo "${BORE_COMMIT}" > "${WORKDIR}/bore-commit-${KVERSION}.txt"
            log "Commit BORE aplicado registrado en ${WORKDIR}/bore-commit-${KVERSION}.txt"
        fi
    else
        log "Se omite el parche BORE por elección del usuario."
    fi
fi

# ---------------------------------------------------------------------------
# 6.4 Parche opcional: coexistencia BORE + sched-ext
# ---------------------------------------------------------------------------
#
# NOTA DE FIABILIDAD: a diferencia del parche BORE principal, no se puede
# garantizar que este parche de "coexistencia" exista siempre como
# fichero independiente en el repo de firelzrd. Por eso la búsqueda es
# "best effort": si no encuentra nada, simplemente no se ofrece — eso no
# es un fallo, es el comportamiento fail-soft esperado.
#
# Nota técnica, para que sepas que no es indispensable: aunque tengas
# sched-ext instalado y en uso (scx_loader/scxctl/tu GUI), este parche NO
# es necesario para que ambos convivan. sched-ext, cuando activas un
# scheduler scx_*, toma el control de esas tareas por completo (fuera de
# la clase CFS/EEVDF que BORE modifica); al pararlo, el control vuelve a
# CFS/BORE. Se ofrece igualmente por si el mantenedor documenta en el
# futuro algún ajuste real de compatibilidad entre ambos.

if [[ "$BORE_APPLIED" == "yes" ]]; then
    log "Comprobando si hay parche de coexistencia BORE + sched-ext disponible..."
    BORE_COEXIST_PATCH_FILE="$(find_bore_coexist_patch)"

    if [[ -z "$BORE_COEXIST_PATCH_FILE" ]]; then
        warn "No se encontró ningún parche de coexistencia BORE + sched-ext en el repo. Se continúa sin él (no afecta a tu uso de sched-ext, ver nota técnica arriba)."
    else
        ok "Parche de coexistencia encontrado: $(basename "$BORE_COEXIST_PATCH_FILE")"
        if whiptail --title "Instalador de Kernel csr79a" \
            --yesno "Se encontró un posible parche adicional de coexistencia BORE + sched-ext:\n\n$(basename "$BORE_COEXIST_PATCH_FILE")\n\nNo es necesario para que sched-ext y BORE convivan (son intercambiables en caliente), pero puedes aplicarlo igualmente. Si falla, el kernel se compila igual con BORE y sin este extra.\n\n¿Deseas aplicarlo?" \
            16 74; then
            if apply_patch_safely "$BORE_COEXIST_PATCH_FILE" "coexistencia BORE+sched-ext"; then
                BORE_COEXIST_APPLIED="yes"
            fi
        else
            log "Se omite el parche de coexistencia por elección del usuario."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 7. Preparar la configuración (.config)
# ---------------------------------------------------------------------------
log "Preparando configuración a partir del kernel actual ($(uname -r))..."

CURRENT_CONFIG="/boot/config-$(uname -r)"
[[ -f "$CURRENT_CONFIG" ]] || error "No se encontró ${CURRENT_CONFIG}."

cp "$CURRENT_CONFIG" .config
make olddefconfig

# ---------------------------------------------------------------------------
# 7.1 Opciones de hardware ASUS (asus_armoury y afines): se pregunta,
#     nunca se fuerza. La detección DMI solo informa el texto de la
#     pregunta y el botón por defecto; la decisión es siempre del usuario.
# ---------------------------------------------------------------------------
#
# 'olddefconfig' hereda tal cual las opciones que ya estaban desactivadas
# en la config de origen; si en algún momento CONFIG_ASUS_ARMOURY quedó
# desactivada (p. ej. por arrancar sin querer un kernel antiguo/de serie
# antes de ejecutar este script), esa ausencia se propagaría de build en
# build salvo que se reactive aquí.
ASUS_APPLIED="no"

# DMI: identifica al fabricante real de la máquina (placa/firmware), sin
# necesidad de instalar nada. En un equipo ASUS, sys_vendor suele devolver
# "ASUSTeK COMPUTER INC.". Esto NO decide nada por sí solo: solo cambia el
# texto de la pregunta y qué botón queda resaltado por defecto.
ASUS_SYS_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")"
if [[ "$ASUS_SYS_VENDOR" =~ [Aa][Ss][Uu][Ss] ]]; then
    ASUS_DETECTED="yes"
else
    ASUS_DETECTED="no"
fi

if [[ "$ASUS_DETECTED" == "yes" ]]; then
    ASUS_YESNO_FLAGS=()
    ASUS_MSG="Se ha detectado hardware ASUS en este equipo (fabricante DMI: \"${ASUS_SYS_VENDOR}\").\n\n¿Deseas activar el soporte específico de ASUS (asus_armoury, ASUS WMI, HID) en el kernel?\n\nEsto activa CONFIG_ASUS_WMI, CONFIG_ASUS_ARMOURY, CONFIG_FIRMWARE_ATTRIBUTES_CLASS, CONFIG_ASUS_NB_WMI y CONFIG_HID_ASUS."
else
    ASUS_YESNO_FLAGS=(--defaultno)
    ASUS_MSG="No se ha detectado hardware ASUS en este equipo (fabricante DMI: \"${ASUS_SYS_VENDOR:-desconocido}\").\n\n¿Deseas activar igualmente el soporte específico de ASUS (asus_armoury, ASUS WMI, HID)?\n\nSi tu equipo no es ASUS, estas opciones no tendrán ningún efecto (ni bueno ni malo): los símbolos simplemente no se usan."
fi

if whiptail --title "Instalador de Kernel csr79a" "${ASUS_YESNO_FLAGS[@]}" \
    --yesno "$ASUS_MSG" 16 76; then
    log "Activando opciones de hardware ASUS (asus_armoury y afines)..."
    scripts/config --enable CONFIG_ASUS_WMI
    scripts/config --enable CONFIG_ASUS_ARMOURY
    scripts/config --enable CONFIG_FIRMWARE_ATTRIBUTES_CLASS
    scripts/config --enable CONFIG_ASUS_NB_WMI
    scripts/config --enable CONFIG_HID_ASUS
    ASUS_APPLIED="yes"
else
    log "Se omite el soporte de hardware ASUS por elección del usuario."
fi

# ---------------------------------------------------------------------------
# 7.2 Soporte de sched_ext (scx_*, usado por scx-scheds): opcional, se
#     pregunta. No es hardware, es una decisión con coste real en build.
# ---------------------------------------------------------------------------
#
# CONFIG_SCHED_CLASS_EXT depende de BPF_SYSCALL && BPF_JIT && DEBUG_INFO_BTF
# (kernel/Kconfig.preempt). DEBUG_INFO_BTF necesita 'pahole' en el PATH
# durante la compilación para generar BTF desde DWARF; 'dwarves' (ya está
# en DEPS más arriba) lo provee, pero generar esa información alarga la
# compilación y añade símbolos de depuración extra al kernel resultante.
SCHED_EXT_APPLIED="no"

if whiptail --title "Instalador de Kernel csr79a" \
    --yesno "¿Deseas activar soporte de sched_ext (CONFIG_SCHED_CLASS_EXT)?\n\nEsto permite cargar schedulers BPF de sched-ext (scx_lavd, scx_bpfland, etc.) sin tener que recompilar el kernel más adelante solo por esto.\n\nCOSTE: requiere activar CONFIG_DEBUG_INFO_BTF, que necesita 'pahole' para generar información BTF desde DWARF durante la compilación. Esto alarga el tiempo de build y añade símbolos de depuración extra al kernel resultante.\n\nSi no piensas usar sched-ext (scx_loader/scxctl o similar), puedes decir que no sin perder nada." \
    18 76; then
    log "Activando soporte de sched_ext (CONFIG_SCHED_CLASS_EXT y dependencias)..."
    scripts/config --enable CONFIG_BPF
    scripts/config --enable CONFIG_BPF_SYSCALL
    scripts/config --enable CONFIG_BPF_JIT
    scripts/config --enable CONFIG_BPF_JIT_ALWAYS_ON
    scripts/config --enable CONFIG_BPF_JIT_DEFAULT_ON
    # CONFIG_DEBUG_INFO_BTF depende de "!DEBUG_INFO_NONE" (choice en
    # lib/Kconfig.debug). Un kernel de Debian normal trae
    # CONFIG_DEBUG_INFO_NONE=y heredado en la config base; si no se
    # desactiva aquí y se selecciona explícitamente una variante DWARF,
    # 'olddefconfig' descarta CONFIG_DEBUG_INFO_BTF pese al --enable de
    # abajo, sin que falte 'pahole' para nada.
    scripts/config --disable CONFIG_DEBUG_INFO_NONE
    scripts/config --enable CONFIG_DEBUG_INFO
    scripts/config --enable CONFIG_DEBUG_INFO_DWARF5
    scripts/config --enable CONFIG_DEBUG_INFO_BTF
    scripts/config --enable CONFIG_SCHED_CLASS_EXT
    SCHED_EXT_APPLIED="yes"
else
    log "Se omite el soporte de sched_ext por elección del usuario."
fi

# ---------------------------------------------------------------------------
# 7.3 CONFIG_NTSYNC (primitivas de sincronización NT para Wine/Proton):
#     opcional, se pregunta. Driver independiente, sin dependencias
#     complejas (a diferencia de sched_ext), pero solo aporta algo si
#     usas Wine/Proton.
# ---------------------------------------------------------------------------
NTSYNC_APPLIED="no"

if whiptail --title "Instalador de Kernel csr79a" \
    --yesno "¿Deseas activar CONFIG_NTSYNC (primitivas de sincronización NT)?\n\nEste driver solo aporta algo si usas Wine o Proton (juegos/aplicaciones Windows): mejora el rendimiento de la sincronización de hilos frente a la emulación en espacio de usuario.\n\nSi no usas Wine ni Proton, esta opción no tendrá ningún efecto en tu sistema. Debian no lo trae activado por defecto." \
    14 76; then
    log "Activando CONFIG_NTSYNC (sincronización NT para Wine/Proton)..."
    scripts/config --enable CONFIG_NTSYNC
    NTSYNC_APPLIED="yes"
else
    log "Se omite CONFIG_NTSYNC por elección del usuario."
fi

# ---------------------------------------------------------------------------
# 7.4 Forzar CONFIG_SCHED_BORE si se aplicó el parche BORE (sección 6.3)
# ---------------------------------------------------------------------------
#
# Mismo motivo que en 7.1/7.2/7.3: sin esto, 'olddefconfig' no activa por sí
# solo una opción que en la config de origen (la de tu kernel actual, que
# no tiene BORE) estaba ausente.
if [[ "$BORE_APPLIED" == "yes" ]]; then
    log "Forzando CONFIG_SCHED_BORE (parche BORE aplicado)..."
    scripts/config --enable CONFIG_SCHED_BORE
fi

# ---------------------------------------------------------------------------
# 7.5 Una sola pasada final de 'olddefconfig' para aplicar 7.1/7.2/7.3/7.4
# ---------------------------------------------------------------------------
#
# Antes se llamaba a 'make olddefconfig' una vez por cada bloque. Cada
# llamada relee y regenera todo el árbol de config; no es caro, pero
# tampoco gratis. Se agrupan aquí todos los forzados y se aplica una única
# pasada, con las mismas comprobaciones de después.
#
# Los avisos de abajo solo comprueban lo que el usuario pidió en 7.1/7.2/7.3
# (vía $ASUS_APPLIED/$SCHED_EXT_APPLIED/$NTSYNC_APPLIED): si dijo que no a
# alguna, es normal que el símbolo no esté activado y no hace falta avisar.
make olddefconfig

if [[ "$ASUS_APPLIED" == "yes" ]] && ! grep -q '^CONFIG_ASUS_ARMOURY=y' .config; then
    warn "CONFIG_ASUS_ARMOURY no quedó activado tras 'olddefconfig' pese a haberlo pedido. El kernel se compilará igualmente, pero puede faltar soporte completo de asus_armoury."
fi

if [[ "$SCHED_EXT_APPLIED" == "yes" ]] && ! grep -q '^CONFIG_SCHED_CLASS_EXT=y' .config; then
    warn "CONFIG_SCHED_CLASS_EXT no quedó activado tras 'olddefconfig' pese a haberlo pedido (revisa si la config base tenía CONFIG_DEBUG_INFO_NONE=y y no se pudo desactivar el choice de debug info, o si falta 'pahole' en el PATH). El kernel se compilará igualmente, pero sin soporte de sched_ext."
fi

if [[ "$NTSYNC_APPLIED" == "yes" ]] && ! grep -q '^CONFIG_NTSYNC=y' .config; then
    warn "CONFIG_NTSYNC no quedó activado tras 'olddefconfig' pese a haberlo pedido. El kernel se compilará igualmente, pero sin el driver de sincronización NT para Wine/Proton."
fi

if [[ "$BORE_APPLIED" == "yes" ]] && ! grep -q '^CONFIG_SCHED_BORE=y' .config; then
    warn "CONFIG_SCHED_BORE no quedó activado tras 'olddefconfig' pese a haberse aplicado el parche (puede que esta versión del parche use otro nombre de símbolo). El kernel se compilará igualmente, con el código de BORE presente pero sin activar en la config."
fi

# ---------------------------------------------------------------------------
# 8. Compilar y generar los .deb
# ---------------------------------------------------------------------------
LOGFILE="${WORKDIR}/build-${KVERSION}.log"
log "Compilando el kernel ${KVERSION} con ${JOBS} jobs (esto puede tardar)..."
[[ "${LLD_FLAGS[*]:-}" == "LD=ld.lld" ]] && log "Usando 'ld.lld' como linker."
# KSUFFIX sustituye al "-custom" fijo de versiones anteriores: incluye
# MARCH_TAG (generic/v3/znver3) para que 'uname -r' y el nombre del propio
# paquete .deb digan de verdad qué se compiló, sin depender del log (que la
# sección 11 puede borrar) ni tener que adivinarlo.
KSUFFIX="custom-${MARCH_TAG}"
# gzip, no xz: xz ya era el valor por defecto de dpkg-deb (fijarlo no
# cambiaba nada) y además es más lento de empaquetar que gzip. Con gzip
# el .deb final es algo más grande, pero eso solo importa si lo mueves o
# archivas; para instalarlo en esta misma máquina es irrelevante.
export KDEB_COMPRESS=gzip
make -j"${JOBS}" bindeb-pkg LOCALVERSION="-${KSUFFIX}" "${LLD_FLAGS[@]}" "${CPU_MARCH_FLAGS[@]}" 2>&1 | tee "$LOGFILE"

ok "Compilación terminada. Paquetes .deb generados en ${WORKDIR}."
log "Estadísticas de ccache de esta sesión:"
ccache -s 2>/dev/null || true

# ---------------------------------------------------------------------------
# 9. Instalar los paquetes generados
# ---------------------------------------------------------------------------
cd "$WORKDIR"

shopt -s nullglob
DEBS=(linux-image-"${KVERSION}"-"${KSUFFIX}"_*.deb linux-headers-"${KVERSION}"-"${KSUFFIX}"_*.deb)
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
#
# Además, el sufijo de revisión Debian (el "-1", "-2"... de
# "7.2.5-1") sale de un contador que vive DENTRO del árbol de fuentes
# extraído ($SRC_DIR), no en ningún sitio persistente. Si entre una
# compilación anterior de este mismo KVERSION (ya instalada, con
# revisión más alta) y esta el $SRC_DIR se volvió a extraer desde cero
# (p. ej. respondiste "sí" a "eliminar archivos generados" en la
# sección 11 tras esa compilación anterior), el contador se reinicia
# en 1 y el .deb nuevo queda con una revisión MENOR que la ya
# instalada. Sin --allow-downgrades, apt rechaza la instalación con
# "Error: Se instalaron versiones anteriores...". Se añade junto con
# --reinstall porque es el mismo escenario (--force) el que puede
# producir cualquiera de los dos casos (misma revisión o revisión
# menor) según si $SRC_DIR se reutilizó o se volvió a extraer.
APT_INSTALL_FLAGS=(-y)
[[ "$FORCE" == "yes" ]] && APT_INSTALL_FLAGS+=(--reinstall --allow-downgrades)
sudo apt install "${APT_INSTALL_FLAGS[@]}" "${DEBS[@]/#/./}"

# ---------------------------------------------------------------------------
# 10. Regenerar GRUB
# ---------------------------------------------------------------------------
log "Regenerando GRUB..."
sudo update-grub

# ---------------------------------------------------------------------------
# 10.5 Limpiar kernels -custom antiguos (gestión de ciclo de vida)
# ---------------------------------------------------------------------------
#
# A diferencia de los kernels oficiales de Debian (que 'apt autoremove'
# limpia solo al entrar uno nuevo, vía el metapaquete linux-image-amd64),
# los kernels -custom-* generados por este script no dependen de ningún
# metapaquete y no se retiran solos: sin este paso, /boot puede acabar
# lleno tras varias compilaciones. Se excluyen siempre el kernel recién
# instalado y el que está actualmente en ejecución (por si aún no has
# reiniciado tras una ejecución anterior). El patrón 'linux-image-*-custom-*'
# cubre las tres variantes posibles (generic/v3/znver3), no solo la de esta
# ejecución. Nada viene premarcado: es una elección explícita, no un
# borrado automático.
RUNNING_KVER="$(uname -r)"
mapfile -t OLD_CUSTOM_IMAGES < <(dpkg-query -W -f='${Package}\n' 'linux-image-*-custom-*' 2>/dev/null \
    | grep -vx "linux-image-${KVERSION}-${KSUFFIX}" \
    | grep -vx "linux-image-${RUNNING_KVER}" \
    || true)

if [[ ${#OLD_CUSTOM_IMAGES[@]} -gt 0 ]]; then
    CHECKLIST_ITEMS=()
    for pkg in "${OLD_CUSTOM_IMAGES[@]}"; do
        CHECKLIST_ITEMS+=("$pkg" "" OFF)
    done
    SELECTED_RAW="$(whiptail --title "Limpiar kernels antiguos" --checklist \
        "Se detectaron kernels -custom antiguos instalados en /boot (aparte del recién compilado). Marca los que quieras eliminar para liberar espacio. Ninguno viene premarcado." \
        20 76 8 "${CHECKLIST_ITEMS[@]}" 3>&1 1>&2 2>&3)" || SELECTED_RAW=""

    if [[ -n "$SELECTED_RAW" ]]; then
        eval "SELECTED_IMAGES=(${SELECTED_RAW})"
        SELECTED_HEADERS=()
        for img in "${SELECTED_IMAGES[@]}"; do
            SELECTED_HEADERS+=("${img/linux-image-/linux-headers-}")
        done
        log "Eliminando kernels antiguos seleccionados: ${SELECTED_IMAGES[*]}"
        sudo apt remove -y "${SELECTED_IMAGES[@]}" "${SELECTED_HEADERS[@]}" \
            || warn "No se pudieron eliminar todos los paquetes seleccionados. Revisa manualmente con 'dpkg -l | grep custom'."
        sudo update-grub
    else
        log "No se elimina ningún kernel antiguo (ninguno seleccionado)."
    fi
else
    ok "No hay kernels -custom antiguos que limpiar."
fi

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
FINISH_MSG="Kernel ${KVERSION}-${KSUFFIX}"
[[ "$BORE_APPLIED" == "yes" ]] && FINISH_MSG+=" (con parche BORE$( [[ "$BORE_COEXIST_APPLIED" == "yes" && "$SCHED_EXT_APPLIED" == "yes" ]] && echo " + coexistencia sched-ext" ))"
FINISH_MSG+=".\n\nha sido instalado exitosamente."

if [[ "$SB_ENABLED" == "yes" ]]; then
    # Antes: el botón "Reiniciar ahora" estaba disponible igual, sin
    # comprobar nada, aunque el kernel no esté firmado. Con Secure Boot
    # activo, este script NO firma el kernel (la firma MOK queda en
    # MANUAL.md como paso manual), así que reiniciar sin haberla completado
    # puede dejar el sistema sin arrancar. Por eso aquí ya NO se ofrece
    # reinicio automático: solo un aviso, y el reinicio queda en tus manos.
    FINISH_MSG+="\n\nATENCIÓN: Secure Boot está activo y este kernel NO está firmado por este script. Antes de reiniciar, completa la firma/inscripción MOK descrita en MANUAL.md, o el arranque puede fallar.\n\nPor seguridad, este script NO va a reiniciar automáticamente. Hazlo tú manualmente en cuanto hayas completado ese paso."
    whiptail --title "Instalación completada — Secure Boot activo" --msgbox "$FINISH_MSG" 18 72
    warn "Reinicio NO automático por tener Secure Boot activo. Completa la firma MOK antes de reiniciar manualmente."
else
    if whiptail --title "Instalación completada" \
        --yes-button "Reiniciar ahora" --no-button "Reiniciar después" \
        --yesno "$FINISH_MSG" 14 60; then
        sudo reboot
    else
        ok "Recuerda reiniciar manualmente para que el nuevo kernel entre en uso."
    fi
fi
