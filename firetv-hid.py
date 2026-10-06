#!/usr/bin/env python3
"""Expose this host as a Bluetooth HID keyboard and send explicit commands."""

import argparse
import grp
import os
import signal
import socket
import threading
import time


HID_UUID = "00001124-0000-1000-8000-00805f9b34fb"
PROFILE_PATH = "/org/videokiosk2/firetv_hid/profile"
AGENT_PATH = "/org/videokiosk2/firetv_hid/agent"
SOCKET_PATH = "/run/firetv-hid.sock"

KEYBOARD_KEYS = {
    "select": 0x28,
    "back": 0x29,
    "right": 0x4F,
    "left": 0x50,
    "down": 0x51,
    "up": 0x52,
    "power": 0x66,
}

CONSUMER_KEYS = {
    "play": 0x00CD,
    "stop": 0x00B7,
    "rewind": 0x00B4,
    "forward": 0x00B3,
}

SYSTEM_KEYS = {
    "system-power": 1,
    "sleep": 2,
    "wake": 3,
}

SERVICE_RECORD = """<?xml version="1.0" encoding="UTF-8" ?>
<record>
  <attribute id="0x0001"><sequence><uuid value="0x1124" /></sequence></attribute>
  <attribute id="0x0004"><sequence>
    <sequence><uuid value="0x0100" /><uint16 value="0x0011" /></sequence>
    <sequence><uuid value="0x0011" /></sequence>
  </sequence></attribute>
  <attribute id="0x0005"><sequence><uuid value="0x1002" /></sequence></attribute>
  <attribute id="0x0006"><sequence>
    <uint16 value="0x656e" /><uint16 value="0x006a" /><uint16 value="0x0100" />
  </sequence></attribute>
  <attribute id="0x0009"><sequence><sequence>
    <uuid value="0x1124" /><uint16 value="0x0100" />
  </sequence></sequence></attribute>
  <attribute id="0x000d"><sequence><sequence>
    <sequence><uuid value="0x0100" /><uint16 value="0x0013" /></sequence>
    <sequence><uuid value="0x0011" /></sequence>
  </sequence></sequence></attribute>
    <attribute id="0x0100"><text value="videokiosk2 Remote" /></attribute>
  <attribute id="0x0101"><text value="Fire TV HID test controller" /></attribute>
  <attribute id="0x0102"><text value="videokiosk2" /></attribute>
  <attribute id="0x0200"><uint16 value="0x0100" /></attribute>
  <attribute id="0x0201"><uint16 value="0x0111" /></attribute>
  <attribute id="0x0202"><uint8 value="0x40" /></attribute>
  <attribute id="0x0203"><uint8 value="0x00" /></attribute>
  <attribute id="0x0204"><boolean value="true" /></attribute>
  <attribute id="0x0205"><boolean value="true" /></attribute>
  <attribute id="0x0206"><sequence><sequence>
    <uint8 value="0x22" />
    <text encoding="hex" value="05010906a1018501050719e029e71500250175019508810295017508810195067508150026ff000507190029ff8100c0050c0901a1018502150026ff0319002aff03751095018100c005010980a101850305011981298315012503750295018100750695018103c0" />
  </sequence></sequence></attribute>
  <attribute id="0x0207"><sequence><sequence>
    <uint16 value="0x0409" /><uint16 value="0x0100" />
  </sequence></sequence></attribute>
  <attribute id="0x020b"><uint16 value="0x0100" /></attribute>
  <attribute id="0x020c"><uint16 value="0x0c80" /></attribute>
  <attribute id="0x020d"><boolean value="false" /></attribute>
  <attribute id="0x020e"><boolean value="true" /></attribute>
</record>
"""


class Runtime:
    def __init__(self):
        self.running = True
        self.interrupt = None
        self.remote_address = None
        self.lock = threading.Lock()

    def send(self, command):
        with self.lock:
            if self.interrupt is None:
                raise RuntimeError("Fire TV is not connected")
            if command in KEYBOARD_KEYS:
                usage = KEYBOARD_KEYS[command]
                self._write(bytes([0xA1, 0x01, 0, 0, usage, 0, 0, 0, 0, 0]))
                self._write(bytes([0xA1, 0x01, 0, 0, 0, 0, 0, 0, 0, 0]))
            elif command in CONSUMER_KEYS:
                usage = CONSUMER_KEYS[command]
                self._write(bytes([0xA1, 0x02, usage & 0xFF, usage >> 8]))
                self._write(bytes([0xA1, 0x02, 0, 0]))
            elif command in SYSTEM_KEYS:
                self._write(bytes([0xA1, 0x03, SYSTEM_KEYS[command]]))
                self._write(bytes([0xA1, 0x03, 0]))
            else:
                raise ValueError(f"Unknown command: {command}")

    def _write(self, report):
        self.interrupt.send(report)
        time.sleep(0.08)


def import_bluez_modules():
    try:
        import dbus
        import dbus.service
        from dbus.mainloop.glib import DBusGMainLoop
        from gi.repository import GLib
    except ImportError as error:
        raise SystemExit(
            "Missing dependencies. Install python3-dbus and python3-gi."
        ) from error
    return dbus, DBusGMainLoop, GLib


def make_dbus_classes(dbus):
    class Profile(dbus.service.Object):
        @dbus.service.method("org.bluez.Profile1", in_signature="", out_signature="")
        def Release(self):
            return None

        @dbus.service.method("org.bluez.Profile1", in_signature="", out_signature="")
        def Cancel(self):
            return None

        @dbus.service.method("org.bluez.Profile1", in_signature="oha{sv}", out_signature="")
        def NewConnection(self, path, file_descriptor, properties):
            return None

        @dbus.service.method("org.bluez.Profile1", in_signature="o", out_signature="")
        def RequestDisconnection(self, path):
            return None

    class Agent(dbus.service.Object):
        @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
        def Release(self):
            return None

        @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="s")
        def RequestPinCode(self, device):
            return "0000"

        @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
        def RequestPasskey(self, device):
            return dbus.UInt32(0)

        @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
        def DisplayPinCode(self, device, pin_code):
            return None

        @dbus.service.method("org.bluez.Agent1", in_signature="ouq", out_signature="")
        def DisplayPasskey(self, device, passkey, entered):
            return None

        @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
        def RequestConfirmation(self, device, passkey):
            return None

        @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
        def RequestAuthorization(self, device):
            return None

        @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
        def AuthorizeService(self, device, uuid):
            return None

        @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
        def Cancel(self):
            return None

    return Profile, Agent


def adapter_path(bus):
    manager = dbus_interface(bus, "/", "org.freedesktop.DBus.ObjectManager")
    objects = manager.GetManagedObjects()
    for path, interfaces in objects.items():
        if "org.bluez.Adapter1" in interfaces:
            return path
    raise RuntimeError("No BlueZ adapter found")


def dbus_interface(bus, path, interface):
    import dbus

    return dbus.Interface(bus.get_object("org.bluez", path), interface)


def configure_adapter(bus, dbus, path, device_name):
    properties = dbus_interface(bus, path, "org.freedesktop.DBus.Properties")
    for name, value in (
        ("Alias", dbus.String(device_name)),
        ("Powered", dbus.Boolean(True)),
        ("PairableTimeout", dbus.UInt32(0)),
        ("DiscoverableTimeout", dbus.UInt32(0)),
        ("Pairable", dbus.Boolean(True)),
        ("Discoverable", dbus.Boolean(True)),
    ):
        properties.Set("org.bluez.Adapter1", name, value)


def command_server(runtime):
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    try:
        os.chown(SOCKET_PATH, 0, grp.getgrnam("video").gr_gid)
    except KeyError:
        pass
    os.chmod(SOCKET_PATH, 0o660)
    server.listen(4)
    server.settimeout(1)
    while runtime.running:
        try:
            connection, _ = server.accept()
        except socket.timeout:
            continue
        with connection:
            command = connection.recv(128).decode("ascii", "replace").strip()
            try:
                if command == "status":
                    state = "connected" if runtime.interrupt else "waiting"
                    response = f"{state} {runtime.remote_address or ''}".strip()
                else:
                    runtime.send(command)
                    response = f"sent {command}"
            except Exception as error:
                response = f"error {error}"
            connection.sendall((response + "\n").encode())
    server.close()


def connect_target(adapter_address, target_address):
    control = socket.socket(
        socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP
    )
    interrupt = socket.socket(
        socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP
    )
    try:
        for channel in (control, interrupt):
            channel.settimeout(3)
            channel.bind((adapter_address, 0))
        control.connect((target_address, 0x11))
        interrupt.connect((target_address, 0x13))
        return control, interrupt
    except OSError:
        control.close()
        interrupt.close()
        return None


def serve(adapter_address, device_name, target_address):
    if os.geteuid() != 0:
        raise SystemExit("The serve command must run as root")

    dbus, DBusGMainLoop, GLib = import_bluez_modules()
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    Profile, Agent = make_dbus_classes(dbus)
    profile = Profile(bus, PROFILE_PATH)
    agent = Agent(bus, AGENT_PATH)
    agent_manager = dbus_interface(bus, "/org/bluez", "org.bluez.AgentManager1")
    profile_manager = dbus_interface(bus, "/org/bluez", "org.bluez.ProfileManager1")
    adapter = adapter_path(bus)
    adapter_properties = dbus_interface(
        bus, adapter, "org.freedesktop.DBus.Properties"
    )
    if not adapter_address:
        adapter_address = str(
            adapter_properties.Get("org.bluez.Adapter1", "Address")
        )

    try:
        agent_manager.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
    except dbus.exceptions.DBusException as error:
        if "AlreadyExists" not in str(error):
            raise
    try:
        agent_manager.RequestDefaultAgent(AGENT_PATH)
    except dbus.exceptions.DBusException:
        pass

    configure_adapter(bus, dbus, adapter, device_name)
    profile_manager.RegisterProfile(
        PROFILE_PATH,
        HID_UUID,
        {
            "ServiceRecord": SERVICE_RECORD,
            "Name": device_name,
            "Role": "server",
            "RequireAuthentication": False,
            "RequireAuthorization": False,
        },
    )

    main_loop = GLib.MainLoop()
    threading.Thread(target=main_loop.run, daemon=True).start()
    runtime = Runtime()
    threading.Thread(target=command_server, args=(runtime,), daemon=True).start()

    control_listener = socket.socket(
        socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP
    )
    interrupt_listener = socket.socket(
        socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP
    )
    control_listener.bind((adapter_address, 0x11))
    interrupt_listener.bind((adapter_address, 0x13))
    control_listener.listen(1)
    interrupt_listener.listen(1)
    control_listener.settimeout(1)
    interrupt_listener.settimeout(5)

    def stop(signum, frame):
        runtime.running = False
        control_listener.close()
        interrupt_listener.close()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print(f"READY {device_name} ({adapter_address})", flush=True)

    while runtime.running:
        connection = connect_target(adapter_address, target_address) if target_address else None
        if connection:
            control, interrupt = connection
            remote_address = target_address
        else:
            try:
                control, control_address = control_listener.accept()
                interrupt, interrupt_address = interrupt_listener.accept()
                remote_address = interrupt_address[0]
            except socket.timeout:
                continue
            except OSError:
                break
        runtime.remote_address = remote_address
        runtime.interrupt = interrupt
        print(f"CONNECTED {runtime.remote_address}", flush=True)
        control.settimeout(1)
        while runtime.running and runtime.interrupt is interrupt:
            try:
                payload = control.recv(128)
                if not payload:
                    break
            except socket.timeout:
                continue
            except OSError:
                break
        with runtime.lock:
            if runtime.interrupt is interrupt:
                runtime.interrupt = None
                runtime.remote_address = None
        control.close()
        interrupt.close()
        print("DISCONNECTED", flush=True)

    runtime.running = False
    main_loop.quit()
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    profile_manager.UnregisterProfile(PROFILE_PATH)
    try:
        agent_manager.UnregisterAgent(AGENT_PATH)
    except dbus.exceptions.DBusException:
        pass
    del profile, agent


def send_command(command):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(SOCKET_PATH)
    client.sendall((command + "\n").encode())
    response = client.recv(1024).decode().strip()
    print(response)
    if response.startswith("error "):
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="action", required=True)
    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument(
        "--adapter", help="Bluetooth adapter address (default: first BlueZ adapter)"
    )
    serve_parser.add_argument(
        "--name",
        default=f"{socket.gethostname()} Remote",
        help="Bluetooth device name (default: <hostname> Remote)",
    )
    serve_parser.add_argument(
        "--target", help="Paired Fire TV Bluetooth address to reconnect"
    )
    send_parser = subparsers.add_parser("send")
    send_parser.add_argument(
        "command",
        choices=[
            "status",
            *KEYBOARD_KEYS,
            *CONSUMER_KEYS,
            *SYSTEM_KEYS,
        ],
    )
    arguments = parser.parse_args()
    if arguments.action == "serve":
        serve(arguments.adapter, arguments.name, arguments.target)
    else:
        send_command(arguments.command)


if __name__ == "__main__":
    main()