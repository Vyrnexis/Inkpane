import std/[strutils, unicode]

import dbus
import glib
import portal

# Pointer and keyboard input through the desktop's RemoteDesktop portal, for inkpane-mcp
# when the user has allowed AI clicking. The desktop asks the user for every session (one
# per inkpane-mcp process, so per AI conversation) and nothing is remembered: an AI that
# edits the settings file still can't click until a person answers that dialog.
# Absolute pointer positions need a screen-cast stream per monitor, so the session also
# selects the monitors; nothing ever reads those streams.

const
  PortalBusName = "org.freedesktop.portal.Desktop"
  PortalObjectPath = "/org/freedesktop/portal/desktop"
  RemoteInterface = "org.freedesktop.portal.RemoteDesktop"
  CastInterface = "org.freedesktop.portal.ScreenCast"
  StartTimeoutSeconds = 120   # the user may be reading the permission dialog
  KeyboardAndPointer = 3'u32
  Monitors = 1'u32

  ButtonCodes* = [("left", 0x110'i32), ("right", 0x111'i32), ("middle", 0x112'i32)]   # evdev
  NamedKeys = [
    ("enter", 0xff0d), ("return", 0xff0d), ("tab", 0xff09), ("esc", 0xff1b),
    ("escape", 0xff1b), ("backspace", 0xff08), ("delete", 0xffff), ("space", 0x20),
    ("up", 0xff52), ("down", 0xff54), ("left", 0xff51), ("right", 0xff53),
    ("home", 0xff50), ("end", 0xff57), ("pageup", 0xff55), ("pagedown", 0xff56),
    ("ctrl", 0xffe3), ("shift", 0xffe1), ("alt", 0xffe9), ("super", 0xffeb), ("meta", 0xffeb)]
  Modifiers* = ["ctrl", "shift", "alt", "super", "meta"]

type
  Stream* = object
    node*: uint32
    x*, y*, w*, h*: int   # the monitor it shows, in logical px

  RemoteSession* = ref object
    handle: string
    streams*: seq[Stream]

proc lookupPair(dict: GVariant, key: string): (int, int) =
  let value = g_variant_lookup_value(dict, key.cstring, variantType("(ii)"))
  if value.isNil:
    return
  var a, b: int32
  g_variant_get(value, "(ii)", addr a, addr b)
  g_variant_unref(value)
  (int(a), int(b))

proc close*(session: RemoteSession) =
  try:
    g_variant_unref(call(PortalBusName, session.handle, "org.freedesktop.portal.Session", "Close"))
  except DBusError:
    discard

proc start*(): RemoteSession =
  ## Asks the desktop for pointer and keyboard control of every monitor; may show its
  ## permission dialog. Raises PortalError when refused.
  let created = portalRequest(RemoteInterface, "CreateSession", StartTimeoutSeconds,
    proc(token: string): GVariant =
      let options = newOptions(token)
      options.addString("session_handle_token", newToken())
      g_variant_new("(@a{sv})", options.finish()))
  let handleValue = g_variant_lookup_value(created, "session_handle", variantType("s"))
  g_variant_unref(created)
  if handleValue.isNil:
    raise newException(PortalError, "The desktop portal did not return a session.")
  result = RemoteSession(handle: $g_variant_get_string(handleValue, nil))
  g_variant_unref(handleValue)
  let handle = result.handle
  try:
    g_variant_unref(portalRequest(RemoteInterface, "SelectDevices", StartTimeoutSeconds,
      proc(token: string): GVariant =
        let options = newOptions(token)
        g_variant_builder_add(options, "{sv}", "types".cstring, g_variant_new_uint32(KeyboardAndPointer))
        g_variant_new("(o@a{sv})", handle.cstring, options.finish())))
    g_variant_unref(portalRequest(CastInterface, "SelectSources", StartTimeoutSeconds,
      proc(token: string): GVariant =
        let options = newOptions(token)
        g_variant_builder_add(options, "{sv}", "types".cstring, g_variant_new_uint32(Monitors))
        g_variant_builder_add(options, "{sv}", "multiple".cstring, g_variant_new_boolean(1))
        g_variant_new("(o@a{sv})", handle.cstring, options.finish())))
    let started = portalRequest(RemoteInterface, "Start", StartTimeoutSeconds,
      proc(token: string): GVariant =
        g_variant_new("(os@a{sv})", handle.cstring, "".cstring, newOptions(token).finish()))
    defer: g_variant_unref(started)
    let streams = g_variant_lookup_value(started, "streams", variantType("a(ua{sv})"))
    if not streams.isNil:
      for i in 0 ..< g_variant_n_children(streams):
        let stream = g_variant_get_child_value(streams, i)
        let node = g_variant_get_child_value(stream, 0)
        let props = g_variant_get_child_value(stream, 1)
        let (x, y) = props.lookupPair("position")
        let (w, h) = props.lookupPair("size")
        result.streams.add(Stream(node: g_variant_get_uint32(node), x: x, y: y, w: w, h: h))
        for part in [node, props, stream]:
          g_variant_unref(part)
      g_variant_unref(streams)
    if result.streams.len == 0:
      raise newException(PortalError, "The desktop shared no monitor, so pointer positions can't be given.")
  except CatchableError:
    result.close()
    raise

############################
# Input
############################

proc notify(session: RemoteSession, methodName: string, parameters: GVariant) =
  g_variant_unref(call(PortalBusName, PortalObjectPath, RemoteInterface, methodName, parameters))

proc moveTo*(session: RemoteSession, stream: Stream, x, y: float) =
  ## x, y in logical px of the stream's monitor.
  session.notify("NotifyPointerMotionAbsolute", g_variant_new("(oa{sv}udd)",
    session.handle.cstring, pointer(nil), stream.node, cdouble(x), cdouble(y)))

proc button*(session: RemoteSession, code: int32, down: bool) =
  session.notify("NotifyPointerButton", g_variant_new("(oa{sv}iu)", session.handle.cstring,
    pointer(nil), code, uint32(ord(down))))

proc scroll*(session: RemoteSession, steps: int) =
  ## Mouse-wheel notches; positive scrolls down.
  session.notify("NotifyPointerAxisDiscrete", g_variant_new("(oa{sv}ui)", session.handle.cstring,
    pointer(nil), 0'u32, int32(steps)))

proc key*(session: RemoteSession, keysym: int, down: bool) =
  session.notify("NotifyKeyboardKeysym", g_variant_new("(oa{sv}iu)", session.handle.cstring,
    pointer(nil), int32(keysym), uint32(ord(down))))

proc keysymFor*(rune: Rune): int =
  ## Latin-1 characters are their own keysym; others are 0x1000000 + the code point.
  case int(rune)
  of 0x0a: 0xff0d   # newline: Return
  of 0x09: 0xff09
  of 0x20 .. 0x7e, 0xa0 .. 0xff: int(rune)
  else: 0x01000000 + int(rune)

proc namedKeysym*(name: string): int =
  ## "enter", "f5", "a", "ctrl" …; -1 when unknown.
  let lower = name.toLowerAscii
  for (n, sym) in NamedKeys:
    if lower == n:
      return sym
  if lower.len >= 2 and lower[0] == 'f' and lower[1 .. ^1].allCharsInSet(Digits):
    let n = parseInt(lower[1 .. ^1])
    if n in 1 .. 12:
      return 0xffbe + n - 1
  if lower.runeLen == 1:
    return keysymFor(lower.runeAt(0))
  -1
