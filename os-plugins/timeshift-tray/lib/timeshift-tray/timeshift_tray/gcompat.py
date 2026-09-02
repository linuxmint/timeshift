# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""The one place this program cares which GLib it is running against.

`register_object_with_closures2` is GLib 2.84. Calling it directly means the
applet installs cleanly on Ubuntu 24.04 and Debian 12 and then dies with an
AttributeError the moment it tries to export anything -- into a session journal
nobody reads, with no icon and no message.

`register_object` is the same call: the GIR marks it `shadowed-by`
`register_object_with_closures`, which has existed since GLib 2.46. So the
fallback is not a reimplementation, it is the older name for the same thing.
"""

import gi

gi.require_version("Gio", "2.0")


def register_object(bus, path, interface_info, on_call, on_get, on_set=None):
    """Export one interface, on whatever GLib this is.

    Returns the registration id, for Gio.DBusConnection.unregister_object.
    """
    modern = getattr(bus, "register_object_with_closures2", None)
    if modern is not None:
        return modern(path, interface_info, on_call, on_get, on_set)
    legacy = getattr(bus, "register_object_with_closures", None) or bus.register_object
    return legacy(path, interface_info, on_call, on_get, on_set)


def unregister_object(bus, registration_id):
    """Undo register_object. Safe to call with 0."""
    if registration_id:
        bus.unregister_object(registration_id)


__all__ = ["register_object", "unregister_object"]
