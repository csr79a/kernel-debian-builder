# MANUAL — kernel-debian-builder (Instalador de Kernel csr79a)

## 1. Objetivo del proyecto

Automatizar el flujo completo de compilación de un kernel Linux vanilla (con parches opcionales) en Debian: desde la descarga del código fuente en kernel.org hasta tener el nuevo kernel arrancable desde GRUB, con una interfaz de pantallas interactiva (`whiptail`) que pregunta antes de activar cualquier opción no estándar.

## 2. Requisitos previos

- Debian o derivado (Trixie, Sid, etc.).
- Usuario con permisos de `sudo`.
- Al menos 60GB libres en disco (el script lo comprueba antes de empezar y aborta si no hay suficiente; sube desde los 50GB de versiones anteriores para dejar margen a la caché de ccache).
- Conexión a internet.

## 3. Preparar los archivos

Si descargaste `build-kernel-debian.sh`, `README.md` y `MANUAL.md` sueltos (no vía `git clone`), primero muévelos juntos a una carpeta y da permisos de ejecución al script:

```
mkdir -p ~/kernel-debian-builder
mv build-kernel-debian.sh README.md MANUAL.md ~/kernel-debian-builder/
cd ~/kernel-debian-builder
chmod +x build-kernel-debian.sh
```

Sin `chmod +x`, `./build-kernel-debian.sh` fallará con "Permiso denegado".

## 4. Qué instala el script

Paquetes desde los repos oficiales de Debian:

- `build-essential`, `libncurses-dev`, `bison`, `flex`, `libssl-dev`, `libelf-dev`
- `dwarves` (BTF), `libdw-dev` (requerida por `dwarves`/`pahole`)
- `debhelper` (provee `debhelper-compat`, exigido por `make bindeb-pkg`)
- `fakeroot`, `bc`, `rsync`, `curl`, `jq`
- `whiptail` (interfaz de pantallas), `mokutil` (detección de Secure Boot)
- `gnupg`, `xz-utils` (verificación del tarball)
- `git`, `patch` (parche opcional BORE, sección 6.3)
- `ccache` (obligatorio; acelera recompilaciones sobre el mismo árbol)

El `apt update` previo a instalar estos paquetes solo se ejecuta si falta alguno; si todos ya están presentes, el script no toca el índice de apt en este punto (ver 5.1 para el caso de `lld`, que si hace falta sí fuerza un `apt update` propio).

## 5. Flujo paso a paso

### 5.1. `ld.lld` como linker opcional

El kernel se puede enlazar con `ld` (GNU/BFD, por defecto) o con un linker más rápido. Versiones anteriores de este script probaron `mold`, pero Kbuild **rechaza `mold` siempre**: `scripts/ld-version.sh` del propio kernel solo acepta un `$(LD)` cuyo `--version` empiece por "GNU ld" o contenga "LLD", y la salida de `mold` ("mold X.Y.Z (compatible with GNU ld)") no cumple ninguna de las dos condiciones. Por eso el script usa `ld.lld` (LLVM), que sí está reconocido:

1. Comprueba si `ld.lld` ya está instalado y si Kbuild lo reconocería (no solo que el binario exista, sino que su `--version` contenga "LLD").
2. Si no, intenta instalar el paquete `lld` (refrescando el índice de apt si hace falta) y vuelve a comprobar.
3. Si de todas formas no queda disponible o no es reconocido, se usa `ld` por defecto sin abortar el script (fail-soft).

### 5.2. ccache

Se configura `CCACHE_DIR` dentro del propio directorio de trabajo (`~/kernel-build/.ccache`), con un tope de 10GB. La primera compilación de una versión nueva tarda igual (caché vacía); las siguientes sobre el mismo árbol —por ejemplo, `--force` tras cambiar una respuesta en la sección 7, o probar el parche BORE con y sin activar— pueden bajar de horas a minutos, porque solo se recompilan los objetos que realmente cambiaron.

### 5.3. Pantalla de bienvenida

Muestra el nombre y versión del instalador, una descripción breve, y pide confirmación para continuar.

### 5.4. Comprobación de espacio en disco

Antes de descargar o compilar nada, el script comprueba que haya al menos 60GB libres en el directorio de trabajo (`~/kernel-build`). Si no los hay, se detiene inmediatamente con un mensaje claro, en vez de fallar a mitad de una compilación de 20-30 minutos.

### 5.5. Detección de Secure Boot

El script ejecuta `mokutil --sb-state`:

- **Si está desactivado**: continúa sin más, sin preguntar nada.
- **Si está activado**: avisa de que el kernel compilado no estará firmado y de que UEFI podría rechazar arrancarlo, y pregunta si quieres continuar de todas formas.

**Si decides seguir con Secure Boot activado**, para que el kernel arranque tendrás que firmarlo manualmente con una clave propia (MOK — Machine Owner Key), un proceso de una sola vez:

```
# 1. Generar una clave propia (una sola vez en la vida del sistema)
sudo openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv -outform DER -out MOK.der -nodes -days 36500 -subj "/CN=Mi Clave Kernel/"

# 2. Registrarla en el firmware UEFI (pide una contraseña temporal)
sudo mokutil --import MOK.der

# 3. Al reiniciar, aparece una pantalla azul de MokManager donde hay que
#    elegir "Enroll MOK" e introducir esa contraseña para confirmar

# 4. Con la clave ya inscrita, firmar el kernel compilado
sudo /usr/lib/linux-kbuild-<version>/scripts/sign-file sha256 MOK.priv MOK.der /boot/vmlinuz-<version>-custom-<variante>
```

El paso 3 requiere interacción física en el arranque y no se puede automatizar desde el script. Con Secure Boot activo, el script tampoco ofrece "Reiniciar ahora" al terminar (ver 5.17): el reinicio queda en tus manos, después de completar la firma.

### 5.6. Detección de versión

El script consulta `https://www.kernel.org/releases.json` y extrae la versión marcada como `stable`. Si ya estás corriendo esa versión, el script termina sin hacer nada — salvo que hayas pasado `--force`, en cuyo caso continúa igualmente.

### 5.7. Cálculo de jobs de compilación

El script detecta tus hilos (`nproc`) y tu RAM total (`free`), y calcula un valor recomendado con la fórmula:

```
jobs_recomendados = mínimo( hilos_detectados , (RAM_GB - 2) / 2 )
```

Se reservan 2GB fijos para el sistema antes de repartir el resto entre los jobs, asumiendo un pico de hasta ~2GB por proceso de compilación en paralelo. Te muestra ambos datos (hilos y RAM) y el valor recomendado, y te deja elegir entre usarlo o forzar el uso de todos los hilos disponibles (con un aviso si eso supera lo recomendado para tu RAM).

Ejemplos:

| RAM  | Hilos | Jobs recomendados |
| ---- | ----- | ----------------- |
| 32GB | 16    | 15                |
| 16GB | 8     | 7                 |
| 8GB  | 16    | 3                 |

### 5.8. Optimización opcional de microarquitectura de CPU (march/mtune)

Por defecto el kernel se compila para el baseline genérico de x86-64 (igual que el kernel oficial de Debian): ni ccache ni ld.lld cambian ninguna instrucción generada, solo cachean/enlazan más rápido. Este paso es distinto: usa la variable `KCFLAGS` de Kbuild para pedirle al compilador instrucciones más modernas.

Se ofrecen hasta dos niveles opcionales (por defecto: sin cambios):

- **x86-64-v3**: baseline portable a cualquier CPU moderna que lo soporte (Intel Haswell 2013+ / AMD Excavator-Zen1 2015+ en adelante). Se ofrece si el compilador local acepta `-march=x86-64-v3` (se comprueba compilando un programa mínimo de prueba, no solo mirando la versión de GCC).
- **znver3**: además del mismo juego de instrucciones que v3, ajusta el modelo de coste/scheduling al núcleo Zen 3/Zen 3+ concreto. Más específico, mejor aprovechado, pero no portable ni siquiera a otra generación Zen distinta. Solo se ofrece si, además de que GCC acepte el flag, `/proc/cpuinfo` confirma que la CPU real es AMD familia ≥25 (Zen3/Zen3+/Zen4 en adelante) — que GCC acepte el flag no significa que tu CPU sea esa microarquitectura, GCC puede generar código para cualquier target que conozca.

**Advertencia importante**: a diferencia de una app de usuario mal compilada (que simplemente crashea), un kernel compilado con instrucciones que la CPU no soporta puede fallar durante el arranque. El kernel de Debian sigue instalado en paralelo (no se sobreescribe), así que el peor caso es elegir "Advanced options for Debian" en GRUB y arrancar con el de serie.

La opción elegida (o "generic" si no se aplicó ninguna) queda registrada en `MARCH_TAG`, que forma parte del sufijo final del kernel instalado (ver 5.15) — así puedes comprobar con `uname -r` qué se compiló de verdad, sin depender de ningún log.

### 5.9. Descarga y verificación SHA256

Descarga el `.tar.xz` desde `cdn.kernel.org` (reutiliza el archivo si ya estaba descargado) y verifica la suma **SHA256** contra el fichero de sumas oficial publicado junto a cada release.

### 5.10. Verificación de firma PGP

El SHA256 anterior protege contra corrupción de descarga, pero se obtiene del mismo servidor que el propio tarball: si un mirror estuviera comprometido, podría servir tarball y checksum falsos a la vez. La firma PGP añade una capa de autenticidad independiente:

1. Importa las claves oficiales de kernel.org (Linus Torvalds y Greg Kroah-Hartman), identificadas por su huella exacta — no se confía en el "web of trust" ni en el nivel de confianza que gpg le asigne a una clave. Prueba tres fuentes en orden por si alguna estuviera caída: dos keyservers y, como último recurso, el WKD (Web Key Directory) de kernel.org resuelto por HTTPS contra su propio dominio.
2. Descarga la firma (`.tar.sign`) y la verifica contra el tarball descomprimido al vuelo.
3. Comprueba que la firma coincide con una de las huellas reconocidas, no solo que sea "válida" (una firma criptográficamente correcta pero de una clave desconocida se rechaza igual).

Si cualquiera de las dos verificaciones (SHA256 o PGP) falla, el script se detiene inmediatamente — no compila código sin confirmar que viene de kernel.org sin alterar.

### 5.11. Extracción y parche opcional BORE (scheduler)

Tras extraer el código fuente, el script comprueba si hay disponible el parche de scheduler [BORE](https://github.com/firelzrd/bore-scheduler) para tu serie de kernel (`$KMAJOR.$KMINOR`). Esto ocurre **antes** de preparar el `.config` (sección 5.13), porque el parche añade el símbolo `CONFIG_SCHED_BORE` al Kconfig del scheduler; si se aplicara después, `olddefconfig` lo descartaría en silencio por no existir todavía en el árbol de Kconfig.

**Nota de confianza**: a diferencia del kernel (verificado por SHA256+PGP contra huellas fijas), BORE es un repo de terceros sin el mismo nivel de control. El script:

- Clona (o actualiza) el repo `firelzrd/bore-scheduler`. Si defines `BORE_PIN_COMMIT` con un hash al principio del script, fija el parche a ese commit exacto (más reproducible); si lo dejas vacío, usa siempre la punta de la rama por defecto.
- Muestra **siempre** el commit exacto que se va a aplicar, para que la decisión sea informada.
- Intenta verificar (fail-soft) la firma de ese commit por si el mantenedor firma su historial; si no puede, avisa pero no bloquea.
- Comprueba con `patch --dry-run` que el parche aplicaría limpio antes de tocar el árbol de fuentes de verdad, y detecta si ya estaba aplicado (por ejemplo, en un reintento con `--force` sobre el mismo árbol reutilizado).
- Si se aplica, registra el commit usado en `bore-commit-<version>.txt` dentro del directorio de trabajo.

Es puramente opcional y **experimental**: modifica el scheduler CFS/EEVDF para priorizar procesos con ráfagas cortas de CPU (más responsividad bajo carga), pero no es necesario para que el kernel funcione ni para nada más de lo que hace este script. Si el parche no existe para tu serie, o falla al aplicarse, el script sigue compilando con normalidad sin él — nunca aborta el build por esto (misma filosofía "fail-soft" del resto del script).

Si aceptaste BORE, el script busca además un posible parche adicional de coexistencia BORE + sched-ext en el mismo repo (búsqueda "best effort": no siempre existe como fichero independiente). No es necesario para que ambos convivan — sched-ext, al activar un scheduler `scx_*`, toma el control de esas tareas fuera de la clase CFS/EEVDF que BORE modifica, y al pararlo el control vuelve a CFS/BORE — pero se ofrece igual por si aporta algún ajuste extra.

### 5.12. Configuración base (.config)

Copia `/boot/config-$(uname -r)` (la configuración del kernel que tienes corriendo ahora mismo) y ejecuta `make olddefconfig`, que adapta esa configuración a las nuevas opciones de la versión más reciente, minimizando el riesgo de perder soporte de hardware o módulos que ya usas.

### 5.13. Preguntas sobre opciones no estándar (ASUS, sched_ext, NTSYNC)

A partir de la v1.7.0, **ninguna** de estas tres opciones se fuerza directamente: cada una es una pregunta independiente en pantalla, con su propia explicación y coste. `make olddefconfig` solo hereda lo que ya tenía activado tu kernel de origen — si dijiste que no a alguna la primera vez, esa ausencia se arrastraría de compilación en compilación salvo que la actives aquí.

- **Hardware ASUS** (`asus_armoury` y afines): el script comprueba el fabricante vía DMI (`/sys/class/dmi/id/sys_vendor`). Si detecta "ASUS", la pregunta aparece con "Sí" resaltado por defecto; si no, con "No" resaltado — pero la detección **nunca decide por ti**, solo cambia el texto y el botón por defecto. Si aceptas, se activan `CONFIG_ASUS_WMI`, `CONFIG_ASUS_ARMOURY` (la pieza clave: sustituye a las funciones que antes exponía `asus-wmi`, y de la que dependen `asusctl`/ROG Control Center desde su versión 6.1.0 — está en mainline desde Linux 6.19, diciembre de 2025), `CONFIG_FIRMWARE_ATTRIBUTES_CLASS`, `CONFIG_ASUS_NB_WMI` y `CONFIG_HID_ASUS`. En un equipo no-ASUS, activarlas no tiene ningún efecto, ni bueno ni malo.

- **sched_ext** (`CONFIG_SCHED_CLASS_EXT`): necesario para cargar schedulers BPF de [sched-ext](https://github.com/sched-ext/scx) (`scx_lavd`, `scx_bpfland`, etc.) — por ejemplo, para el repo [`sched-ext-debian`](https://github.com/csr79a/sched-ext-debian). Tiene un coste real explicado en la propia pregunta: depende de `CONFIG_DEBUG_INFO_BTF`, que necesita `pahole` (paquete `dwarves`) para generar información BTF desde DWARF durante la compilación, alargando el build y añadiendo símbolos de depuración extra al kernel resultante. Si aceptas, el script activa `CONFIG_BPF`, `CONFIG_BPF_SYSCALL`, `CONFIG_BPF_JIT`, `CONFIG_BPF_JIT_ALWAYS_ON`, `CONFIG_BPF_JIT_DEFAULT_ON`, desactiva `CONFIG_DEBUG_INFO_NONE` (un kernel de Debian normal lo trae heredado en la config base; sin desactivarlo explícitamente, `olddefconfig` descarta `CONFIG_DEBUG_INFO_BTF` pese al `--enable`, sin que falte `pahole` para nada — este fue un bug real corregido en la v1.7.1), activa `CONFIG_DEBUG_INFO` + `CONFIG_DEBUG_INFO_DWARF5`, y finalmente `CONFIG_DEBUG_INFO_BTF` y `CONFIG_SCHED_CLASS_EXT`.

- **CONFIG_NTSYNC** (primitivas de sincronización NT): solo aporta algo si usas Wine o Proton (mejora el rendimiento de sincronización de hilos frente a la emulación en espacio de usuario). Debian no lo trae activado por defecto. Driver independiente, sin dependencias complejas — a diferencia de sched_ext, no alarga el build de forma apreciable.

Tras las tres preguntas, si se aplicó el parche BORE (5.11), el script fuerza `CONFIG_SCHED_BORE` (mismo motivo: sin esto, `olddefconfig` no lo activaría por sí solo). Después se hace una **única pasada final** de `make olddefconfig` que aplica todo lo anterior de golpe (antes se llamaba una vez por cada bloque; se consolidó en la v1.3.0), seguida de comprobaciones que avisan (sin abortar) si algún símbolo esperado no quedó activo pese a haberlo pedido — y solo para las opciones que de verdad pediste, no para las que rechazaste.

### 5.14. Compilación

```
make -j$JOBS bindeb-pkg LOCALVERSION=-custom-<variante> [LD=ld.lld] [KCFLAGS=...]
```

`bindeb-pkg` es el target oficial del propio kernel Linux para generar paquetes `.deb`. `<variante>` es `generic`, `v3` o `znver3` según la optimización de CPU realmente aplicada en 5.8 (nunca la que solo se ofreció o eligió si al final no se pudo usar). Se empaqueta con `KDEB_COMPRESS=gzip` (más rápido que `xz`, que ya era el valor por defecto de todas formas — fijarlo a `xz` en una versión anterior de este script no cambiaba nada; el `.deb` resultante es algo más grande, pero eso solo importa si lo mueves o archivas, no para instalarlo localmente). El log completo de la compilación se guarda en `~/kernel-build/build-<version>.log`, y al terminar el script muestra las estadísticas de uso de ccache de la sesión.

### 5.15. Instalación

Los `.deb` generados se instalan con `apt install` (no `dpkg -i`), para que, si al kernel nuevo le faltara alguna dependencia, `apt` la resuelva e instale automáticamente en vez de dejar el sistema con paquetes a medio instalar.

Con `--force`, se añaden además `--reinstall --allow-downgrades`:

- `--reinstall` porque si vuelves a compilar la misma versión de kernel (mismo `KVERSION`, tras cambiar una respuesta en 5.13 y recompilar), el `.deb` generado tiene el mismo número de versión que el ya instalado, y sin este flag `apt` lo detectaría como "ya está en su versión más reciente" y no haría nada, aunque el `.config` usado sea distinto.
- `--allow-downgrades` porque el sufijo de revisión Debian (el "-1", "-2"... de "7.2.5-1") sale de un contador que vive dentro del árbol de fuentes extraído, no en ningún sitio persistente. Si entre una compilación anterior (ya instalada, con revisión más alta) y esta el árbol de fuentes se volvió a extraer desde cero — por ejemplo, respondiste "sí" a "eliminar archivos generados" en 5.17 tras esa compilación anterior — el contador se reinicia en 1 y el `.deb` nuevo puede quedar con una revisión **menor** que la ya instalada; sin este flag, `apt` rechazaría la instalación como si fuera un downgrade real.

### 5.16. GRUB

El script ejecuta `sudo update-grub` de forma explícita al final de la instalación.

### 5.17. Limpieza de kernels `-custom` antiguos

A diferencia de los kernels oficiales de Debian (que `apt autoremove` limpia solo al entrar uno nuevo, vía el metapaquete `linux-image-amd64`), los kernels `-custom-*` que genera este script no dependen de ningún metapaquete y no se retiran solos: sin este paso, `/boot` puede acabar lleno tras varias compilaciones. El script:

1. Lista los paquetes `linux-image-*-custom-*` instalados, excluyendo siempre el que se acaba de instalar y el que está actualmente en ejecución (por si aún no has reiniciado tras una ejecución anterior).
2. Si hay alguno, te muestra un checklist de `whiptail` con todos ellos **sin nada premarcado** — es una elección explícita, nunca un borrado automático.
3. Elimina los paquetes de imagen y headers que marques, y regenera GRUB si hubo cambios.

### 5.18. Limpieza de archivos de compilación

Pregunta si quieres eliminar el contenido de `~/kernel-build` (fuente descargada, código extraído, `.deb` generados — no borra la caché de ccache ni el repo de BORE, que se reutilizan entre ejecuciones). Si dices que no, se conservan por si quieres reinstalarlos o revisar el log.

### 5.19. Pantalla final y reinicio

Muestra un resumen de la versión instalada (con nota sobre el parche BORE si se aplicó) y:

- **Si Secure Boot está desactivado**: ofrece reiniciar ahora o después.
- **Si Secure Boot está activado**: el script **no ofrece reiniciar automáticamente**. Solo un mensaje de aviso recordando completar la firma/inscripción MOK (sección 5.5) antes de reiniciar manualmente — reiniciar sin haberla completado puede dejar el sistema sin arrancar.

## 6. Recompilar con --force

```
./build-kernel-debian.sh --force
```

La comprobación de la sección 5.6 compara `uname -r` contra la última versión estable de kernel.org **solo por número de versión**. Si ya compilaste un kernel `-custom` con este script, tu `uname -r` reportará esa misma versión con el sufijo `-custom-<variante>`, y el script asumiría que "ya la tienes" y saldría sin hacer nada — aunque hayas cambiado algo en las preguntas de 5.13 y quieras que ese cambio se aplique.

`--force` salta esa comprobación y recompila igualmente. Es el caso de uso típico cuando:

- Cambias una respuesta sobre ASUS, sched_ext o NTSYNC.
- Quieres probar el parche BORE con o sin él.
- Quieres regenerar los `.deb` sin esperar a que salga una versión de kernel nueva de verdad.

Sin `--force`, el uso normal (`./build-kernel-debian.sh`) sigue funcionando igual: si hay una versión más reciente disponible, compila; si no, no hace nada.

## 7. Desinstalar un kernel compilado

Al quedar gestionado como un paquete Debian normal, basta con:

```
sudo apt remove linux-image-<version>-custom-<variante> linux-headers-<version>-custom-<variante>
sudo update-grub
```

(`<variante>` es `generic`, `v3` o `znver3` — revisa `dpkg -l | grep custom` si no la recuerdas). El propio script también te ofrece hacer esta limpieza de forma interactiva al final de cada ejecución (sección 5.17).

## 8. Limitaciones actuales / posibles mejoras futuras

- Por ahora solo soporta kernel **vanilla** más el parche opcional BORE. Podrían añadirse en el futuro otros parches sueltos (p. ej. otros schedulers alternativos) sobre la misma base.
- La firma automática con clave MOK para Secure Boot no está implementada todavía — de momento es un proceso manual documentado arriba (5.5).
- Pensado para Debian; en otras distros basadas en `.deb` debería funcionar igual, pero no está probado.

## 9. Historial de versiones

- **1.7.1** — Corrección en la pregunta de sched_ext (5.13): forzar `CONFIG_DEBUG_INFO_BTF` por sí solo no bastaba, porque depende de `!DEBUG_INFO_NONE` y un kernel de Debian normal hereda `CONFIG_DEBUG_INFO_NONE=y`. Ahora se desactiva explícitamente antes de pedir `CONFIG_DEBUG_INFO_BTF`.
- **1.7.0** — ASUS, sched-ext y NTSYNC dejan de forzarse directamente: cada uno pasa a ser una pregunta `whiptail` independiente, con su propio coste explicado. ASUS añade detección DMI (solo informa el texto/botón por defecto, nunca decide). Se introducen variables `*_APPLIED` para que los avisos finales solo salten si de verdad se pidió esa opción.
- **1.6.1** — Corrección cosmética de la cabecera del changelog. Nueva sección: se fuerza `CONFIG_NTSYNC=y` (en ese momento, sin preguntar — pasó a pregunta en 1.7.0).
- **1.6.0** — El sufijo del kernel instalado pasa de "-custom" fijo a "-custom-\<variante>" (generic/v3/znver3, según lo realmente aplicado), para poder comprobar con `uname -r` qué se compiló sin depender del log de build.
- **1.5.2** — Corrección de bug real: la instalación de `lld` podía fallar en silencio si el índice de apt estaba desactualizado. Se añade `$APT_UPDATED` para refrescar el índice exactamente una vez cuando hace falta, y se deja de silenciar la salida de `apt install`.
- **1.5.1** — Ajustes de robustez: se elimina `make localmodconfig` (beneficio marginal frente al riesgo); `znver3` ahora exige también que la CPU real sea AMD familia 25 (no solo que GCC acepte el flag); corrección de texto (Zen 3+ en vez de Zen 3); se amplía el aviso de BORE para dejar claro que es experimental y opcional.
- **1.5.0** — Corrección de bug real: `mold` hacía fallar la compilación porque Kbuild lo rechaza siempre (su `ld-version.sh` solo acepta linkers "GNU ld" o "LLD"). Sustituido por `ld.lld`.
- **1.4.1** — Corrección de seguridad menor: el fichero temporal de prueba de compilador pasa de nombre predecible (`/tmp/march-test-$$.c`) a `mktemp`.
- **1.4.0** — Nueva optimización opcional de microarquitectura de CPU vía `KCFLAGS` (x86-64-v3 / znver3), opt-in, con comprobación real de soporte antes de ofrecerla.
- **1.3.1** — Corrección: `KDEB_COMPRESS=xz` no cumplía su objetivo (ya era el valor por defecto y además más lento). Cambiado a `gzip`.
- **1.3.0** — Tanda de optimizaciones: ccache obligatorio; `mold` como linker opcional (más tarde corregido a `ld.lld` en 1.5.0); intento de `KDEB_COMPRESS=xz` (corregido en 1.3.1); `make localmodconfig` opcional (retirado en 1.5.1); gestión de ciclo de vida de kernels `-custom` antiguos; parche BORE con commit mostrado y verificación de firma fail-soft; con Secure Boot activo, ya no se ofrece "Reiniciar ahora".
- **1.2.1** — Se añade `--allow-downgrades` a la instalación con `--force`.
- **1.2.0** — Soporte opcional para el parche BORE (scheduler) del repo `firelzrd/bore-scheduler`, con verificación `--dry-run` y filosofía fail-soft.
- **1.1.4** — Flag `--force`. Se añade el forzado de `CONFIG_SCHED_CLASS_EXT` (sched-ext) y sus dependencias BPF/BTF.
- **1.1.3** — Se añade el WKD de kernel.org como tercera fuente para importar claves PGP.
- **1.1.2** — Se usa `apt install` en vez de `dpkg -i` para instalar los `.deb` generados.
- **1.1.1** — Corrección de bugs menores; se añade verificación de firma PGP (autenticidad) además del SHA256 ya existente.
- **1.1.0** — Versión base: descarga desde kernel.org, verificación SHA256, compilación con opciones ASUS forzadas, generación e instalación de paquetes `.deb`, regeneración de GRUB.
