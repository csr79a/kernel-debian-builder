# MANUAL — kernel-debian-builder (Instalador de Kernel csr79a)

## 1. Objetivo del proyecto

Automatizar el flujo completo de compilación de un kernel Linux vanilla en Debian: desde la descarga del código fuente en kernel.org hasta tener el nuevo kernel arrancable desde GRUB, sin herramientas externas a los repos oficiales de Debian, con una interfaz de pantallas interactiva (`whiptail`).

## 2. Requisitos previos

- Debian o derivado (Trixie, Sid, etc.).
- Usuario con permisos de `sudo`.
- Al menos 50GB libres en disco (el script lo comprueba antes de empezar y aborta si no hay suficiente).
- Conexión a internet.

## 3. Preparar los archivos

Si descargaste `build-kernel-debian.sh`, `README.md` y `MANUAL.md` sueltos (no vía `git clone`), primero muévelos juntos a una carpeta y da permisos de ejecución al script:

```bash
mkdir -p ~/kernel-debian-builder
mv build-kernel-debian.sh README.md MANUAL.md ~/kernel-debian-builder/
cd ~/kernel-debian-builder
chmod +x build-kernel-debian.sh
```

Sin `chmod +x`, `./build-kernel-debian.sh` fallará con "Permiso denegado".

## 4. Qué instala el script

Paquetes desde los repos oficiales de Debian:

- `build-essential`
- `libncurses-dev`
- `bison`
- `flex`
- `libssl-dev`
- `libelf-dev`
- `dwarves` (necesario para generar información BTF)
- `libdw-dev` (requerida por `dwarves`/`pahole`)
- `debhelper` (provee `debhelper-compat`, exigido por `make bindeb-pkg`)
- `fakeroot`
- `bc`
- `rsync`
- `curl`
- `jq`
- `whiptail` (interfaz de pantallas)
- `mokutil` (detección de Secure Boot)

## 5. Flujo paso a paso

### 5.1. Pantalla de bienvenida

Muestra el nombre y versión del instalador, una descripción breve, y pide confirmación para continuar.

### 5.2. Comprobación de espacio en disco

Antes de descargar o compilar nada, el script comprueba que haya al menos 50GB libres en el directorio de trabajo (`~/kernel-build`). Si no los hay, se detiene inmediatamente con un mensaje claro, en vez de fallar a mitad de una compilación de 20-30 minutos.

### 5.3. Detección de Secure Boot

El script ejecuta `mokutil --sb-state`:

- **Si está desactivado**: continúa sin más, sin preguntar nada.
- **Si está activado**: avisa de que el kernel compilado no estará firmado y de que UEFI podría rechazar arrancarlo, y pregunta si quieres continuar de todas formas.

**Si decides seguir con Secure Boot activado**, para que el kernel arranque tendrás que firmarlo manualmente con una clave propia (MOK — Machine Owner Key), un proceso de una sola vez:

```bash
# 1. Generar una clave propia (una sola vez en la vida del sistema)
sudo openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv -outform DER -out MOK.der -nodes -days 36500 -subj "/CN=Mi Clave Kernel/"

# 2. Registrarla en el firmware UEFI (pide una contraseña temporal)
sudo mokutil --import MOK.der

# 3. Al reiniciar, aparece una pantalla azul de MokManager donde hay que
#    elegir "Enroll MOK" e introducir esa contraseña para confirmar

# 4. Con la clave ya inscrita, firmar el kernel compilado
sudo /usr/lib/linux-kbuild-<version>/scripts/sign-file sha256 MOK.priv MOK.der /boot/vmlinuz-<version>-custom
```

El paso 3 requiere interacción física en el arranque y no se puede automatizar desde el script.

### 5.4. Detección de versión

El script consulta `https://www.kernel.org/releases.json` y extrae la versión marcada como `stable`. Si ya estás corriendo esa versión, el script termina sin hacer nada — salvo que hayas pasado `--force` (ver sección 6), en cuyo caso continúa igualmente.

### 5.5. Cálculo de jobs de compilación

El script detecta tus hilos (`nproc`) y tu RAM total (`free`), y calcula un valor recomendado con la fórmula:

```
jobs_recomendados = mínimo( hilos_detectados , (RAM_GB - 2) / 2 )
```

Se reservan 2GB fijos para el sistema antes de repartir el resto entre los jobs, asumiendo un pico de hasta ~2GB por proceso de compilación en paralelo. Te muestra ambos datos (hilos y RAM) y el valor recomendado, y te deja elegir entre usarlo o forzar el uso de todos los hilos disponibles (con un aviso si eso supera lo recomendado para tu RAM).

Ejemplos:

| RAM  | Hilos | Jobs recomendados |
|------|-------|--------------------|
| 32GB | 16    | 15                 |
| 16GB | 8     | 7                  |
| 8GB  | 16    | 3                  |

### 5.6. Descarga y verificación

Descarga el `.tar.xz` desde `cdn.kernel.org` y lo verifica en dos pasos:

1. **SHA256** contra el fichero de sumas oficial publicado junto a cada release.
2. **Firma PGP** de ese fichero de sumas, contra las claves oficiales de kernel.org (Linus Torvalds y Greg Kroah-Hartman), identificadas por su huella exacta — no se confía en el "web of trust" ni en el nivel de confianza que gpg le asigne a una clave. Las claves se importan probando tres fuentes en orden, por si alguna estuviera caída: dos keyservers y, como último recurso, el WKD (Web Key Directory) de kernel.org resuelto por HTTPS contra su propio dominio.

Si cualquiera de las dos verificaciones falla, el script se detiene inmediatamente — no compila código sin confirmar que viene de kernel.org sin alterar.

### 5.7. Configuración (.config)

Copia `/boot/config-$(uname -r)` (la configuración del kernel que tienes corriendo ahora mismo) y ejecuta `make olddefconfig`, que adapta esa configuración a las nuevas opciones de la versión más reciente, minimizando el riesgo de perder soporte de hardware o módulos que ya usas.

### 5.8. Forzar opciones de hardware ASUS (asusctl / ROG Control Center)

`make olddefconfig` solo **hereda** lo que ya tenía activado tu kernel actual — no activa opciones nuevas aunque el kernel nuevo ya las soporte. Si tu kernel de origen no traía activadas las opciones de ASUS, esa ausencia se arrastraría de compilación en compilación para siempre. Por eso el script las fuerza explícitamente después de `olddefconfig`:

```
CONFIG_ASUS_WMI
CONFIG_ASUS_ARMOURY
CONFIG_FIRMWARE_ATTRIBUTES_CLASS
CONFIG_ASUS_NB_WMI
CONFIG_HID_ASUS
```

`CONFIG_ASUS_ARMOURY` es la pieza clave: es el driver que sustituye a las funciones que antes exponía `asus-wmi`, y del que dependen `asusctl`/ROG Control Center **desde su versión 6.1.0** para la mayoría de sus funciones (límite de carga de batería, control de TDP, etc.). Está en el kernel mainline **desde Linux 6.19** (diciembre de 2025); antes de esa versión solo estaba disponible vía kernels parcheados o como módulo DKMS aparte. Las demás opciones de la lista llevan mucho más tiempo en mainline, pero tampoco vienen activadas por defecto en toda config base, así que se fuerzan igual.

### 5.9. Forzar soporte de sched-ext (CONFIG_SCHED_CLASS_EXT)

Mismo motivo que en el punto anterior: sin forzarlo, el kernel resultante no podría cargar schedulers de [sched-ext](https://github.com/sched-ext/scx) (`scx_lavd`, `scx_bpfland`, etc.) — necesarios, por ejemplo, para el repo [`sched-ext-debian`](https://github.com/csr79a/sched-ext-debian).

Se fuerza:

```
CONFIG_BPF
CONFIG_BPF_SYSCALL
CONFIG_BPF_JIT
CONFIG_BPF_JIT_ALWAYS_ON
CONFIG_BPF_JIT_DEFAULT_ON
CONFIG_DEBUG_INFO_BTF
CONFIG_SCHED_CLASS_EXT
```

`CONFIG_SCHED_CLASS_EXT` depende de `BPF_SYSCALL && BPF_JIT && DEBUG_INFO_BTF` (así lo define el propio `Kconfig` del kernel), de ahí que haya que forzar también esas tres.

Un matiz importante sobre "desde qué versión": la clase sched_ext existe como opción de compilación en mainline **desde Linux 6.12** (septiembre de 2024), pero eso no significa que cualquier distro la traiga activada por defecto en esa versión. El propio kernel de Debian en la rama 6.12 (el que trae Trixie de fábrica) **no** la trae activada — Debian solo empezó a activarla en su propio paquete `linux` a partir de la versión `6.14.3-1~exp1` ([bug #1102639](https://bugs.debian.org/1102639)). Mientras uses la rama 6.12 de Debian como base (aunque compiles un kernel más reciente a partir de ella), hay que forzarla a mano.

Tras forzarla, el script comprueba que `CONFIG_SCHED_CLASS_EXT=y` quedó realmente activa en el `.config` resultante, y avisa (sin abortar) si por algún motivo no fue así.

### 5.10. Compilación

```bash
make -j$JOBS bindeb-pkg LOCALVERSION=-custom
```

`bindeb-pkg` es el target oficial del propio kernel Linux para generar paquetes `.deb`. El sufijo `-custom` permite distinguir este kernel de los que vienen de los repos de Debian. El log completo de la compilación se guarda en `~/kernel-build/build-<version>.log`.

### 5.11. Instalación

Los `.deb` generados se instalan con `apt install` (no `dpkg -i`), para que, si al kernel nuevo le faltara alguna dependencia, `apt` la resuelva e instale automáticamente en vez de dejar el sistema con paquetes a medio instalar.

Con `--force` (ver sección 6), se añade además `--reinstall`: si vuelves a compilar la misma versión de kernel (por ejemplo, tras cambiar una opción forzada en 5.8/5.9), el `.deb` generado tiene el mismo número de versión que el ya instalado, y sin `--reinstall` `apt` lo detectaría como "ya está en su versión más reciente" y no haría nada, aunque el contenido (el `.config` usado) sea distinto.

### 5.12. GRUB

El script ejecuta `sudo update-grub` de forma explícita al final de la instalación.

### 5.13. Limpieza de archivos

Pregunta si quieres eliminar el contenido de `~/kernel-build` (fuente descargada, código extraído, `.deb` generados). Si dices que no, se conservan por si quieres reinstalarlos o revisar el log.

### 5.14. Pantalla final y reinicio

Muestra un resumen de la versión instalada (con nota sobre Secure Boot si aplica) y ofrece reiniciar ahora o después. El nuevo kernel no estará activo hasta que reinicies.

## 6. Recompilar con --force

```bash
./build-kernel-debian.sh --force
```

La comprobación del paso 5.4 compara `uname -r` contra la última versión estable de kernel.org **solo por número de versión**. Si ya compilaste un kernel `-custom` con este script, tu `uname -r` reportará esa misma versión con el sufijo `-custom`, y el script asumiría que "ya la tienes" y saldría sin hacer nada — aunque hayas cambiado algo en las secciones 5.8/5.9 y quieras que ese cambio se aplique.

`--force` salta esa comprobación y recompila igualmente. Es el caso de uso típico cuando:

- Añades o cambias una opción forzada (ASUS, sched_ext, u otra futura).
- Quieres regenerar los `.deb` sin esperar a que salga una versión de kernel nueva de verdad.

Sin `--force`, el uso normal (`./build-kernel-debian.sh`) sigue funcionando igual: si hay una versión más reciente disponible, compila; si no, no hace nada.

## 7. Desinstalar un kernel compilado

Al quedar gestionado como un paquete Debian normal, basta con:

```bash
sudo apt remove linux-image-<version>-custom linux-headers-<version>-custom
sudo update-grub
```

## 8. Limitaciones actuales / posibles mejoras futuras

- Por ahora solo soporta kernel **vanilla** (sin parches). Podría añadirse en el futuro un paso opcional para aplicar parches sueltos (p. ej. schedulers alternativos) sobre la base vanilla.
- La firma automática con clave MOK para Secure Boot no está implementada todavía — de momento es un proceso manual documentado arriba.
- Pensado para Debian; en otras distros basadas en `.deb` debería funcionar igual, pero no está probado.

## 9. Historial de versiones

- **1.1.4** — Flag `--force` (ver sección 6). Sección 5.9: se fuerza `CONFIG_SCHED_CLASS_EXT` y sus dependencias BPF/BTF, necesario para sched-ext.
- **1.1.3** — Se añade el WKD de kernel.org como tercera fuente para importar las claves PGP, por si ambos keyservers estuvieran caídos a la vez.
- **1.1.2** — Se usa `apt install` en vez de `dpkg -i` para instalar los `.deb` generados, de forma que las dependencias que falten se resuelvan automáticamente en vez de dejar el sistema en estado roto.
- **1.1.1** — Corrección de bugs menores (comprobación de `sudo`, falso positivo al detectar el kernel ya instalado, protección del glob al instalar los `.deb`, manejo de error en la consulta a kernel.org, validación del formato de versión recibido). Se añade verificación de firma PGP (autenticidad, además del SHA256 ya existente) contra las claves oficiales de kernel.org.
- **1.1.0** — Versión base: descarga desde kernel.org, verificación SHA256, compilación con opciones ASUS forzadas, generación e instalación de paquetes `.deb`, regeneración de GRUB.
