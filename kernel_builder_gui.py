#!/usr/bin/env python3
"""Instalador de Kernel csr79a — interfaz gráfica (PyQt6).

Ejecuta build-kernel-debian.sh SIN MODIFICARLO, dentro de un pseudo-terminal
(igual que el lanzador general: sudo, colores y `read` funcionan como en una
terminal real). La diferencia con el lanzador general es que aquí los cuadros
`whiptail` del script (--yesno, --msgbox, --infobox, --menu, --checklist) no
se convierten a texto: se reenvían a esta ventana y se muestran como diálogos
Qt nativos.

Cómo funciona el puente:

  1. Antes de lanzar el script se crea un socket Unix en un directorio
     temporal propio de esta ejecución y se levanta un servidor
     (BridgeServer) que escucha en él.
  2. Se antepone al PATH del proceso hijo un `whiptail` propio (BRIDGE_SHIM,
     un script Python) y se le pasa la ruta del socket por la variable de
     entorno KBUILDER_BRIDGE_SOCK.
  3. Cuando el script real llama a `whiptail ...`, en realidad ejecuta
     nuestro shim: éste traduce los argumentos a JSON, lo envía por el
     socket y espera la respuesta.
  4. El servidor, en un hilo aparte, recibe la petición y la reenvía a esta
     ventana mediante una señal Qt (conexión en cola: se ejecuta en el hilo
     de la interfaz). La ventana muestra el diálogo correspondiente, guarda
     el resultado y libera un `threading.Event` para que el hilo del
     servidor pueda responder al shim.
  5. El shim traduce la respuesta de vuelta al formato que espera el script
     (código de salida 0/1, y para --menu/--checklist el tag elegido por
     stderr, tal como hace el whiptail real con `3>&1 1>&2 2>&3`).

El socket y el shim se limpian al terminar cada ejecución. El script no se
copia ni se parchea: la GUI solo le pasa la selección de CPU y BORE mediante
variables de entorno, manteniendo toda la lógica de compilación en el script.

Requiere: python3-pyqt6, y build-kernel-debian.sh en la misma carpeta que
este archivo.
"""
import codecs
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import socketserver
import struct
import subprocess
import sys
import tempfile
import termios
import threading
from pathlib import Path

from PyQt6.QtCore import QObject, Qt, QTimer, pyqtSignal
from PyQt6.QtGui import QColor, QFontDatabase, QTextCharFormat, QTextCursor
from PyQt6.QtWidgets import (QApplication, QDialog, QDialogButtonBox,
                             QButtonGroup, QFrame, QHBoxLayout, QCheckBox, QLabel,
                             QLineEdit, QListWidget, QListWidgetItem, QRadioButton,
                             QMessageBox, QPlainTextEdit, QPushButton,
                             QStackedWidget, QVBoxLayout, QWidget)

SCRIPT_DIR = Path(__file__).resolve().parent
SCRIPT = SCRIPT_DIR / "build-kernel-debian.sh"

SHIM_DIR = Path.home() / ".local/share/kernel-builder-gui/shims"

# Colores/paleta y regex ANSI: idénticos a los del lanzador general, para
# que el panel de registro se vea igual.
FG_DEFECTO = "#d7dde2"
PALETA = ["#8b949e", "#ff6b6b", "#7ee787", "#f2cc60", "#79b8ff", "#d2a8ff",
          "#56d4dd", "#e6edf3",
          "#a0aab4", "#ff8e8e", "#9af5a1", "#ffe08a", "#9dcbff", "#e2c5ff",
          "#7fe9f0", "#ffffff"]
ANSI_RE = re.compile(
    r"\x1b(?:\[[0-?]*[ -/]*[@-~]"
    r"|\][^\x07\x1b]*(?:\x07|\x1b\\)"
    r"|[()][0-~]"
    r"|[78=>@-Z\\-_])")
PASS_RE = re.compile(r"(?i)(contraseña|password|passphrase)[^\n]{0,80}:\s*$")

STYLE = """
QLabel#eyebrow { color: palette(highlight); font-size: 9pt; font-weight: 700; }
QLabel#titulo { font-size: 26pt; font-weight: 700; }
QLabel#subtitulo { color: gray; font-size: 11pt; }
QLabel#pie { color: gray; font-size: 9pt; }
QLabel#detalle { color: gray; font-size: 10pt; }
QLabel#accion { font-size: 16pt; font-weight: 700; }
QLabel#estado { font-size: 11pt; font-weight: 600; }
QLabel#estado[estado="run"] { color: palette(highlight); }
QLabel#estado[estado="ok"] { color: #2ea043; }
QLabel#estado[estado="error"] { color: #d64545; }
QFrame#hero { background: palette(base); border: 1px solid palette(mid);
              border-left: 6px solid palette(highlight); border-radius: 16px; }
QFrame#tarjeta { background: palette(base); border: 1px solid palette(mid);
                 border-radius: 14px; }
QPlainTextEdit#log { background: #14181c; color: #d7dde2;
                     border: 1px solid palette(mid); border-radius: 12px;
                     padding: 10px; selection-background-color: palette(highlight); }
QLineEdit#entrada { min-height: 34px; padding: 0 12px; border-radius: 10px;
                    border: 2px solid palette(mid); background: palette(base); }
QLineEdit#entrada[atencion="true"] { border-color: palette(highlight); }
QPushButton { min-width: 130px; min-height: 38px; padding: 0 18px;
              border-radius: 10px; font-size: 11pt; font-weight: 600;
              border: 2px solid transparent; }
QPushButton#primario { background: palette(highlight); color: palette(highlighted-text); }
QPushButton#primario:hover { border-color: palette(highlighted-text); }
QPushButton#secundario { background: transparent; color: palette(text);
              border-color: palette(mid); }
QPushButton#secundario:hover { border-color: palette(highlight); }
QPushButton#secundario:disabled { color: palette(mid); }
QRadioButton, QCheckBox { font-size: 10.5pt; spacing: 8px; }
QRadioButton:disabled, QCheckBox:disabled { color: palette(mid); }
QLabel#opcion_titulo { font-size: 12pt; font-weight: 700; }
QLabel#opcion_detalle { color: gray; font-size: 9.5pt; }
QFrame#opcion { background: #171d23; border: 1px solid palette(mid); border-radius: 12px; }
QFrame#opcion:hover { border-color: palette(highlight); }
QLabel#seleccion { color: palette(highlight); font-size: 10pt; font-weight: 600; }
"""

# Shim de whiptail: NO es texto plano como el del lanzador general, es un
# script Python que reenvía cada cuadro a esta ventana por socket Unix.
# Reescribe los argumentos con el mismo contrato que whiptail: --yesno/
# --msgbox/--infobox devuelven solo código de salida (0/1); --menu escribe
# el tag elegido en stderr; --checklist escribe los tags elegidos en stderr,
# separados por espacios y entrecomillados (igual que el whiptail real, así
# el 'eval "SELECTED_IMAGES=(${SELECTED_RAW})"' del script funciona igual).
BRIDGE_SHIM = r'''#!/usr/bin/env python3
# whiptail (puente gráfico, generado por kernel_builder_gui.py; no editar).
import json, os, socket, sys

def fail(msg):
    print(f"whiptail (puente grafico): {msg}", file=sys.stderr)
    sys.exit(255)

sock_path = os.environ.get("KBUILDER_BRIDGE_SOCK")
if not sock_path:
    fail("no se encontro KBUILDER_BRIDGE_SOCK")

args = sys.argv[1:]
title = ""
kind = None
text = ""
yes_label = "Si"
no_label = "No"
defaultno = False
items = []
citems = []

def es_numero(s):
    return s.lstrip("-").isdigit()

i = 0
while i < len(args):
    a = args[i]
    if a == "--title":
        title = args[i + 1] if i + 1 < len(args) else ""
        i += 2
    elif a == "--yes-button":
        yes_label = args[i + 1] if i + 1 < len(args) else yes_label
        i += 2
    elif a == "--no-button":
        no_label = args[i + 1] if i + 1 < len(args) else no_label
        i += 2
    elif a == "--defaultno":
        defaultno = True
        i += 1
    elif a in ("--backtitle", "--ok-button", "--cancel-button"):
        i += 2
    elif a in ("--clear", "--nocancel", "--scrolltext", "--fb",
               "--fullbuttons", "--notags", "--separate-output"):
        i += 1
    elif a in ("--yesno", "--msgbox", "--infobox"):
        kind = a[2:]
        text = args[i + 1] if i + 1 < len(args) else ""
        i += 2
        if i < len(args) and es_numero(args[i]):
            i += 1
        if i < len(args) and es_numero(args[i]):
            i += 1
    elif a == "--menu":
        kind = "menu"
        text = args[i + 1] if i + 1 < len(args) else ""
        i += 2
        for _ in range(3):
            if i < len(args) and es_numero(args[i]):
                i += 1
        while i + 1 < len(args):
            items.append((args[i], args[i + 1]))
            i += 2
    elif a == "--checklist":
        kind = "checklist"
        text = args[i + 1] if i + 1 < len(args) else ""
        i += 2
        for _ in range(3):
            if i < len(args) and es_numero(args[i]):
                i += 1
        while i + 2 < len(args):
            estado = args[i + 2].upper() == "ON"
            citems.append((args[i], args[i + 1], estado))
            i += 3
    elif a.startswith("--"):
        fail(f"opcion no soportada: {a}")
    else:
        i += 1

if kind is None:
    fail("solo admite --yesno, --msgbox, --infobox, --menu y --checklist")

req = {"kind": kind, "title": title, "text": text, "yes_label": yes_label,
       "no_label": no_label, "defaultno": defaultno, "items": items,
       "citems": citems}

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(600)
    s.connect(sock_path)
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
except OSError as err:
    fail(f"no se pudo hablar con la interfaz: {err}")

if not buf:
    fail("la interfaz no respondio")

resp = json.loads(buf.decode())
code = resp.get("code", 255)

if kind == "menu":
    sys.stderr.write(resp.get("selected") or "")
elif kind == "checklist":
    seleccion = resp.get("selected") or []
    sys.stderr.write(" ".join(f'"{t}"' for t in seleccion))

sys.exit(code)
'''


def entorno(sock_path):
    """Entorno para el script: TERM=dumb evita barras de progreso con cursor;
    el PATH antepuesto hace que 'whiptail' resuelva a nuestro puente."""
    env = os.environ.copy()
    env.update({"TERM": "dumb", "PAGER": "cat", "GIT_PAGER": "cat",
                "SYSTEMD_PAGER": "", "KBUILDER_BRIDGE_SOCK": str(sock_path)})
    try:
        SHIM_DIR.mkdir(parents=True, exist_ok=True)
        ruta = SHIM_DIR / "whiptail"
        if not ruta.exists() or ruta.read_text(encoding="utf-8") != BRIDGE_SHIM:
            ruta.write_text(BRIDGE_SHIM, encoding="utf-8")
        ruta.chmod(0o755)
        env["PATH"] = f"{SHIM_DIR}:{env.get('PATH', '')}"
    except OSError:
        pass
    return env


def repolish(widget):
    widget.style().unpolish(widget)
    widget.style().polish(widget)


def detectar_cpu():
    """Lectura de solo diagnóstico: informa, no decide. La comprobación que
    de verdad decide si se ofrece v3/znver3 la hace el propio script (5.5),
    contra /proc/cpuinfo y contra lo que GCC acepte en ese momento."""
    info = {"modelo": "desconocido", "vendor": "", "family": "",
            "zen3_o_posterior": False, "gcc_v3": None, "gcc_znver3": None}
    try:
        texto = Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return info
    for linea in texto.splitlines():
        if linea.startswith("model name") and info["modelo"] == "desconocido":
            info["modelo"] = linea.split(":", 1)[1].strip()
        elif linea.startswith("vendor_id") and not info["vendor"]:
            info["vendor"] = linea.split(":", 1)[1].strip()
        elif linea.startswith("cpu family") and not info["family"]:
            info["family"] = linea.split(":", 1)[1].strip()
        if info["vendor"] and info["family"] and info["modelo"] != "desconocido":
            break
    if info["vendor"] == "AuthenticAMD" and info["family"].isdigit() and int(info["family"]) >= 25:
        info["zen3_o_posterior"] = True
    if shutil.which("gcc"):
        fd, ruta_c = tempfile.mkstemp(suffix=".c")
        try:
            os.write(fd, b"int main(void){return 0;}")
            os.close(fd)
            for flag, clave in (("-march=x86-64-v3", "gcc_v3"),
                                ("-march=znver3", "gcc_znver3")):
                r = subprocess.run(["gcc", flag, "-o", "/dev/null", ruta_c],
                                   capture_output=True)
                info[clave] = (r.returncode == 0)
        finally:
            os.unlink(ruta_c)
    return info


class PtyRunner(QObject):
    """Ejecuta un proceso dentro de un pseudo-terminal (idéntico al del
    lanzador general: sudo, read y colores se comportan como en una
    terminal real)."""
    salida = pyqtSignal(bytes)
    terminado = pyqtSignal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.proc = None
        self.master = None
        self.timer = QTimer(self)
        self.timer.setInterval(40)
        self.timer.timeout.connect(self._tick)

    def activo(self):
        return self.proc is not None

    def start(self, args, env, cwd=None):
        master, slave = pty.openpty()
        attrs = termios.tcgetattr(slave)
        attrs[1] &= ~termios.ONLCR
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

        def hijo():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(args, stdin=slave, stdout=slave,
                                     stderr=slave, preexec_fn=hijo, env=env,
                                     cwd=cwd)
        os.close(slave)
        os.set_blocking(master, False)
        self.master = master
        self.timer.start()

    def enviar(self, texto):
        if self.master is None:
            return
        try:
            os.write(self.master, (texto + "\n").encode())
        except OSError:
            pass

    def cancelar(self):
        if not self.activo():
            return
        try:
            os.write(self.master, b"\x03")
        except OSError:
            pass
        QTimer.singleShot(4000, lambda p=self.proc: self._escalar(p, signal.SIGTERM))
        QTimer.singleShot(8000, lambda p=self.proc: self._escalar(p, signal.SIGKILL))

    def matar(self):
        if self.activo():
            self._escalar(self.proc, signal.SIGKILL)

    def _escalar(self, proc, sig):
        if proc is self.proc and proc.poll() is None:
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                pass

    def _leer(self):
        while True:
            try:
                listo, _, _ = select.select([self.master], [], [], 0)
                if not listo:
                    return
                datos = os.read(self.master, 65536)
            except OSError:
                return
            if not datos:
                return
            self.salida.emit(datos)

    def _tick(self):
        self._leer()
        rc = self.proc.poll()
        if rc is None:
            return
        self._leer()
        self.timer.stop()
        try:
            os.close(self.master)
        except OSError:
            pass
        self.master = None
        self.proc = None
        self.terminado.emit(rc)


class VistaLog(QPlainTextEdit):
    """Panel de registro tipo terminal: interpreta colores ANSI y \\r
    (idéntico al del lanzador general)."""

    def __init__(self):
        super().__init__()
        self.setObjectName("log")
        self.setReadOnly(True)
        self.setMaximumBlockCount(20000)
        self.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        self.limpiar()

    def limpiar(self):
        self.clear()
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self._resto = ""
        self._cr = False
        self._fmt = self._formato_base()

    @staticmethod
    def _formato_base():
        fmt = QTextCharFormat()
        fmt.setForeground(QColor(FG_DEFECTO))
        return fmt

    def _al_final(self):
        sb = self.verticalScrollBar()
        return sb.value() >= sb.maximum() - 4

    def _bajar(self):
        sb = self.verticalScrollBar()
        sb.setValue(sb.maximum())

    def feed(self, datos):
        texto = self._resto + self._decoder.decode(datos)
        self._resto = ""
        i = texto.rfind("\x1b")
        if i != -1 and not ANSI_RE.match(texto, i) and len(texto) - i < 64:
            self._resto = texto[i:]
            texto = texto[:i]
        seguir = self._al_final()
        pos = 0
        for m in ANSI_RE.finditer(texto):
            self._texto(texto[pos:m.start()])
            seq = m.group(0)
            if seq.startswith("\x1b[") and seq.endswith("m"):
                self._sgr(seq[2:-1])
            pos = m.end()
        self._texto(texto[pos:])
        if seguir:
            self._bajar()

    def sistema(self, mensaje, color="#56d4dd"):
        seguir = self._al_final()
        cur = self.textCursor()
        cur.movePosition(QTextCursor.MoveOperation.End)
        if self.document().lastBlock().text():
            cur.insertBlock()
        fmt = QTextCharFormat()
        fmt.setForeground(QColor(color))
        fmt.setFontWeight(700)
        cur.insertText(mensaje, fmt)
        cur.insertBlock()
        if seguir:
            self._bajar()

    def ultima_linea(self):
        return self.document().lastBlock().text()

    def _texto(self, s):
        if not s:
            return
        if self._cr:
            self._cr = False
            if not s.startswith("\n"):
                s = "\r" + s
        if s.endswith("\r"):
            self._cr = True
            s = s[:-1]
        cur = self.textCursor()
        cur.movePosition(QTextCursor.MoveOperation.End)
        for parte in re.split(r"(\r\n|\n|\r)", s):
            if not parte:
                continue
            if parte in ("\n", "\r\n"):
                cur.insertBlock()
            elif parte == "\r":
                cur.movePosition(QTextCursor.MoveOperation.StartOfBlock,
                                 QTextCursor.MoveMode.KeepAnchor)
                cur.removeSelectedText()
            else:
                cur.insertText(parte, self._fmt)

    def _sgr(self, params):
        nums = [int(p) if p.isdigit() else 0 for p in params.split(";")] if params else [0]
        i = 0
        while i < len(nums):
            n = nums[i]
            if n == 0:
                self._fmt = self._formato_base()
            elif n == 1:
                self._fmt.setFontWeight(700)
            elif n == 22:
                self._fmt.setFontWeight(400)
            elif 30 <= n <= 37:
                self._fmt.setForeground(QColor(PALETA[n - 30]))
            elif 90 <= n <= 97:
                self._fmt.setForeground(QColor(PALETA[n - 90 + 8]))
            elif n == 39:
                self._fmt.setForeground(QColor(FG_DEFECTO))
            elif n in (38, 48):
                modo = nums[i + 1] if i + 1 < len(nums) else 0
                if modo == 2:
                    if n == 38 and i + 4 < len(nums):
                        self._fmt.setForeground(QColor(nums[i + 2], nums[i + 3], nums[i + 4]))
                    i += 4
                elif modo == 5:
                    i += 2
            i += 1


class Bridge(QObject):
    """Puente entre el hilo del servidor de sockets y el hilo de la interfaz.
    pedir() se emite desde el hilo del servidor; Qt la entrega en cola al
    hilo de la interfaz, que rellena 'caja' y libera 'evento'."""
    pedir = pyqtSignal(dict, dict, object)


class BridgeHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(30)
        datos = b""
        try:
            while not datos.endswith(b"\n"):
                trozo = self.request.recv(65536)
                if not trozo:
                    break
                datos += trozo
        except OSError:
            return
        if not datos:
            return
        try:
            peticion = json.loads(datos.decode())
        except ValueError:
            return
        evento = threading.Event()
        caja = {}
        self.server.bridge.pedir.emit(peticion, caja, evento)
        evento.wait(600)
        respuesta = caja.get("resp", {"code": 255})
        try:
            self.request.sendall((json.dumps(respuesta) + "\n").encode())
        except OSError:
            pass


class BridgeServer(threading.Thread):
    def __init__(self, sock_path, bridge):
        super().__init__(daemon=True)
        self._srv = socketserver.ThreadingUnixStreamServer(str(sock_path), BridgeHandler)
        self._srv.daemon_threads = True
        self._srv.bridge = bridge

    def run(self):
        self._srv.serve_forever(poll_interval=0.2)

    def detener(self):
        self._srv.shutdown()
        self._srv.server_close()


class KernelBuilderWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Instalador de Kernel csr79a")
        self.setMinimumSize(880, 660)
        self.resize(1080, 780)

        self.runner = PtyRunner(self)
        self.runner.salida.connect(self._salida)
        self.runner.terminado.connect(self._terminado)
        self.timer_espera = QTimer(self)
        self.timer_espera.setSingleShot(True)
        self.timer_espera.timeout.connect(self._esperando_respuesta)

        self.bridge = Bridge(self)
        self.bridge.pedir.connect(self._atender_dialogo,
                                  Qt.ConnectionType.QueuedConnection)
        self.bridge_server = None
        self.sock_dir = None

        self.activo = False

        self.stack = QStackedWidget()
        self.stack.addWidget(self._build_home())
        self.stack.addWidget(self._build_run())
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.stack)

    # ---------------------------------------------------------------- inicio

    def _build_home(self):
        page = QWidget()

        hero = QFrame()
        hero.setObjectName("hero")
        hcol = QVBoxLayout(hero)
        hcol.setContentsMargins(30, 24, 30, 26)
        hcol.setSpacing(6)
        eyebrow = QLabel("KERNEL PERSONALIZADO")
        eyebrow.setObjectName("eyebrow")
        titulo = QLabel("Kernel Builder")
        titulo.setObjectName("titulo")
        subtitulo = QLabel(
            "Configura la optimización de CPU y el scheduler antes de compilar. "
            "La GUI solo selecciona las opciones; build-kernel-debian.sh sigue "
            "siendo el motor que descarga, verifica, parchea, compila e instala.")
        subtitulo.setObjectName("subtitulo")
        subtitulo.setWordWrap(True)
        hcol.addWidget(eyebrow)
        hcol.addWidget(titulo)
        hcol.addSpacing(4)
        hcol.addWidget(subtitulo)

        info = detectar_cpu()
        try:
            kver = os.uname().release
        except AttributeError:
            kver = "desconocido"

        hardware = QFrame()
        hardware.setObjectName("tarjeta")
        hcol2 = QVBoxLayout(hardware)
        hcol2.setContentsMargins(24, 18, 24, 18)
        hcol2.setSpacing(7)
        cab = QLabel("Hardware detectado")
        cab.setObjectName("accion")
        hcol2.addWidget(cab)
        datos = QLabel(
            f"CPU: {info['modelo'] or 'desconocido'}\n"
            f"Kernel actual: {kver}\n"
            f"{info['vendor'] or 'CPU'} · familia {info['family'] or '?'}")
        datos.setObjectName("detalle")
        datos.setWordWrap(True)
        hcol2.addWidget(datos)

        # ------------------------------------------------ CPU
        cpu_panel = QFrame()
        cpu_panel.setObjectName("tarjeta")
        cpu_col = QVBoxLayout(cpu_panel)
        cpu_col.setContentsMargins(24, 18, 24, 18)
        cpu_col.setSpacing(10)

        cpu_head = QHBoxLayout()
        cpu_title = QLabel("Optimización de CPU")
        cpu_title.setObjectName("accion")
        cpu_head.addWidget(cpu_title)
        cpu_head.addStretch()
        cpu_status = QLabel("Detección real mediante CPU + GCC")
        cpu_status.setObjectName("pie")
        cpu_head.addWidget(cpu_status)
        cpu_col.addLayout(cpu_head)

        cpu_desc = QLabel(
            "Elige un único perfil. x86-64-v3 y znver3 cambian KCFLAGS y el "
            "nombre final del kernel; no son parches independientes.")
        cpu_desc.setObjectName("pie")
        cpu_desc.setWordWrap(True)
        cpu_col.addWidget(cpu_desc)

        self.cpu_group = QButtonGroup(self)
        self.cpu_group.setExclusive(True)
        self.rb_generic = QRadioButton("Genérico — máxima portabilidad")
        self.rb_v3 = QRadioButton("x86-64-v3 — baseline moderno")
        self.rb_znver3 = QRadioButton("AMD Zen 3 / znver3 — optimizado para tu CPU")
        for rb in (self.rb_generic, self.rb_v3, self.rb_znver3):
            self.cpu_group.addButton(rb)
            cpu_col.addWidget(rb)
        self.rb_generic.setChecked(True)

        if not info["gcc_v3"]:
            self.rb_v3.setEnabled(False)
            self.rb_v3.setToolTip("GCC no acepta -march=x86-64-v3 en este sistema.")
        else:
            self.rb_v3.setToolTip("GCC acepta -march=x86-64-v3.")
        if not (info["gcc_znver3"] and info["zen3_o_posterior"]):
            self.rb_znver3.setEnabled(False)
            self.rb_znver3.setToolTip(
                "Solo se ofrece cuando la CPU es AMD Zen 3 o posterior y GCC acepta znver3.")
        else:
            self.rb_znver3.setToolTip(
                "CPU AMD Zen 3+ detectada y GCC acepta -march=znver3 -mtune=znver3.")

        # ------------------------------------------------ BORE
        bore_panel = QFrame()
        bore_panel.setObjectName("tarjeta")
        bore_col = QVBoxLayout(bore_panel)
        bore_col.setContentsMargins(24, 18, 24, 18)
        bore_col.setSpacing(9)
        bore_head = QHBoxLayout()
        bore_title = QLabel("Scheduler")
        bore_title.setObjectName("accion")
        bore_head.addWidget(bore_title)
        bore_head.addStretch()
        bore_badge = QLabel("OPCIONAL · EXPERIMENTAL")
        bore_badge.setObjectName("seleccion")
        bore_head.addWidget(bore_badge)
        bore_col.addLayout(bore_head)
        self.chk_bore = QCheckBox("Usar BORE Scheduler")
        self.chk_bore.setToolTip(
            "Pide al script que aplique automáticamente el parche BORE compatible "
            "con la serie del kernel. Si no existe o no aplica limpiamente, el build continúa sin BORE.")
        bore_col.addWidget(self.chk_bore)
        bore_detail = QLabel(
            "El script buscará el parche BORE correspondiente, comprobará el commit "
            "y hará un --dry-run antes de aplicarlo. La GUI no aplica el parche directamente.")
        bore_detail.setObjectName("pie")
        bore_detail.setWordWrap(True)
        bore_col.addWidget(bore_detail)

        # ------------------------------------------------ resumen
        resumen = QFrame()
        resumen.setObjectName("tarjeta")
        rcol = QVBoxLayout(resumen)
        rcol.setContentsMargins(24, 16, 24, 16)
        rcol.setSpacing(6)
        rtitle = QLabel("Configuración seleccionada")
        rtitle.setObjectName("accion")
        rcol.addWidget(rtitle)
        self.lbl_config = QLabel()
        self.lbl_config.setObjectName("seleccion")
        self.lbl_config.setWordWrap(True)
        rcol.addWidget(self.lbl_config)

        def actualizar_resumen():
            if self.rb_znver3.isChecked():
                march = "AMD Zen 3 / znver3"
            elif self.rb_v3.isChecked():
                march = "x86-64-v3"
            else:
                march = "Genérico"
            bore = "BORE activado" if self.chk_bore.isChecked() else "BORE desactivado"
            self.lbl_config.setText(f"CPU: {march}   ·   Scheduler: {bore}")

        for rb in (self.rb_generic, self.rb_v3, self.rb_znver3):
            rb.toggled.connect(actualizar_resumen)
        self.chk_bore.toggled.connect(actualizar_resumen)
        actualizar_resumen()

        controles = QHBoxLayout()
        self.chk_force = QCheckBox("Forzar recompilación (--force)")
        self.chk_force.setToolTip(
            "Permite recompilar la misma versión aunque ya esté instalada o preparada.")
        controles.addWidget(self.chk_force)
        controles.addStretch()
        btn_compilar = QPushButton("▶  Aplicar configuración y compilar")
        btn_compilar.setObjectName("primario")
        btn_compilar.clicked.connect(self.iniciar)
        controles.addWidget(btn_compilar)

        aviso = QLabel(f"Script: {SCRIPT}" if SCRIPT.exists()
                       else f"⚠ No se encontró {SCRIPT}")
        aviso.setObjectName("pie")

        layout = QVBoxLayout(page)
        layout.setContentsMargins(36, 28, 36, 22)
        layout.setSpacing(12)
        layout.addWidget(hero)
        layout.addWidget(hardware)
        layout.addWidget(cpu_panel)
        layout.addWidget(bore_panel)
        layout.addWidget(resumen)
        layout.addLayout(controles)
        layout.addWidget(aviso)
        return page

    # ------------------------------------------------------------ ejecución

    def _build_run(self):
        page = QWidget()
        cab = QHBoxLayout()
        self.lbl_accion = QLabel("Instalador de Kernel csr79a")
        self.lbl_accion.setObjectName("accion")
        self.lbl_estado = QLabel("")
        self.lbl_estado.setObjectName("estado")
        cab.addWidget(self.lbl_accion)
        cab.addStretch()
        cab.addWidget(self.lbl_estado)

        self.log = VistaLog()

        fila = QHBoxLayout()
        self.entrada = QLineEdit()
        self.entrada.setObjectName("entrada")
        self.entrada.returnPressed.connect(self.enviar)
        self.btn_enviar = QPushButton("Enviar")
        self.btn_enviar.setObjectName("secundario")
        self.btn_enviar.clicked.connect(self.enviar)
        fila.addWidget(self.entrada, 1)
        fila.addWidget(self.btn_enviar)

        pie = QHBoxLayout()
        self.btn_cancelar = QPushButton("Cancelar")
        self.btn_cancelar.setObjectName("secundario")
        self.btn_cancelar.clicked.connect(self.cancelar)
        self.btn_volver = QPushButton("Volver")
        self.btn_volver.setObjectName("secundario")
        self.btn_volver.clicked.connect(self.volver)
        self.btn_volver.setEnabled(False)
        pie.addWidget(self.btn_cancelar)
        pie.addStretch()
        pie.addWidget(self.btn_volver)

        layout = QVBoxLayout(page)
        layout.setContentsMargins(36, 24, 36, 22)
        layout.setSpacing(12)
        layout.addLayout(cab)
        layout.addWidget(self.log, 1)
        layout.addLayout(fila)
        layout.addLayout(pie)
        return page

    def iniciar(self):
        if self.runner.activo():
            return
        if not SCRIPT.exists():
            QMessageBox.critical(self, "Falta el script",
                                 f"No se encontró {SCRIPT}.")
            return
        respuesta = QMessageBox.question(
            self, "Confirmar",
            "La compilación puede tardar bastante y usará sudo para "
            "instalar dependencias y los .deb generados.\n\n¿Continuar?")
        if respuesta != QMessageBox.StandardButton.Yes:
            return

        self.sock_dir = Path(tempfile.mkdtemp(prefix="kbuilder-", dir="/tmp"))
        sock_path = self.sock_dir / "bridge.sock"
        try:
            self.bridge_server = BridgeServer(sock_path, self.bridge)
            self.bridge_server.start()
        except OSError as err:
            QMessageBox.critical(self, "No se pudo abrir el socket", str(err))
            shutil.rmtree(self.sock_dir, ignore_errors=True)
            self.sock_dir = None
            return

        self.log.limpiar()
        self._estado("run", "En ejecución…")
        self._controles(True)
        self.stack.setCurrentIndex(1)
        self.log.sistema("▶ Compilando (esto puede tardar bastante)…")

        args = ["bash", str(SCRIPT)]
        if self.chk_force.isChecked():
            args.append("--force")

        env = entorno(sock_path)
        if self.rb_znver3.isChecked():
            env["KBUILDER_MARCH_CHOICE"] = "znver3"
        elif self.rb_v3.isChecked():
            env["KBUILDER_MARCH_CHOICE"] = "v3"
        else:
            env["KBUILDER_MARCH_CHOICE"] = "generic"
        env["KBUILDER_BORE_CHOICE"] = "yes" if self.chk_bore.isChecked() else "no"

        seleccion = self.lbl_config.text()
        self.log.sistema(f"Configuración: {seleccion}", color="#79b8ff")
        self.runner.start(args, env, cwd=str(Path.home()))

    def _terminado(self, rc):
        self._cerrar_puente()
        if getattr(self, "_cancelado", False):
            self._cancelado = False
            self._fin("Cancelado por el usuario.", "Cancelado")
            return
        if rc == 0:
            self._fin("El script terminó correctamente.", "✔ Completado", ok=True)
        else:
            self._fin(f"El script terminó con código {rc}.", f"✖ Falló (código {rc})")

    def _cerrar_puente(self):
        if self.bridge_server is not None:
            self.bridge_server.detener()
            self.bridge_server = None
        if self.sock_dir is not None:
            shutil.rmtree(self.sock_dir, ignore_errors=True)
            self.sock_dir = None

    def _fin(self, mensaje, estado, ok=False):
        self.log.sistema(mensaje, color="#7ee787" if ok else "#ff6b6b")
        self._estado("ok" if ok else "error", estado)
        self._controles(False)
        self.timer_espera.stop()

    def _estado(self, tipo, texto):
        self.lbl_estado.setText(texto)
        self.lbl_estado.setProperty("estado", tipo)
        repolish(self.lbl_estado)

    def _controles(self, ejecutando):
        self.btn_volver.setEnabled(not ejecutando)
        self.entrada.setEnabled(ejecutando)
        self.btn_enviar.setEnabled(ejecutando)
        self.btn_cancelar.setEnabled(ejecutando)
        self.entrada.clear()
        self.entrada.setEchoMode(QLineEdit.EchoMode.Normal)
        self.entrada.setPlaceholderText("Respuesta al script…" if ejecutando else "")
        self._atencion(False)
        if ejecutando:
            self.entrada.setFocus()

    def _atencion(self, activa):
        self.entrada.setProperty("atencion", "true" if activa else "false")
        repolish(self.entrada)

    # ------------------------------------------------------- entrada/salida

    def _salida(self, datos):
        self.log.feed(datos)
        pide_clave = bool(PASS_RE.search(self.log.ultima_linea()))
        modo = QLineEdit.EchoMode.Password if pide_clave else QLineEdit.EchoMode.Normal
        if self.entrada.echoMode() != modo:
            self.entrada.setEchoMode(modo)
            self.entrada.setPlaceholderText(
                "Contraseña (no se muestra)…" if pide_clave else "Respuesta al script…")
        self._atencion(False)
        self.timer_espera.start(700)

    def _esperando_respuesta(self):
        if self.runner.activo() and self.log.ultima_linea():
            self._atencion(True)
            self.entrada.setFocus()

    def enviar(self):
        if not self.runner.activo():
            return
        texto = self.entrada.text()
        self.entrada.clear()
        self._atencion(False)
        self.runner.enviar(texto)

    def cancelar(self):
        if self.runner.activo():
            self._cancelado = True
            self.log.sistema("Cancelando…", color="#f2cc60")
            self.runner.cancelar()

    def volver(self):
        self.stack.setCurrentIndex(0)

    # --------------------------------------------------- puente de diálogos

    def _atender_dialogo(self, peticion, caja, evento):
        try:
            kind = peticion.get("kind")
            titulo = peticion.get("title") or "Instalador de Kernel csr79a"
            texto = peticion.get("text", "")
            if kind == "yesno":
                codigo = self._dlg_yesno(titulo, texto,
                                         peticion.get("yes_label", "Sí"),
                                         peticion.get("no_label", "No"),
                                         peticion.get("defaultno", False))
                resp = {"code": codigo}
            elif kind == "msgbox":
                self._dlg_msgbox(titulo, texto)
                resp = {"code": 0}
            elif kind == "infobox":
                self.log.sistema(f"[{titulo}] {texto}")
                resp = {"code": 0}
            elif kind == "menu":
                codigo, tag = self._dlg_menu(titulo, texto, peticion.get("items", []))
                resp = {"code": codigo, "selected": tag}
            elif kind == "checklist":
                codigo, tags = self._dlg_checklist(titulo, texto, peticion.get("citems", []))
                resp = {"code": codigo, "selected": tags}
            else:
                resp = {"code": 255}
        except Exception:
            resp = {"code": 255}
        caja["resp"] = resp
        evento.set()

    def _dlg_yesno(self, titulo, texto, yes_lbl, no_lbl, defaultno):
        caja = QMessageBox(self)
        caja.setWindowTitle(titulo)
        caja.setText(texto)
        caja.setIcon(QMessageBox.Icon.Question)
        btn_si = caja.addButton(yes_lbl, QMessageBox.ButtonRole.YesRole)
        btn_no = caja.addButton(no_lbl, QMessageBox.ButtonRole.NoRole)
        caja.setDefaultButton(btn_no if defaultno else btn_si)
        caja.exec()
        return 0 if caja.clickedButton() is btn_si else 1

    def _dlg_msgbox(self, titulo, texto):
        caja = QMessageBox(self)
        caja.setWindowTitle(titulo)
        caja.setText(texto)
        caja.setIcon(QMessageBox.Icon.Information)