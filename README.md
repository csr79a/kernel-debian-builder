# kernel-debian-builder

Instalador de Kernel csr79a — compila e instala automáticamente la última versión **estable** del kernel de Linux en Debian y derivados, generando paquetes `.deb` gestionados por `dpkg`/`apt`, con interfaz interactiva por pantallas (`whiptail`).

## Qué hace

1. Instala las dependencias de compilación necesarias desde los repos oficiales de Debian (`build-essential`, `dwarves`/`libdw-dev`, `ccache`, `git`, `patch`, `gnupg`, `whiptail`, `mokutil`...).
2. Instala/activa `ld.lld` como linker opcional (más rápido que `ld` al enlazar); si no está disponible, sigue sin él sin abortar.
3. Configura `ccache` (tope 10G, bajo el propio directorio de trabajo) para que las recompilaciones sobre el mismo árbol (`--force`, probar una opción distinta) sean mucho más rápidas que la primera.
4. Comprueba que hay al menos 60GB libres en disco antes de empezar (margen para la caché de ccache).
5. Detecta si Secure Boot está activado y avisa del riesgo de arrancar un kernel sin firmar.
6. Detecta la última versión estable publicada en [kernel.org](https://kernel.org).
7. Calcula un número de jobs de compilación recomendado según tus hilos y RAM, y te deja elegir entre ese valor o usar todos los hilos.
8. Ofrece, de forma **opcional**, optimizar la compilación para tu microarquitectura de CPU concreta (`x86-64-v3` o, en AMD Zen3/Zen3+/Zen4+, `znver3`), comprobando antes que tu compilador y tu CPU realmente lo soportan.
9. Descarga el código fuente y verifica su integridad: suma **SHA256** y **firma PGP** contra las claves oficiales de kernel.org.
10. Ofrece, de forma **opcional y experimental**, aplicar el parche de scheduler [BORE](https://github.com/firelzrd/bore-scheduler) (si existe para tu serie de kernel), mostrando siempre el commit exacto que se va a aplicar.
11. Genera la configuración (`.config`) a partir del kernel que tienes corriendo actualmente, y te pregunta —una por una, nunca las fuerza sin preguntar— si quieres activar soporte de hardware ASUS (`asus_armoury` y afines), soporte de `sched_ext` (para usar schedulers como `scx_lavd`), y `CONFIG_NTSYNC` (sincronización NT para Wine/Proton).
12. Compila el kernel y genera paquetes `.deb` (`linux-image`, `linux-headers`) usando el método nativo del propio kernel (`make bindeb-pkg`).
13. Instala los paquetes con `apt install` (resuelve dependencias automáticamente).
14. Regenera GRUB (`update-grub`).
15. Si detecta kernels `-custom` antiguos instalados de ejecuciones previas, te deja elegir cuáles eliminar para no llenar `/boot`.
16. Pregunta si quieres eliminar los archivos generados durante la compilación.
17. Pantalla final con opción de reiniciar ahora o después (o solo un aviso, si Secure Boot está activo — ver más abajo).

## Uso

**Si clonas el repo de GitHub:**

```
git clone https://github.com/csr79a/kernel-debian-builder.git
cd kernel-debian-builder
chmod +x build-kernel-debian.sh
./build-kernel-debian.sh
```

**Si descargaste los archivos sueltos** (por ejemplo desde `~/Descargas`), colócalos juntos en una carpeta antes de ejecutar:

```
mkdir -p ~/kernel-debian-builder
mv build-kernel-debian.sh README.md MANUAL.md ~/kernel-debian-builder/
cd ~/kernel-debian-builder
chmod +x build-kernel-debian.sh
./build-kernel-debian.sh
```

No lo ejecutes como root: el script pedirá `sudo` cuando lo necesite.

## Recompilar (--force)

Si ya compilaste un kernel con este script y quieres recompilarlo (por ejemplo, tras cambiar una respuesta en las preguntas de ASUS/sched-ext/NTSYNC, o probar el parche BORE), usa `--force`:

```
./build-kernel-debian.sh --force
```

Sin este flag, si ya tienes la última versión estable instalada, el script no hace nada.

## Requisitos

- Debian (o derivado) con `sudo` configurado.
- Conexión a internet.
- Espacio en disco: al menos 60GB libres (el script lo comprueba antes de empezar).

Más detalles en [MANUAL.md](https://github.com/csr79a/kernel-debian-builder/blob/master/MANUAL.md).

## Notas

- Solo compila versiones **estables** (no `-rc`), siempre la última publicada.
- Si ya estás en la última versión estable, el script no hace nada (salvo con `--force`).
- El kernel se instala con el sufijo `-custom-<variante>` en `LOCALVERSION` (`generic`, `v3` o `znver3`, según la optimización de CPU realmente aplicada), para distinguirlo fácilmente del kernel de los repos de Debian y saber qué se compiló solo con `uname -r`.
- ASUS, `sched_ext` y `CONFIG_NTSYNC` ya **no se fuerzan sin preguntar**: cada uno es una pregunta independiente en pantalla, con su propio coste explicado (por ejemplo, `sched_ext` alarga la compilación por `CONFIG_DEBUG_INFO_BTF`).
- El parche BORE es opcional y experimental: si no existe para tu serie de kernel, o falla al aplicarse, el script sigue compilando con normalidad sin él (nunca aborta el build por esto).
- El script gestiona el ciclo de vida de los kernels `-custom` que instala: al final te deja elegir cuáles de los antiguos borrar (excluyendo siempre el recién instalado y el que está en ejecución).
- Desinstalar un kernel concreto es tan sencillo como con cualquier paquete de Debian: `sudo apt remove linux-image-<version>-custom-<variante> linux-headers-<version>-custom-<variante>`.
- Si Secure Boot está activado, el kernel se instala igualmente pero no arrancará hasta firmarlo con una clave MOK propia, y el script **no ofrece reiniciar automáticamente** en ese caso — ver sección de Secure Boot en el MANUAL.
